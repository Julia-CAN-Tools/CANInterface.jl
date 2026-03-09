module CANInterface

abstract type AbstractCanDriver end

using PrecompileTools

include("socketcaninterface.jl")

export AbstractCanDriver, SocketCanDriver, CanFrameRaw, SocketCANError
export CanFilter, CAN_EFF_FLAG, CAN_MAX_DLC, CAN_SFF_MASK, CAN_EFF_MASK

@compile_workload begin
    # Pure functions — always run during precompile
    _validate_canid(UInt32(0x18FEF100), true)
    _validate_canid(UInt32(0x7FF), false)
    CanFrameRaw(UInt32(0x98FEF100), UInt8(8), 0x00, 0x00, 0x00, ntuple(_ -> UInt8(0), 8))
    CanFilter(UInt32(0x18FEF100), CAN_EFF_MASK)

    # Socket I/O — gracefully skipped if vcan0 is unavailable (e.g. CI)
    try
        sc = SocketCanDriver("vcan0")
        write(sc, UInt32(0x18FEF100), ntuple(_ -> UInt8(0), 8))
        write(sc, UInt32(0x18FEF100), UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        read(sc; timeout_ms=0)
        Base.isopen(sc)
        set_recv_own_msgs!(sc, false)
        set_filters!(sc, CanFilter[CanFilter(UInt32(0x18FEF100), CAN_EFF_MASK)])
        close(sc)
    catch
    end
end

end # module CANInterface
