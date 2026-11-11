import Foundation
import Testing
@testable import RTL2832U

/// Runs only when a dongle is on the bus, and opens it for a few seconds.
@Suite(.serialized)
struct RadioTests {

    private static let hasDongle = !Dongle.all.isEmpty

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func anUndisturbedStreamIsOneCaptureAtTheRequestedSettings() async throws {
        let radio = try await Dongle.first().open()
        var captures = 0
        var samples = 0
        var peak: Float = 0
        for try await capture in try await radio.receive(frequency: 100_000_000, sampleRate: 2_400_000) {
            captures += 1
            #expect(capture.frequency == 100_000_000)
            #expect(abs(capture.sampleRate - 2_400_000) < 1)
            for try await block in capture {
                samples += block.count
                peak = max(peak, block.i.map(abs).max() ?? 0, block.q.map(abs).max() ?? 0)
                if samples >= 4_800_000 { break }
            }
            break
        }
        radio.close()
        #expect(captures == 1)
        #expect(samples >= 4_800_000)
        #expect(peak > 0 && peak <= 1.01)
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func aRetuneStartsExactlyOneNewCaptureAtTheNewFrequency() async throws {
        let radio = try await Dongle.first().open()
        var seen: [(frequency: Double, blocks: Int)] = []
        var tuned = false
        outer: for try await capture in try await radio.receive(frequency: 100_000_000, sampleRate: 2_400_000) {
            var blocks = 0
            for try await _ in capture {
                blocks += 1
                if !tuned && blocks == 10 {
                    try await radio.tune(to: 101_000_000)
                    tuned = true
                }
                if tuned && capture.frequency == 101_000_000 && blocks == 10 {
                    seen.append((capture.frequency, blocks))
                    break outer
                }
            }
            seen.append((capture.frequency, blocks))
        }
        radio.close()
        #expect(seen.map(\.frequency) == [100_000_000, 101_000_000])
        #expect(seen.allSatisfy { $0.blocks >= 10 })
        #expect(await radio.frequency == 101_000_000)
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func closingEndsTheSequenceWithoutAnError() async throws {
        let radio = try await Dongle.first().open()
        var count = 0
        for try await _ in try await radio.receive(frequency: 100_000_000, sampleRate: 2_400_000).samples {
            count += 1
            if count == 5 { radio.close() }
        }
        #expect(count >= 5)
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func theVGACodeIsTheSameAcrossGainModesAndRetunes() throws {
        let device = try Device(dongle: try Dongle.first(), gain: .automatic, options: Radio.Options())
        defer { device.close() }
        #expect(device.tuner.vgaCode == R828D.defaultVGACode)
        try device.setCenterFrequency(101_000_000)
        #expect(device.tuner.vgaCode == R828D.defaultVGACode)

        try device.setGain(.manual(20))
        #expect(device.tuner.vgaCode == R828D.defaultVGACode)
        try device.setCenterFrequency(433_920_000)
        #expect(device.tuner.vgaCode == R828D.defaultVGACode)

        try device.setGain(.automatic)
        try device.setCenterFrequency(100_000_000)
        #expect(device.tuner.vgaCode == R828D.defaultVGACode)
    }

    private func open(_ frequency: Double = 100_000_000) async throws -> Radio {
        try await Dongle.first().open()
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func everyRetuneStepStartsOneCaptureAtTheNewFrequency() async throws {
        // Steps from 0.2 MHz to 1 GHz, across the Blog V4's HF conversion and the VHF and UHF bands.
        let plan: [Double] = [100_000_000, 100_200_000, 90_000_000, 162_550_000, 433_920_000, 868_000_000,
                              1_090_000_000, 10_000_000, 100_000_000]
        let radio = try await open(plan[0])
        var seen: [Double] = []
        var next = 1
        var blocks = 0
        for try await capture in try await radio.receive(frequency: plan[0], sampleRate: 2_400_000) {
            seen.append(capture.frequency)
            blocks = 0
            for try await block in capture {
                #expect(block.diagnostics.acquisition.centerHz.map(Double.init) == capture.frequency)
                blocks += 1
                if blocks == 6 { break }
            }
            guard next < plan.count else { break }
            try await radio.tune(to: plan[next])
            next += 1
        }
        radio.close()
        #expect(seen == plan, "one capture per frequency, no extra and none missing")
    }

    private func captures(whileStalling stall: Duration) async throws -> Int {
        let radio = try await open()
        let clock = ContinuousClock()
        var started: ContinuousClock.Instant?
        var count = 0
        var blocks = 0
        var stalled = false
        outer: for try await capture in try await radio.receive(frequency: 100_000_000, sampleRate: 2_400_000) {
            count += 1
            for try await _ in capture {
                blocks += 1
                // Fifty blocks is a second in, long after any backlog from opening has been consumed. The router
                // holds eight blocks, so the stall plus the backlog at this point must stay under 160 ms.
                if blocks == 50 && !stalled {
                    stalled = true
                    try await Task.sleep(for: stall)
                    started = clock.now
                }
                if let started, clock.now - started > .seconds(1.5) { break outer }
            }
        }
        radio.close()
        return count
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func aShortConsumerStallLeavesOneCapture() async throws {
        #expect(try await captures(whileStalling: .milliseconds(50)) == 1)
        #expect(try await captures(whileStalling: .milliseconds(120)) == 1)
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func aStallLongerThanTheQueueStartsANewCapture() async throws {
        // Twenty blocks of backlog against a buffer of eight: the control for the test above.
        #expect(try await captures(whileStalling: .milliseconds(400)) > 1)
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func aLongConsumerStallEndsTheCapture() async throws {
        #expect(try await captures(whileStalling: .milliseconds(300)) >= 2)
        #expect(try await captures(whileStalling: .milliseconds(1000)) >= 2)
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    func aSecondOpenIsRefusedAndAClosedOrDroppedRadioReleasesTheDongle() async throws {
        let first = try await open()
        await #expect(throws: RadioError.self) { _ = try await open() }
        first.close()
        let again = try await open()
        again.close()
        await #expect(throws: RadioError.closed) { try await again.tune(to: 101_000_000) }
        // Dropping without close releases the dongle too.
        do { _ = try await open() }
        try await Task.sleep(for: .milliseconds(300))
        let last = try await open()
        last.close()
    }

    /// The longest time the main actor went without running a 1 ms timer while `work` ran.
    @MainActor
    private func worstStall(during work: () async throws -> Void) async throws -> Double {
        let clock = ContinuousClock()
        let ticker = Task { @MainActor () -> Double in
            var worst = 0.0
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                let now = clock.now
                let gap = (now - last).components
                worst = max(worst, Double(gap.seconds) * 1000 + Double(gap.attoseconds) / 1e15)
                last = now
            }
            return worst
        }
        try await Task.sleep(for: .milliseconds(20))
        try await work()
        try await Task.sleep(for: .milliseconds(20))
        ticker.cancel()
        return await ticker.value
    }

    @Test(.enabled(if: RadioTests.hasDongle), .timeLimit(.minutes(1)))
    @MainActor
    func retuningDoesNotBlockTheMainActor() async throws {
        let dongle = try Dongle.first()

        // The instrument's floor, with nothing running.
        let idle = try await worstStall { try await Task.sleep(for: .milliseconds(300)) }

        // Positive control: a tuner call made directly on the main actor must stall the ticker.
        var device: Device? = try Device(dongle: dongle, frequency: 100_000_000, sampleRate: 2_400_000,
                                         gain: .automatic, options: Radio.Options())
        let blocking = try await worstStall { try device!.setCenterFrequency(101_000_000) }
        device = nil
        try await Task.sleep(for: .milliseconds(300))

        let radio = try await open()
        var asynchronous = 0.0
        for frequency in [101_000_000.0, 100_000_000, 101_000_000, 100_000_000] {
            asynchronous = max(asynchronous, try await worstStall { try await radio.tune(to: frequency) })
        }
        radio.close()

        print("main actor worst stall: idle \(idle) ms, direct call \(blocking) ms, Radio.tune \(asynchronous) ms")
        #expect(blocking > 30, "the instrument sees a blocking call")
        #expect(asynchronous < blocking / 2, "an asynchronous retune stalls the main actor far less")
    }

    /// Needs a person: set RTL2832U_UNPLUG_TEST=1 and pull the dongle out within 60 seconds of the test starting.
    @Test(.enabled(if: RadioTests.hasDongle && ProcessInfo.processInfo.environment["RTL2832U_UNPLUG_TEST"] != nil),
          .timeLimit(.minutes(2)))
    func unplugEndsTheSequenceWithAnError() async throws {
        let radio = try await open()
        print("UNPLUG THE DONGLE NOW")
        let clock = ContinuousClock()
        var unplugged: ContinuousClock.Instant?
        var caught: RadioError?
        var blocks = 0
        do {
            for try await block in try await radio.receive(frequency: 100_000_000, sampleRate: 2_400_000).samples {
                blocks += 1
                if blocks == 1 { _ = block }
            }
        } catch {
            caught = error as? RadioError
            unplugged = clock.now
        }
        print("sequence ended after \(blocks) blocks with \(String(describing: caught))",
              "at \(String(describing: unplugged))")
        #expect(caught == .disconnected)
        print("dongles on the bus when the sequence ended: \(Dongle.all.count)")
        await #expect(throws: RadioError.self) { try await radio.tune(to: 101_000_000) }
    }
}
