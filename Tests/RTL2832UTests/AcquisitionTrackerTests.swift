import Testing
@testable import RTL2832U

struct AcquisitionTrackerTests {

    private let rate = 2_400_000.0
    private let block = 48_000                         // 20 ms
    private let blockNs: UInt64 = 20_000_000
    private let bytes = 96_000

    private func classify(_ tracker: AcquisitionTracker, at completedNs: UInt64,
                          bytes got: Int? = nil) -> IQAcquisition {
        tracker.classify(completedNs: completedNs, samples: block, rate: rate, requestedBytes: bytes,
                         receivedBytes: got ?? bytes)
    }

    /// Feeds `count` on-time blocks starting after the anchor block at `start`.
    @discardableResult
    private func steady(_ tracker: AcquisitionTracker, from start: UInt64, count: Int) -> IQAcquisition {
        var last = IQAcquisition()
        for k in 1...count { last = classify(tracker, at: start + UInt64(k) * blockNs) }
        return last
    }

    @Test func unloadedStreamIsCleanAndKeepsItsGeneration() {
        let tracker = AcquisitionTracker(centerHz: 100_000_000, window: 8)
        tracker.endRetune(to: 100_000_000, success: true, at: 0)
        _ = classify(tracker, at: 1_000_000_000)
        let last = steady(tracker, from: 1_000_000_000, count: 50)
        #expect(last == IQAcquisition(tuningGeneration: 0, centerHz: 100_000_000))
    }

    @Test func blocksAroundARetuneAreUnsettledUntilOneBlockAfterTheMargin() {
        let tracker = AcquisitionTracker(centerHz: 90_400_000, window: 8)
        tracker.endRetune(to: 90_400_000, success: true, at: 0)
        var t: UInt64 = 1_000_000_000
        _ = classify(tracker, at: t)
        tracker.beginRetune()
        t += blockNs
        let during = classify(tracker, at: t)                       // completes while the call is running
        #expect(during.tuningGeneration == 1 && !during.tuningSettled)
        tracker.endRetune(to: 91_000_000, success: true, at: t + 3_000_000)   // the call returned 3 ms after that block
        t += blockNs
        let straddling = classify(tracker, at: t)                   // began 3 ms before the return
        #expect(straddling.centerHz == 91_000_000 && !straddling.tuningSettled)
        t += blockNs
        #expect(classify(tracker, at: t).tuningSettled, "began 17 ms after the return, past the 10 ms margin")
    }

    @Test func blockStartingInsideTheMarginIsUnsettled() {
        let tracker = AcquisitionTracker(centerHz: 1, window: 8)
        tracker.endRetune(to: 1, success: true, at: 0)
        _ = classify(tracker, at: 1_000_000_000)
        tracker.beginRetune()
        tracker.endRetune(to: 2, success: true, at: 1_100_000_000)
        // completes 25 ms after the return: began 5 ms after it, inside the 10 ms margin
        #expect(!classify(tracker, at: 1_125_000_000).tuningSettled)
        // completes 35 ms after the return: began 15 ms after it
        #expect(classify(tracker, at: 1_135_000_000).tuningSettled)
    }

    @Test func aRefusedFrequencyKeepsTheOldCenterAndStaysUnsettledForTheMargin() {
        let tracker = AcquisitionTracker(centerHz: 100, window: 8)
        tracker.endRetune(to: 100, success: true, at: 0)
        _ = classify(tracker, at: 1_000_000_000)
        tracker.beginRetune()
        tracker.endRetune(to: 200, success: false, at: 1_050_000_000)
        let block = classify(tracker, at: 1_060_000_000)
        #expect(block.centerHz == 100 && block.tuningGeneration == 1 && !block.tuningSettled)
    }

    @Test func aShortTransferIsFlagged() {
        let tracker = AcquisitionTracker(centerHz: 1, window: 8)
        tracker.endRetune(to: 1, success: true, at: 0)
        _ = classify(tracker, at: 1_000_000_000)
        #expect(!classify(tracker, at: 1_020_000_000, bytes: bytes - 512).transferComplete)
    }

    @Test func aStallTheQueueAbsorbsLeavesNoShortfall() {
        let tracker = AcquisitionTracker(centerHz: 1, window: 8)
        tracker.endRetune(to: 1, success: true, at: 0)
        var t: UInt64 = 1_000_000_000
        _ = classify(tracker, at: t)
        for _ in 0..<10 { t += blockNs; _ = classify(tracker, at: t) }
        // the consumer stalls 100 ms; the four queued blocks then arrive back to back and the stream is on time again
        var shortfalls: [Int] = []
        let resume = t + 100_000_000
        for k in 1...30 {
            let nominal = t + UInt64(k) * blockNs
            shortfalls.append(classify(tracker, at: max(nominal, k <= 5 ? resume : nominal)).clockShortfallSamples)
        }
        #expect(shortfalls.allSatisfy { $0 == 0 })
    }

    @Test func theWindowIsWhatTellsAbsorbedLatenessFromLoss() {
        // The same absorbed stall read through a one-block window shows the transient lateness as a shortfall, so the
        // zero readings of the eight-block window come from the persistence rule and not from the scenario.
        let tracker = AcquisitionTracker(centerHz: 1, window: 1)
        tracker.endRetune(to: 1, success: true, at: 0)
        var t: UInt64 = 1_000_000_000
        _ = classify(tracker, at: t)
        for _ in 0..<10 { t += blockNs; _ = classify(tracker, at: t) }
        let resume = t + 100_000_000
        var peak = 0
        for k in 1...30 {
            let nominal = t + UInt64(k) * blockNs
            peak = max(peak, classify(tracker, at: max(nominal, k <= 5 ? resume : nominal)).clockShortfallSamples)
        }
        #expect(peak > Int(0.05 * rate))
    }

    @Test func aLossTheQueueCannotAbsorbReadsAsAPersistentShortfallAboutAQueueDepthLater() {
        let tracker = AcquisitionTracker(centerHz: 1, window: 8)
        tracker.endRetune(to: 1, success: true, at: 0)
        var t: UInt64 = 1_000_000_000
        _ = classify(tracker, at: t)
        for _ in 0..<10 { t += blockNs; _ = classify(tracker, at: t) }
        t += 200_000_000                                            // 200 ms of samples never arrive
        var readings: [Int] = []
        for _ in 0..<12 { t += blockNs; readings.append(classify(tracker, at: t).clockShortfallSamples) }
        #expect(readings.prefix(7).allSatisfy { $0 == 0 }, "the window still holds on-time blocks")
        let settled = readings.last ?? 0
        #expect(abs(Double(settled) - 0.2 * rate) < 0.001 * rate, "the shortfall equals the lost 200 ms to 1 ms")
    }

    @Test func aRestartedClockForgetsEarlierShortfall() {
        let tracker = AcquisitionTracker(centerHz: 1, window: 4)
        tracker.endRetune(to: 1, success: true, at: 0)
        var t: UInt64 = 1_000_000_000
        _ = classify(tracker, at: t)
        t += 500_000_000
        for _ in 0..<6 { t += blockNs; _ = classify(tracker, at: t) }
        tracker.restartClock()
        _ = classify(tracker, at: t + blockNs)
        #expect(steady(tracker, from: t + blockNs, count: 10).clockShortfallSamples == 0)
    }
}
