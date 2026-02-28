# Helper C structs
const PF_CAN = Cint(29)
const AF_CAN = Cint(29)
const SOCK_RAW = Cint(3)
const CAN_RAW = Cint(1)
const CAN_EFF_FLAG = UInt32(0x80000000)
const CAN_MAX_DLC = 8

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

struct SocketCANError <: Exception
    msg::String
end

function close(fd::Int32)
    fd >=0 || return nothing
    ccall(:close, Cint, (Cint,), Cint(fd))
    return nothing
end

mutable struct SocketCanDriver <: AbstractCanDriver
    channelname::String
    handler::Int32

    function SocketCanDriver(channelname::String)
        handler = ccall(:socket, Cint, (Cint, Cint, Cint), PF_CAN, SOCK_RAW, CAN_RAW)
        handler < 0 && throw(SocketCANError("socket() failed: $(strerror(Libc.errno()))"))

        index = ccall(:if_nametoindex, UInt32, (Cstring,), channelname)
        if index == 0
            close(handler)
            throw(SocketCANError("if_nametoindex('$channelname') failed: $(strerror(Libc.errno()))"))
        end
        addrRef = Ref{SockAddrCAN}(SockAddrCAN(UInt16(AF_CAN), UInt16(0), Cint(index), ntuple(_->UInt8(0), 8)))
        bindres = ccall(:bind, Cint, (Cint, Ptr{SockAddrCAN}, UInt32), handler, addrRef, UInt32(sizeof(SockAddrCAN)))

        if bindres < 0
            close(handler)
            throw(SocketCANError("bind() failed on '$channelname': $(strerror(Libc.errno()))"))
        end

        return new(channelname, handler)
    end
end

function close(sc::SocketCanDriver)
    sc.handler >=0 || return nothing
    ccall(:close, Cint, (Cint,), Cint(sc.handler))
    return nothing
end

function read(sc::SocketCanDriver)
    raw = Ref{CanFrameRaw}()
    nbytes = ccall(:read, Cssize_t, (Cint, Ptr{CanFrameRaw}, Csize_t), Cint(sc.handler), raw, Csize_t(sizeof(CanFrameRaw)))
    if nbytes == sizeof(CanFrameRaw)
        frame = raw[]
        return frame
    elseif nbytes == 0
        return nothing
    else
        if nbytes < 0
            err = Libc.errno()
            throw(SocketCANError("read() failed: $(strerror(err))"))
        end
        return nothing
    end
end

function write(sc::SocketCanDriver, canid::UInt32, data::NTuple{8, UInt8})
    raw = Ref{CanFrameRaw}(CanFrameRaw(canid | CAN_EFF_FLAG, UInt8(CAN_MAX_DLC), 0x00, 0x00, 0x00, data))
    nbytes = ccall(:write, Cssize_t, (Cint, Ptr{CanFrameRaw}, Csize_t), Cint(sc.handler), raw, Csize_t(sizeof(CanFrameRaw)))
    if nbytes != sizeof(CanFrameRaw)
        err = Libc.errno()
        throw(SocketCANError("write() failed: $(strerror(err))"))
    end
    return nothing
end

function write(sc::SocketCanDriver, canid::UInt32, data::AbstractVector{UInt8})
    length(data) == CAN_MAX_DLC || throw(ArgumentError("CAN frames must have $CAN_MAX_DLC bytes"))
    bytes = ntuple(i-> UInt8(data[i]), CAN_MAX_DLC)
    return write(sc, canid, bytes)
end