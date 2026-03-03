using Test
using CANInterface

# Pull internal names into scope for testing
using CANInterface: CanFrameRaw, SockAddrCAN, SocketCANError, SocketCanDriver,
                    CAN_EFF_FLAG, CAN_MAX_DLC, CAN_SFF_MASK, CAN_EFF_MASK,
                    PF_CAN, AF_CAN, SOCK_RAW, CAN_RAW, CanFilter

@testset "CANInterface" begin

    @testset "Constants" begin
        @test PF_CAN  == Cint(29)
        @test AF_CAN  == Cint(29)
        @test SOCK_RAW == Cint(3)
        @test CAN_RAW  == Cint(1)
        @test CAN_EFF_FLAG == UInt32(0x80000000)
        @test CAN_MAX_DLC  == 8
        @test CAN_SFF_MASK == UInt32(0x000007FF)
        @test CAN_EFF_MASK == UInt32(0x1FFFFFFF)
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

    @testset "CAN ID validation" begin
        @test_throws ArgumentError CANInterface._validate_canid(UInt32(0x80000000), true)
        @test_throws ArgumentError CANInterface._validate_canid(UInt32(0x800), false)
        # Valid IDs should not throw
        CANInterface._validate_canid(UInt32(0x1FFFFFFF), true)
        CANInterface._validate_canid(UInt32(0x7FF), false)
    end

    @testset "close idempotency and isopen" begin
        sc = try
            SocketCanDriver("vcan0")
        catch e
            @warn "vcan0 unavailable — skipping close tests: $e"
            nothing
        end
        sc === nothing && return

        @test isopen(sc)
        CANInterface.close(sc)
        @test !isopen(sc)
        # Second close must not throw
        CANInterface.close(sc)
        @test !isopen(sc)
    end

    @testset "read/write on closed driver" begin
        sc = try
            SocketCanDriver("vcan0")
        catch e
            @warn "vcan0 unavailable — skipping closed-driver tests: $e"
            nothing
        end
        sc === nothing && return

        CANInterface.close(sc)
        @test_throws SocketCANError CANInterface.read(sc)
        @test_throws SocketCANError CANInterface.write(sc, UInt32(0x18FF00EF), ntuple(_ -> UInt8(0), 8))
    end

    @testset "finalizer prevents leak" begin
        sc = try
            SocketCanDriver("vcan0")
        catch e
            @warn "vcan0 unavailable — skipping finalizer test: $e"
            nothing
        end
        sc === nothing && return
        # Drop reference and GC — should not crash
        sc = nothing
        GC.gc()
        @test true  # if we reach here, no segfault from double-close
    end

    @testset "write argument validation" begin
        sc = try
            SocketCanDriver("vcan0")
        catch e
            @warn "vcan0 unavailable — skipping write tests: $e"
            nothing
        end
        sc === nothing && return

        try
            # Too many bytes
            @test_throws ArgumentError CANInterface.write(sc, UInt32(0x123), zeros(UInt8, 9))
            # Short vector should succeed (variable DLC)
            CANInterface.write(sc, UInt32(0x123), UInt8[0x01, 0x02, 0x03])
            # Empty vector should succeed
            CANInterface.write(sc, UInt32(0x123), UInt8[])
        finally
            CANInterface.close(sc)
        end
    end

    @testset "non-blocking read timeout" begin
        sc = try
            SocketCanDriver("vcan0")  # no traffic on vcan0
        catch e
            @warn "vcan0 unavailable — skipping timeout test: $e"
            nothing
        end
        sc === nothing && return

        try
            t0 = time()
            result = CANInterface.read(sc; timeout_ms=50)
            elapsed = time() - t0
            @test result === nothing
            @test elapsed < 0.5  # should return after ~50ms, not block forever
        finally
            CANInterface.close(sc)
        end
    end

    @testset "blocking read returns nothing on close from another thread" begin
        sc = try
            SocketCanDriver("vcan0")
        catch e
            @warn "vcan0 unavailable — skipping thread close test: $e"
            nothing
        end
        sc === nothing && return

        result = Ref{Any}(:not_set)
        t = Threads.@spawn begin
            result[] = CANInterface.read(sc; timeout_ms=2000)
        end
        sleep(0.05)
        CANInterface.close(sc)
        wait(t)
        @test result[] === nothing
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
            @test isopen(sc)

            frame = CANInterface.read(sc)
            @test frame isa CanFrameRaw
            @test frame.can_dlc <= UInt8(CAN_MAX_DLC)
        finally
            CANInterface.close(sc)
        end
    end

end
