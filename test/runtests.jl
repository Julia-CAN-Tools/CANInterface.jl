using Test
using CANInterface

# Pull internal names into scope for testing
using CANInterface: CanFrameRaw, SockAddrCAN, SocketCANError, SocketCanDriver,
                    CAN_EFF_FLAG, CAN_MAX_DLC, PF_CAN, AF_CAN, SOCK_RAW, CAN_RAW

@testset "CANInterface" begin

    @testset "Constants" begin
        @test PF_CAN  == Cint(29)
        @test AF_CAN  == Cint(29)
        @test SOCK_RAW == Cint(3)
        @test CAN_RAW  == Cint(1)
        @test CAN_EFF_FLAG == UInt32(0x80000000)
        @test CAN_MAX_DLC  == 8
    end

    @testset "Struct sizes" begin
        @test sizeof(SockAddrCAN) == 16
        @test sizeof(CanFrameRaw) == 16
    end

    @testset "SocketCANError" begin
        err = SocketCANError("test error")
        @test err isa Exception
        @test err.msg == "test error"
    end

    @testset "write argument validation" begin
        # The vector overload checks length before touching the socket.
        sc = SocketCanDriver("vcan1")
        try
            @test_throws ArgumentError CANInterface.write(sc, UInt32(0x18FF00EF), UInt8[0x01, 0x02])
        finally
            CANInterface.close(sc)
        end
    end

    @testset "vcan1 integration" begin
        # Requires a CAN log replaying on vcan1 (e.g. canplayer vcan1=can1 -I logfile)
        sc = try
            SocketCanDriver("vcan1")
        catch e
            @warn "vcan1 unavailable — skipping integration tests: $e"
            nothing
        end

        sc === nothing && return

        try
            @test sc isa SocketCanDriver
            @test sc.channelname == "vcan1"
            @test sc.handler >= 0

            frame = CANInterface.read(sc)
            @test frame isa CanFrameRaw
            @test frame.can_dlc <= UInt8(CAN_MAX_DLC)
        finally
            CANInterface.close(sc)
        end
    end

end
