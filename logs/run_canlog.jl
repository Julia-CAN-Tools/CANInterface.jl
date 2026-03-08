script = joinpath(@__DIR__, "setupVirtualCAN.sh")
run(`sudo bash $script`)

log = joinpath(@__DIR__, "canlog.log")

while true
    run(`canplayer vcan0=can0 vcan1=can1 -I $log`)
end
