# ─── Constants ────────────────────────────────────────────────────────────────

const PF_CAN = Cint(29)
const AF_CAN = Cint(29)
const SOCK_RAW = Cint(3)
const CAN_RAW = Cint(1)
const CAN_EFF_FLAG = UInt32(0x80000000)
const CAN_MAX_DLC = 8
const CAN_SFF_MASK = UInt32(0x000007FF)   # 11-bit standard ID mask
const CAN_EFF_MASK = UInt32(0x1FFFFFFF)   # 29-bit extended ID mask

# poll(2) constants
const POLLIN  = Cshort(0x0001)
const POLLERR = Cshort(0x0008)
const POLLHUP = Cshort(0x0010)
const POLLNVAL = Cshort(0x0020)

# setsockopt constants
const SOL_CAN_RAW = Cint(101)
const CAN_RAW_FILTER = Cint(1)
const CAN_RAW_RECV_OWN_MSGS = Cint(4)

# errno constants
const EINTR  = 4
const EBADF  = 9

# ─── Structs ─────────────────────────────────────────────────────────────────

struct SockAddrCAN
    can_family::UInt16
    pad::UInt16
    can_ifindex::Cint
    addr::NTuple{8, UInt8}
end

Base.sizeof(::Type{SockAddrCAN}) = 16

struct CanFrameRaw
    can_id::UInt32
    can_dlc::UInt8
    _pad::UInt8
    _res0::UInt8
    _res1::UInt8
    data::NTuple{8,UInt8}
end

Base.sizeof(::Type{CanFrameRaw}) = 16

struct PollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end

struct CanFilter
    can_id::UInt32
    can_mask::UInt32
end

# ─── Exception ───────────────────────────────────────────────────────────────

struct SocketCANError <: Exception
    msg::String
end

# ─── Driver ──────────────────────────────────────────────────────────────────

function _close_fd(sc)
    old = @atomicswap sc.closed = true
    old && return nothing
    fd = sc.handler
    fd >= 0 && ccall(:close, Cint, (Cint,), fd)
    return nothing
end

mutable struct SocketCanDriver <: AbstractCanDriver
    channelname::String
    handler::Int32
    @atomic closed::Bool

    function SocketCanDriver(channelname::String)
        handler = ccall(:socket, Cint, (Cint, Cint, Cint), PF_CAN, SOCK_RAW, CAN_RAW)
        handler < 0 && throw(SocketCANError("socket() failed: $(Libc.strerror(Libc.errno()))"))

        index = ccall(:if_nametoindex, UInt32, (Cstring,), channelname)
        if index == 0
            ccall(:close, Cint, (Cint,), handler)
            throw(SocketCANError("if_nametoindex('$channelname') failed: $(Libc.strerror(Libc.errno()))"))
        end
        addrRef = Ref{SockAddrCAN}(SockAddrCAN(UInt16(AF_CAN), UInt16(0), Cint(index), ntuple(_->UInt8(0), 8)))
        bindres = ccall(:bind, Cint, (Ptr{SockAddrCAN}, UInt32, Cint), handler, addrRef, UInt32(sizeof(SockAddrCAN)))

        if bindres < 0
            ccall(:close, Cint, (Cint,), handler)
            throw(SocketCANError("bind() failed on '$channelname': $(Libc.strerror(Libc.errno()))"))
        end

        sc = new(channelname, handler, false)
        finalizer(_close_fd, sc)
        return sc
    end
end

function close(sc::SocketCanDriver)
    _close_fd(sc)
    return nothing
end

function Base.isopen(sc::SocketCanDriver)::Bool
    return !(@atomic sc.closed)
end

# ─── Read ────────────────────────────────────────────────────────────────────

"""
    read(sc::SocketCanDriver; timeout_ms::Int=-1) -> CanFrameRaw or nothing

Read one CAN frame.

- `timeout_ms = -1` (default): block indefinitely
- `timeout_ms = 0`: return immediately if no data available
- `timeout_ms > 0`: wait up to that many milliseconds

Returns `nothing` on timeout, EOF, partial read, or when the socket is closed
during a blocking wait. Throws `SocketCANError` on real I/O errors.
"""
function read(sc::SocketCanDriver; timeout_ms::Int=-1)
    @atomic(sc.closed) && throw(SocketCANError("read() on closed SocketCanDriver '$(sc.channelname)'"))

    if timeout_ms >= 0
        pfd = Ref(PollFD(Cint(sc.handler), POLLIN, Cshort(0)))
        ret = ccall(:poll, Cint, (Ptr{PollFD}, Cuint, Cint), pfd, Cuint(1), Cint(timeout_ms))
        if ret == 0
            return nothing  # timeout
        elseif ret < 0
            err = Libc.errno()
            (err == EINTR || err == EBADF) && return nothing
            throw(SocketCANError("poll() failed on '$(sc.channelname)': $(Libc.strerror(err))"))
        end
        # ret > 0: data ready or error condition on fd — check revents
        revents = pfd[].revents
        (revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 && return nothing
    end

    raw = Ref{CanFrameRaw}()
    nbytes = ccall(:read, Cssize_t, (Cint, Ptr{CanFrameRaw}, Csize_t),
                    Cint(sc.handler), raw, Csize_t(sizeof(CanFrameRaw)))
    if nbytes == sizeof(CanFrameRaw)
        return raw[]
    elseif nbytes <= 0
        err = Libc.errno()
        (nbytes == 0 || err == EBADF || err == EINTR) && return nothing
        throw(SocketCANError("read() failed on '$(sc.channelname)': $(Libc.strerror(err))"))
    else
        return nothing  # partial read
    end
end

# ─── Write ───────────────────────────────────────────────────────────────────

function _validate_canid(canid::UInt32, extended::Bool)
    if canid & ~CAN_EFF_MASK != 0
        throw(ArgumentError("CAN ID 0x$(string(canid; base=16)) has bits set above 29-bit range; pass raw ID without flags"))
    end
    if !extended && canid > CAN_SFF_MASK
        throw(ArgumentError("Standard CAN ID 0x$(string(canid; base=16)) exceeds 11-bit range"))
    end
    return nothing
end

"""
    write(sc, canid, data::NTuple{8,UInt8}; extended=true)

Write a CAN frame with an 8-byte tuple payload.
When `extended=true` (default), `CAN_EFF_FLAG` is ORed into `canid`.
"""
function write(sc::SocketCanDriver, canid::UInt32, data::NTuple{8,UInt8}; extended::Bool=true)
    @atomic(sc.closed) && throw(SocketCANError("write() on closed SocketCanDriver '$(sc.channelname)'"))
    _validate_canid(canid, extended)
    id = extended ? (canid | CAN_EFF_FLAG) : canid
    raw = Ref{CanFrameRaw}(CanFrameRaw(id, UInt8(CAN_MAX_DLC), 0x00, 0x00, 0x00, data))
    nbytes = ccall(:write, Cssize_t, (Cint, Ptr{CanFrameRaw}, Csize_t),
                    Cint(sc.handler), raw, Csize_t(sizeof(CanFrameRaw)))
    nbytes == sizeof(CanFrameRaw) && return nothing
    throw(SocketCANError("write() failed on '$(sc.channelname)': $(Libc.strerror(Libc.errno()))"))
end

"""
    write(sc, canid, data::AbstractVector{UInt8}; extended=true)

Write a CAN frame with a vector payload (0-8 bytes, padded with zeros).
When `extended=true` (default), `CAN_EFF_FLAG` is ORed into `canid`.
"""
function write(sc::SocketCanDriver, canid::UInt32, data::AbstractVector{UInt8}; extended::Bool=true)
    dlc = length(data)
    0 <= dlc <= CAN_MAX_DLC || throw(ArgumentError("CAN data length must be 0-$CAN_MAX_DLC, got $dlc"))
    bytes = ntuple(i -> i <= dlc ? UInt8(data[i]) : UInt8(0), CAN_MAX_DLC)
    @atomic(sc.closed) && throw(SocketCANError("write() on closed SocketCanDriver '$(sc.channelname)'"))
    _validate_canid(canid, extended)
    id = extended ? (canid | CAN_EFF_FLAG) : canid
    raw = Ref{CanFrameRaw}(CanFrameRaw(id, UInt8(dlc), 0x00, 0x00, 0x00, bytes))
    nbytes = ccall(:write, Cssize_t, (Cint, Ptr{CanFrameRaw}, Csize_t),
                    Cint(sc.handler), raw, Csize_t(sizeof(CanFrameRaw)))
    nbytes == sizeof(CanFrameRaw) && return nothing
    throw(SocketCANError("write() failed on '$(sc.channelname)': $(Libc.strerror(Libc.errno()))"))
end

# ─── Socket Options ──────────────────────────────────────────────────────────

"""
    set_filters!(sc, filters::AbstractVector{CanFilter})

Apply kernel-level CAN ID filters via `setsockopt`. Only frames matching at
least one filter will be delivered to `read()`.
"""
function set_filters!(sc::SocketCanDriver, filters::AbstractVector{CanFilter})
    @atomic(sc.closed) && throw(SocketCANError("set_filters!() on closed SocketCanDriver '$(sc.channelname)'"))
    ret = ccall(:setsockopt, Cint,
        (Cint, Cint, Cint, Ptr{CanFilter}, UInt32),
        sc.handler, SOL_CAN_RAW, CAN_RAW_FILTER,
        filters, UInt32(length(filters) * sizeof(CanFilter)))
    ret < 0 && throw(SocketCANError("setsockopt(CAN_RAW_FILTER) failed: $(Libc.strerror(Libc.errno()))"))
    return nothing
end

"""
    set_recv_own_msgs!(sc, enabled::Bool)

Toggle `CAN_RAW_RECV_OWN_MSGS` socket option. When `true`, the socket receives
frames it sends itself. Useful for loopback testing.
"""
function set_recv_own_msgs!(sc::SocketCanDriver, enabled::Bool)
    @atomic(sc.closed) && throw(SocketCANError("set_recv_own_msgs!() on closed SocketCanDriver '$(sc.channelname)'"))
    val = Ref(Cint(enabled ? 1 : 0))
    ret = ccall(:setsockopt, Cint,
        (Cint, Cint, Cint, Ptr{Cint}, UInt32),
        sc.handler, SOL_CAN_RAW, CAN_RAW_RECV_OWN_MSGS,
        val, UInt32(sizeof(Cint)))
    ret < 0 && throw(SocketCANError("setsockopt(CAN_RAW_RECV_OWN_MSGS) failed: $(Libc.strerror(Libc.errno()))"))
    return nothing
end
