module CANInterface

using Printf

abstract type AbstractCanDriver end

include("socketcaninterface.jl")

end # module CANInterface
