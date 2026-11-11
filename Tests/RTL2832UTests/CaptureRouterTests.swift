import Foundation
import Testing
@testable import RTL2832U

/// The router turns raw blocks into captures. Each test feeds blocks whose acquisition record is chosen, because the
/// conditions the router reacts to cannot be produced on demand with the dongle: a short transfer has not occurred on
/// hardware, and a loss needs a stall longer than the queue covers. The clean stream is the control for every other
/// test: a router that split captures spuriously would fail it.
struct CaptureRouterTests {

    private struct Seen {
        var frequency: Double
        var sampleRate: Double
        var values: [Float]
    }

    private func feed(_ router: CaptureRouter, _ value: Float, generation: Int = 0, epoch: Int = 1,
                      centerHz: UInt32 = 100_000_000, rate: Double = 2_400_000, settled: Bool = true,
                      complete: Bool = true, shortfall: Int = 0) {
        let i = [Float](repeating: value, count: 4)
        let q = [Float](repeating: -value, count: 4)
        i.withUnsafeBufferPointer { ip in
            q.withUnsafeBufferPointer { qp in
                router.accept(IQStream.Block(
                    i: ip.baseAddress!, q: qp.baseAddress!, count: 4, sampleRate: rate, epoch: epoch,
                    acquisition: IQAcquisition(tuningGeneration: generation, centerHz: centerHz,
                                               transferComplete: complete, tuningSettled: settled,
                                               clockShortfallSamples: shortfall)))
            }
        }
    }

    private func collect(_ router: CaptureRouter) async throws -> [Seen] {
        var result: [Seen] = []
        for try await capture in router.captures {
            var seen = Seen(frequency: capture.frequency, sampleRate: capture.sampleRate, values: [])
            for try await block in capture { seen.values.append(block.i[0]) }
            result.append(seen)
        }
        return result
    }

    @Test func aCleanStreamIsOneCapture() async throws {
        let router = CaptureRouter()
        for value in 1...6 { feed(router, Float(value)) }
        router.finish()
        let captures = try await collect(router)
        #expect(captures.count == 1)
        #expect(captures[0].values == [1, 2, 3, 4, 5, 6])
        #expect(captures[0].frequency == 100_000_000)
        #expect(captures[0].sampleRate == 2_400_000)
    }

    @Test func aRetuneEndsTheCaptureAndTheNewOneCarriesTheNewFrequency() async throws {
        let router = CaptureRouter()
        feed(router, 1)
        feed(router, 2)
        feed(router, 3, generation: 1, centerHz: 101_000_000, settled: false)
        feed(router, 4, generation: 1, centerHz: 101_000_000, settled: false)
        feed(router, 5, generation: 1, centerHz: 101_000_000)
        feed(router, 6, generation: 1, centerHz: 101_000_000)
        router.finish()
        let captures = try await collect(router)
        #expect(captures.count == 2)
        #expect(captures[0].values == [1, 2])
        #expect(captures[1].values == [5, 6], "blocks that may overlap the retune are withheld")
        #expect(captures[1].frequency == 101_000_000)
    }

    @Test func aShortTransferIsWithheldAndEndsTheCapture() async throws {
        let router = CaptureRouter()
        feed(router, 1)
        feed(router, 2, complete: false)
        feed(router, 3)
        router.finish()
        let captures = try await collect(router)
        #expect(captures.map(\.values) == [[1], [3]])
    }

    @Test func aRateChangeStartsACaptureAtTheNewRate() async throws {
        let router = CaptureRouter()
        feed(router, 1)
        feed(router, 2, epoch: 2, rate: 1_000_000)
        router.finish()
        let captures = try await collect(router)
        #expect(captures.map(\.values) == [[1], [2]])
        #expect(captures.map(\.sampleRate) == [2_400_000, 1_000_000])
    }

    @Test func aDetectedLossStartsANewCapture() async throws {
        let router = CaptureRouter()
        feed(router, 1)
        feed(router, 2)
        feed(router, 3, shortfall: 4_800)
        feed(router, 4, shortfall: 4_800)
        router.finish()
        let captures = try await collect(router)
        #expect(captures.map(\.values) == [[1, 2], [3, 4]])
    }

    @Test func aConstantShortfallDoesNotSplitTheCapture() async throws {
        let router = CaptureRouter()
        feed(router, 1, shortfall: 4_800)
        feed(router, 2, shortfall: 4_800)
        feed(router, 3, shortfall: 4_800)
        router.finish()
        let captures = try await collect(router)
        #expect(captures.count == 1, "only a rise in the shortfall is a new loss")
    }

    @Test func aConsumerThatFallsBehindGetsANewCaptureAndNeverSeesAGapInsideOne() async throws {
        let router = CaptureRouter(buffering: 2)
        for value in 1...6 { feed(router, Float(value)) }
        router.finish()
        let captures = try await collect(router)
        // The queue keeps the newest two blocks, so each capture holds consecutive blocks and the discarded ones
        // fall between captures.
        #expect(captures.map(\.values) == [[2, 3], [5, 6]])
    }

    @Test func aFailureEndsTheConsumersLoopWithThatError() async throws {
        let router = CaptureRouter()
        feed(router, 1)
        router.finish(throwing: RadioError.disconnected)
        var caught: RadioError?
        do {
            for try await capture in router.captures {
                for try await _ in capture {}
            }
        } catch {
            caught = error as? RadioError
        }
        #expect(caught == .disconnected)
    }

    @Test func theFlatViewYieldsEveryBlockAcrossCaptures() async throws {
        let router = CaptureRouter()
        feed(router, 1)
        feed(router, 2, generation: 1, centerHz: 101_000_000)
        feed(router, 3, generation: 1, centerHz: 101_000_000)
        router.finish()
        var values: [Float] = []
        for try await block in Samples(captures: router.captures) { values.append(block.i[0]) }
        #expect(values == [1, 2, 3])
    }

    @Test func eachBlockCarriesItsCapturesFrequency() async throws {
        let router = CaptureRouter()
        feed(router, 1, centerHz: 100_000_000)
        feed(router, 2, generation: 1, centerHz: 101_000_000)
        router.finish()
        var frequencies: [Double?] = []
        for try await block in Samples(captures: router.captures) { frequencies.append(block.frequency) }
        #expect(frequencies == [100_000_000, 101_000_000])
    }
}
