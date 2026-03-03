module CANInterface

abstract type AbstractCanDriver end

include("socketcaninterface.jl")

export AbstractCanDriver, SocketCanDriver, CanFrameRaw, SocketCANError
export CanFilter, CAN_EFF_FLAG, CAN_MAX_DLC, CAN_SFF_MASK, CAN_EFF_MASK

end # module CANInterface
