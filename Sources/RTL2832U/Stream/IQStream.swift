// Sustained I/Q acquisition with a sample rate that can change while samples are flowing. A rate change stops the
// queued requests, waits for the last handler to return, retunes the baseband, the tuner filter and the local
// oscillator, clears the converter's offset estimate, flushes the dongle's FIFO and starts a new stream. Every block
// carries the rate it was captured at and an epoch that increases with each reconfiguration, so downstream state can
// be reset at the boundary.

import Foundation
import Dispatch

package final class IQStream: @unchecked Sendable {

    /// Valid only for the duration of the handler call.
    package struct Block {
        package let i: UnsafePointer<Float>
        package let q: UnsafePointer<Float>
        package let count: Int
        package let sampleRate: Double
        package let epoch: Int
        package var acquisition = IQAcquisition()

        package init(i: UnsafePointer<Float>, q: UnsafePointer<Float>, count: Int, sampleRate: Double, epoch: Int,
                     acquisition: IQAcquisition = IQAcquisition()) {
            self.i = i
            self.q = q
            self.count = count
            self.sampleRate = sampleRate
            self.epoch = epoch
            self.acquisition = acquisition
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case alreadyRunning
        case notRunning

        var description: String {
            switch self {
            case .alreadyRunning: "stream is already running"
            case .notRunning: "stream is not running"
            }
        }
    }

    static let blockSeconds = 0.02
    static let queueDepth = 8
    private static let maxBlockSamples = 65_536

    private let demodulator: Demodulator
    private let tuner: R828D
    private let converter: IQConverter
    private var handler: (@Sendable (Block) -> Void)?
    private var discardNext = false
    private var tracker: AcquisitionTracker?
    private var requestedBytes = 0
    /// Called once, from the completion queue, with the IOReturn of the first transfer that failed.
    var onFailure: (@Sendable (Int32) -> Void)?

    private(set) var isRunning = false
    private(set) var sampleRate: Double = 0
    private(set) var centerHz: UInt32 = 0
    private(set) var epoch = 0

    init(demodulator: Demodulator, tuner: R828D, spectrumInverted: Bool = false) {
        self.demodulator = demodulator
        self.tuner = tuner
        converter = IQConverter(capacity: Self.maxBlockSamples, sampleRate: 1, timeConstant: 1)
        converter.spectrumInverted = spectrumInverted
    }

    /// Bytes per request: about `blockSeconds` of samples, rounded to whole 512-byte bulk packets.
    static func blockBytes(sampleRate: Double) -> Int {
        max(512, Int((sampleRate * 2 * blockSeconds / 512).rounded()) * 512)
    }

    func start(sampleRate: UInt32, centerHz: UInt32, handler: @escaping @Sendable (Block) -> Void) throws {
        guard !isRunning else { throw Failure.alreadyRunning }
        self.handler = handler
        self.centerHz = centerHz
        try configure(sampleRate)
        let tracker = AcquisitionTracker(centerHz: centerHz, window: Self.queueDepth)
        tracker.endRetune(to: centerHz, success: true, at: DispatchTime.now().uptimeNanoseconds)
        self.tracker = tracker
        try begin()
    }

    /// Changes the sample rate without stopping the caller's processing. Blocks from the old rate stop arriving before
    /// the first block of the new rate, and the epoch differs between them.
    func setSampleRate(_ rate: UInt32) throws {
        guard isRunning else { throw Failure.notRunning }
        demodulator.transport.stopStream()
        isRunning = false
        try configure(rate)
        try begin()
    }

    /// Reprograms the tuner while samples flow. The blocks captured around the change carry the new tuning generation
    /// and read as unsettled until they began after the transition.
    func retune(to hz: UInt32) throws {
        tracker?.beginRetune()
        do {
            try tuner.setFrequency(hz)
        } catch {
            tracker?.endRetune(to: hz, success: false, at: DispatchTime.now().uptimeNanoseconds)
            throw error
        }
        centerHz = hz
        tracker?.endRetune(to: hz, success: true, at: DispatchTime.now().uptimeNanoseconds)
    }

    /// Stops the stream. The result is false when a handler was still running at the transport's drain deadline.
    @discardableResult
    func stop() -> Bool {
        let drained = demodulator.transport.stopStream()
        isRunning = false
        return drained
    }

    private func configure(_ rate: UInt32) throws {
        tracker?.beginRetune()
        do {
            try tuner.setBandwidth(Int(rate))
            sampleRate = try demodulator.setSampleRate(rate)
            try tuner.setFrequency(centerHz)
        } catch {
            tracker?.endRetune(to: centerHz, success: false, at: DispatchTime.now().uptimeNanoseconds)
            throw error
        }
        tracker?.endRetune(to: centerHz, success: true, at: DispatchTime.now().uptimeNanoseconds)
        converter.sampleRate = sampleRate
        converter.reset()
        epoch += 1
    }

    private func begin() throws {
        try demodulator.resetBuffer()
        discardNext = true
        let blockLength = Self.blockBytes(sampleRate: sampleRate)
        requestedBytes = blockLength
        tracker?.restartClock()
        try demodulator.transport.startStream(blockLength: blockLength, depth: Self.queueDepth,
                                      onFailure: onFailure) { [self] raw in
            deliver(raw)
        }
        isRunning = true
    }

    private func deliver(_ raw: UnsafeRawBufferPointer) {
        let completed = DispatchTime.now().uptimeNanoseconds
        if discardNext {
            discardNext = false
            _ = tracker?.classify(completedNs: completed, samples: raw.count / 2, rate: sampleRate,
                                  requestedBytes: requestedBytes, receivedBytes: raw.count)
            return
        }
        let n = converter.convert(raw)
        let acquisition = tracker?.classify(completedNs: completed, samples: n, rate: sampleRate,
                                            requestedBytes: requestedBytes, receivedBytes: raw.count)
        handler?(Block(i: converter.i, q: converter.q, count: n, sampleRate: sampleRate, epoch: epoch,
                       acquisition: acquisition ?? IQAcquisition()))
    }
}
