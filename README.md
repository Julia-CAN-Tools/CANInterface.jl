# CANInterface.jl

Julia bindings for Linux SocketCAN. Provides raw CAN frame read/write over
virtual or physical CAN interfaces.

**Requirements:** Linux with SocketCAN support, Julia >= 1.7.

## Setup

CANInterface.jl is an unregistered local package. Add it by path:

```julia
using Pkg
Pkg.develop(path="/path/to/CANInterface.jl")
```

Or use it directly with `--project`:

```julia
julia --project=/path/to/CANInterface.jl
```

### Virtual CAN (for development/testing)

```bash
sudo modprobe vcan
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0
```

## Quick Start

```julia
using CANInterface

# Open a CAN interface
sc = SocketCanDriver("vcan0")

# Write a J1939-style extended frame (29-bit ID, 8 bytes)
CANInterface.write(sc, UInt32(0x18FF00EF), (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08))

# Read a frame (blocks until one arrives)
frame = CANInterface.read(sc)
if frame !== nothing
    println("ID: 0x$(string(frame.can_id, base=16))  DLC: $(frame.can_dlc)  Data: $(frame.data)")
end

# Always close when done
CANInterface.close(sc)
```

## API Reference

### Types

#### `AbstractCanDriver`

Abstract supertype for all CAN drivers. Subtype this to implement a custom
transport backend.

#### `SocketCanDriver <: AbstractCanDriver`

Concrete driver wrapping a Linux SocketCAN raw socket.

```julia
sc = SocketCanDriver(channelname::String)
```

Creates a `CAN_RAW` socket, resolves the interface by name, and binds to it.
Throws `SocketCANError` if the interface doesn't exist or the socket can't be
created.

**Fields** (read-only in practice):

| Field         | Type     | Description                      |
|---------------|----------|----------------------------------|
| `channelname` | `String` | Interface name (e.g. `"vcan0"`)  |
| `handler`     | `Int32`  | Underlying file descriptor       |

**Lifecycle:**

- A GC finalizer is registered automatically, so sockets won't leak even if
  you forget to call `close()`. However, explicit `close()` is recommended for
  deterministic cleanup.
- `close()` is idempotent and thread-safe — calling it multiple times is fine.

#### `CanFrameRaw`

Immutable struct matching the Linux `struct can_frame` layout (16 bytes).

| Field     | Type              | Description                                    |
|-----------|-------------------|------------------------------------------------|
| `can_id`  | `UInt32`          | CAN ID with flag bits (EFF, RTR, ERR)          |
| `can_dlc` | `UInt8`           | Data length code (0-8)                         |
| `data`    | `NTuple{8,UInt8}` | Payload bytes (only first `can_dlc` are valid) |

To extract the raw 29-bit ID without flags:

```julia
raw_id = frame.can_id & CAN_EFF_MASK    # 0x1FFFFFFF
```

To check if it's an extended frame:

```julia
is_extended = (frame.can_id & CAN_EFF_FLAG) != 0
```

#### `CanFilter`

Kernel-level receive filter. Used with `set_filters!()`.

```julia
CanFilter(can_id::UInt32, can_mask::UInt32)
```

A frame is accepted if `(received_id & can_mask) == (can_id & can_mask)`.

#### `SocketCANError <: Exception`

Thrown on socket operation failures. Contains a human-readable `msg` field
with the underlying `strerror()` output.

```julia
try
    sc = SocketCanDriver("nonexistent0")
catch e::SocketCANError
    println(e.msg)  # "if_nametoindex('nonexistent0') failed: No such device"
end
```

### Constants

| Constant       | Value          | Description                           |
|----------------|----------------|---------------------------------------|
| `CAN_EFF_FLAG` | `0x80000000`   | Extended frame format flag bit        |
| `CAN_MAX_DLC`  | `8`            | Maximum data bytes per CAN 2.0 frame  |
| `CAN_SFF_MASK` | `0x000007FF`   | 11-bit standard ID mask               |
| `CAN_EFF_MASK` | `0x1FFFFFFF`   | 29-bit extended ID mask               |

---

### Functions

#### `CANInterface.read`

```julia
read(sc::SocketCanDriver; timeout_ms::Int = -1) -> CanFrameRaw | nothing
```

Read one CAN frame from the socket.

**`timeout_ms` behavior:**

| Value | Behavior                                           |
|-------|----------------------------------------------------|
| `-1`  | Block indefinitely until a frame arrives (default) |
| `0`   | Non-blocking: return immediately if nothing queued |
| `> 0` | Wait up to N milliseconds, then return `nothing`   |

**Returns:** `CanFrameRaw` on success, `nothing` on timeout/EOF/closed socket.

**Throws:** `SocketCANError` on real I/O errors (but NOT on EBADF/EINTR, which
return `nothing` for clean shutdown support).

```julia
# Blocking read (waits forever)
frame = CANInterface.read(sc)

# Poll with 100ms timeout
frame = CANInterface.read(sc; timeout_ms=100)
if frame === nothing
    println("No frame within 100ms")
end

# Non-blocking check
frame = CANInterface.read(sc; timeout_ms=0)
```

#### `CANInterface.write`

```julia
write(sc, canid::UInt32, data::NTuple{8,UInt8};   extended::Bool = true)
write(sc, canid::UInt32, data::AbstractVector{UInt8}; extended::Bool = true)
```

Write a CAN frame to the socket.

**Parameters:**

| Parameter  | Description                                                       |
|------------|-------------------------------------------------------------------|
| `canid`    | Raw CAN ID (11- or 29-bit). Do NOT include `CAN_EFF_FLAG` bits.  |
| `data`     | Payload — 8-byte tuple, or 0-8 byte vector (padded to 8 bytes)   |
| `extended` | When `true` (default), ORs `CAN_EFF_FLAG` into the ID on the wire |

**Throws:** `SocketCANError` on write failure, `ArgumentError` on invalid ID
or data length > 8.

```julia
# Extended frame (29-bit ID) — default
CANInterface.write(sc, UInt32(0x18FF00EF), (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08))

# Standard frame (11-bit ID)
CANInterface.write(sc, UInt32(0x7DF), UInt8[0x02, 0x01, 0x00]; extended=false)

# Vector payload — variable length (0-8 bytes), zero-padded
CANInterface.write(sc, UInt32(0x123), UInt8[0xDE, 0xAD]; extended=false)
```

#### `CANInterface.close`

```julia
close(sc::SocketCanDriver) -> nothing
```

Close the underlying socket. Idempotent and thread-safe — safe to call from
any thread, multiple times. After closing, `read()` and `write()` will throw
`SocketCANError`.

If a `read()` is blocking on another thread when `close()` is called, the read
returns `nothing` (does not throw).

#### `Base.isopen`

```julia
isopen(sc::SocketCanDriver) -> Bool
```

Returns `true` if the driver has not been closed.

#### `set_filters!`

```julia
set_filters!(sc::SocketCanDriver, filters::AbstractVector{CanFilter}) -> nothing
```

Apply kernel-level CAN ID filters. After calling this, only frames matching
at least one filter are delivered to `read()`. This is more efficient than
filtering in userspace because the kernel drops non-matching frames before
they reach your process.

```julia
# Only receive frames with ID 0x18FEF100 (mask out source address byte)
filters = [CanFilter(UInt32(0x18FEF100), UInt32(0x1FFFFF00))]
set_filters!(sc, filters)

# Accept two specific IDs
filters = [
    CanFilter(UInt32(0x0CF00400), UInt32(0x1FFFFFFF)),  # EEC1
    CanFilter(UInt32(0x18FEF100), UInt32(0x1FFFFFFF)),  # CCVS
]
set_filters!(sc, filters)

# Remove all filters (receive everything again)
set_filters!(sc, CanFilter[])
```

#### `set_recv_own_msgs!`

```julia
set_recv_own_msgs!(sc::SocketCanDriver, enabled::Bool) -> nothing
```

Toggle whether the socket receives frames that it sends itself. Off by default
in SocketCAN. Useful for loopback testing where a single socket both writes
and reads.

```julia
set_recv_own_msgs!(sc, true)
CANInterface.write(sc, UInt32(0x123), ntuple(_ -> UInt8(0), 8))
frame = CANInterface.read(sc; timeout_ms=100)  # receives its own write
```

---

## Usage Patterns

### Basic read loop with timeout

```julia
sc = SocketCanDriver("vcan0")
try
    while true
        frame = CANInterface.read(sc; timeout_ms=100)
        frame === nothing && continue
        # process frame...
        println("0x$(string(frame.can_id & CAN_EFF_MASK, base=16, pad=8)): $(frame.data)")
    end
finally
    CANInterface.close(sc)
end
```

### Multi-threaded read/write with clean shutdown

```julia
sc = SocketCanDriver("vcan0")

# Reader on a background thread — uses timeout to check for shutdown
stop = Threads.Atomic{Bool}(false)
reader = Threads.@spawn begin
    while !stop[]
        frame = CANInterface.read(sc; timeout_ms=200)
        frame === nothing && continue
        println("RX: 0x$(string(frame.can_id & CAN_EFF_MASK, base=16))")
    end
end

sleep(5.0)

# Shutdown: set flag, close socket, wait for reader
stop[] = true
CANInterface.close(sc)
wait(reader)
```

### Filtered receive (kernel-level)

```julia
sc = SocketCanDriver("can0")

# Only receive EEC1 messages (PGN 0xF004, any source address)
filters = [CanFilter(UInt32(0x0CF00400), UInt32(0x1FFFFF00))]
set_filters!(sc, filters)

frame = CANInterface.read(sc)  # blocks until an EEC1 frame arrives
```

### Loopback test (single socket write+read)

```julia
sc = SocketCanDriver("vcan0")
set_recv_own_msgs!(sc, true)

data = ntuple(i -> UInt8(i), 8)
CANInterface.write(sc, UInt32(0x123), data; extended=false)

frame = CANInterface.read(sc; timeout_ms=100)
@assert frame !== nothing
@assert frame.data == data
CANInterface.close(sc)
```

---

## Testing

```bash
cd CANInterface.jl
julia --project=. test/runtests.jl
```

Most tests require virtual CAN interfaces. Set them up first:

```bash
sudo modprobe vcan
for i in 0 1; do
    sudo ip link add dev vcan$i type vcan
    sudo ip link set up vcan$i
done
```

The `vcan1` integration test expects live CAN traffic (e.g. from `canplayer`).
Tests that need unavailable interfaces are skipped with a warning — they don't
fail.
