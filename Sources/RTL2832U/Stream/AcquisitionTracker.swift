// Classifies each delivered block by the properties of its acquisition that the transfer layer can know: whether the
// transfer was whole, whether the block was captured after the last retune had taken effect, and whether the sample
// clock agrees with the number of samples that arrived. Times are host uptime in nanoseconds; the tracker takes them
// as arguments so that its rules can be exercised with chosen timestamps.

import Synchronization

final class AcquisitionTracker: Sendable {

    /// A block counts as captured after a retune only when it began at least this long after the retune call
    /// returned. On the development dongle the block holding the frequency transition completed at most 4.5 ms after
    /// the call returned (20 retunes of 600 kHz); the margin is twice that.
    static let settleMarginNs: UInt64 = 10_000_000

    /// Shortfalls under this many seconds of signal read as zero. The shortfall of an unloaded stream stayed within
    /// 0.1 ms of zero in the measurements.
    static let shortfallToleranceSeconds = 0.002

    private struct State {
        var generation = 0
        var centerHz: UInt32
        var retuning = false
        var settledAfterNs: UInt64 = 0
        var anchorNs: UInt64?
        var delivered = 0
        var recent: [Double]
        var recentIndex = 0
    }

    private let state: Mutex<State>

    /// - Parameters:
    ///   - centerHz: the frequency the tuner holds when the stream starts.
    ///   - window: the number of recent blocks over which a lateness that later disappears is told apart from a
    ///     persistent shortfall. The queue depth is the natural choice, because a consumer stall the queue absorbs is
    ///     over within that many blocks.
    init(centerHz: UInt32, window: Int) {
        state = Mutex(State(centerHz: centerHz, recent: [Double](repeating: 0, count: max(1, window))))
    }

    /// Restarts the clock comparison, as a new stream begins. The retune generation and frequency carry over.
    func restartClock() {
        state.withLock {
            $0.anchorNs = nil
            $0.delivered = 0
            $0.recentIndex = 0
            for k in $0.recent.indices { $0.recent[k] = 0 }
        }
    }

    func beginRetune() {
        state.withLock {
            $0.generation += 1
            $0.retuning = true
        }
    }

    /// `success` is false when the tuner refused the frequency, in which case it holds an undefined tuning and the
    /// recorded frequency stays as it was.
    func endRetune(to hz: UInt32, success: Bool, at nowNs: UInt64) {
        state.withLock {
            $0.retuning = false
            if success { $0.centerHz = hz }
            $0.settledAfterNs = nowNs + Self.settleMarginNs
        }
    }

    /// - Parameters:
    ///   - completedNs: when the transfer completed.
    ///   - samples: the complex samples the block holds.
    ///   - rate: the sample rate in samples per second.
    ///   - requestedBytes: the length of the request.
    ///   - receivedBytes: the bytes the transfer moved.
    func classify(completedNs: UInt64, samples: Int, rate: Double, requestedBytes: Int,
                  receivedBytes: Int) -> IQAcquisition {
        state.withLock { st in
            let duration = UInt64(Double(samples) / rate * 1e9)
            let startedNs = completedNs &- duration
            let settled = !st.retuning && startedNs >= st.settledAfterNs

            var shortfall = 0
            if let anchor = st.anchorNs {
                st.delivered += samples
                let deficit = rate * Double(completedNs &- anchor) / 1e9 - Double(st.delivered)
                st.recent[st.recentIndex % st.recent.count] = deficit
                st.recentIndex += 1
                let persistent = max(0, st.recent.min() ?? 0)
                shortfall = persistent < Self.shortfallToleranceSeconds * rate ? 0 : Int(persistent)
            } else {
                st.anchorNs = completedNs
                for k in st.recent.indices { st.recent[k] = 0 }
            }
            return IQAcquisition(tuningGeneration: st.generation, centerHz: st.centerHz,
                                 transferComplete: receivedBytes == requestedBytes, tuningSettled: settled,
                                 clockShortfallSamples: shortfall)
        }
    }
}
