# CANInterface.jl Production-Readiness Plan

## Context

CANInterface.jl is a thin SocketCAN FFI wrapper used by SystemSimulator.jl for real-time CAN bus communication. Several safety and robustness gaps make it unsuitable for production: sockets can leak on missed `close()` calls, double-close corrupts unrelated file descriptors, blocking reads force fragile shutdown workarounds (a "wake frame" hack in `runscript.jl`), and the API is inflexible (always extended frames, always DLC=8). This plan addresses these issues in priority order while maintaining full backward compatibility with SystemSimulator.jl.

---

## Phase 1: Critical Safety Fixes

**Files:** `src/socketcaninterface.jl`, `src/CANInterface.jl`, `Project.toml`

### 1a. Add atomic `closed` flag + finalizer to `SocketCanDriver`

```julia
mutable struct SocketCanDriver <: AbstractCanDriver
    channelname::String
    handler::Int32
    @atomic closed::Bool   # NEW
end
```

- Constructor sets `closed = false`, registers `finalizer(_close_fd, sc)`
- New `_close_fd(sc)`: uses `@atomicswap sc.closed = true` — only the first caller actually calls `ccall(:close, ...)`
- `close(sc)` delegates to `_close_fd`
- This makes `close()` idempotent and thread-safe, and prevents fd leaks on GC

### 1b. Add `Base.isopen(sc::SocketCanDriver)`

Returns `!(@atomic sc.closed)` — lets callers check driver state.

### 1c. Guard `read()`/`write()` against closed driver

Throw `SocketCANError("...on closed SocketCanDriver...")` if `@atomic(sc.closed)` is true.

### 1d. Handle EBADF/EINTR gracefully in `read()`

When `close()` is called from another thread while `read()` blocks, the read gets `EBADF` (errno 9). Instead of throwing, return `nothing` for errno 9 (EBADF) and 4 (EINTR). This makes SystemSimulator's `reader_loop` exit cleanly without hitting the catch branch, and **eliminates the need for the wake-frame hack** in `runscript.jl`.

### 1e. Delete standalone `close(fd::Int32)` helper (lines 33-37)

Only used in constructor error paths — replace with inline `ccall(:close, ...)`. Removes a confusing shadow of `Base.close`.

### 1f. Remove unused `Printf` dependency

Delete `using Printf` from `src/CANInterface.jl`, remove from `Project.toml` `[deps]` and `[compat]`.

---

## Phase 2: API Improvements

**File:** `src/socketcaninterface.jl`, `src/CANInterface.jl`

### 2a. Add explicit exports

```julia
export AbstractCanDriver, SocketCanDriver, CanFrameRaw, SocketCANError
export CAN_EFF_FLAG, CAN_MAX_DLC
```

Non-breaking: SystemSimulator uses `import CANInterface as CI` which ignores exports.

### 2b. Support standard (11-bit) frames via `extended` keyword

```julia
write(sc, canid, data::NTuple{8,UInt8}; extended::Bool=true)
```

Default `extended=true` preserves current behavior. When `false`, `CAN_EFF_FLAG` is not ORed in.

### 2c. Support variable DLC (0-8 bytes) in vector overload

Currently requires exactly 8 bytes. Change to accept 0-8 bytes, pad with zeros, set `can_dlc` to actual length. The NTuple overload stays fixed at DLC=8.

### 2d. Add CAN ID validation

Add `CAN_SFF_MASK = 0x7FF` and `CAN_EFF_MASK = 0x1FFFFFFF` constants. Reject IDs with bits set above the 29-bit range (catches accidental flag-bit inclusion).

---

## Phase 3: Non-blocking Read via `poll()`

**File:** `src/socketcaninterface.jl`

Add a `timeout_ms` keyword to `read()`:

```julia
read(sc; timeout_ms::Int=-1) -> CanFrameRaw or nothing
```

- `-1` (default): block indefinitely — **identical to current behavior**
- `0`: pure non-blocking poll
- `>0`: wait up to N milliseconds

Implementation uses `ccall(:poll, ...)` with a `PollFD` struct before the `ccall(:read, ...)`. Returns `nothing` on timeout. This gives SystemSimulator a clean alternative to the close-to-unblock shutdown pattern.

---

## Phase 4: Socket Options (lower priority, can defer)

### 4a. `set_filters!(sc, filters)` — kernel-level CAN ID filtering via `setsockopt`
### 4b. `set_recv_own_msgs!(sc, enabled)` — toggle `CAN_RAW_RECV_OWN_MSGS` (useful for testing)

---

## Test Plan

Add to `test/runtests.jl`:

| Test | Phase | What it verifies |
|------|-------|-----------------|
| Close idempotency | 1 | `close()` twice doesn't throw, `isopen()` transitions |
| Read/write on closed driver | 1 | Throws `SocketCANError` |
| Finalizer runs without crash | 1 | GC a driver without explicit close |
| Variable DLC write | 2 | Short vectors accepted, >8 rejected |
| Standard frame write | 2 | `extended=false` doesn't set EFF flag |
| Non-blocking read timeout | 3 | `read(sc; timeout_ms=50)` returns `nothing` within ~200ms on idle vcan |
| Close unblocks timed read | 3 | Spawned read with timeout returns `nothing` after close from main thread |

Run with: `cd CANInterface.jl && julia --project=. test/runtests.jl`

## Backward Compatibility

All changes are backward-compatible with SystemSimulator.jl — zero modifications needed:
- `CanFrameRaw` struct and field names (`.can_id`, `.can_dlc`, `.data`) unchanged
- `SocketCanDriver(name)` constructor signature unchanged (new `closed` field is internal)
- `read(sc)` with no kwargs blocks as before
- `write(sc, canid, data)` with no kwargs uses `extended=true`, DLC=8 as before
- `close(sc)` still works, now idempotent
