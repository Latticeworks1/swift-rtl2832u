import Foundation
import Synchronization

/// An open dongle. `Dongle.open` claims it and identifies its chips, `receive` starts a stream of samples, and
/// `close` releases it. Its controls are asynchronous and run on a queue of their own, so calling one from the main
/// actor does not block it, and they apply whether or not a stream is running.
///
/// The driver decides what it can about the samples. Blocks that overlap a retune or arrive short are withheld, and a
/// removal or a failed transfer ends the sequence by throwing from the loop that reads it.
public actor Radio {

    /// Settings that are properties of the board and the connection and not of a reception.
    public struct Options: Sendable {
        /// The board the dongle is built on, which sets the tuner's reference clock and antenna switching.
        public var board = Board.blogV4
        /// The tuner's reference clock in hertz, or nil for the board's own: 28.8 MHz for the Blog V4 and 16 MHz for
        /// a generic dongle.
        public var referenceHz: UInt32?
        /// The reference clock's frequency error in parts per million, which scales the clocks derived from it.
        public var correctionPPM = 0.0
        /// The tuner's filter bandwidth in hertz, or nil to match the sample rate.
        public var bandwidth: Double?
        /// Powers the antenna port for an active antenna. Switched off again when the radio closes.
        public var biasTee = false
        /// The demodulator's gain loop after the ADC, separate from the tuner's own gain.
        public var digitalAGC = false

        public init() {}

        var bandwidthHz: UInt32? { bandwidth.flatMap { try? wholeHertz($0, RadioError.unsupportedSampleRate) } }

        /// The tuner's board profile. The reference and the board profile are independent: an explicit reference
        /// replaces the board default and the HF conversion stays with the board. The correction scales the reference.
        var tunerBoard: R828D.Board {
            let base: R828D.Board = board == .generic ? .generic : .blogV4
            let reference = Double(referenceHz ?? base.referenceHz) * (1 + correctionPPM / 1e6)
            return R828D.Board(referenceHz: UInt32(reference.rounded()), hfConversionHz: base.hfConversionHz,
                               rfPath: base.rfPath)
        }

        /// The reference clock the tuner PLL runs from, after the board default and the correction.
        public var tunerReferenceHz: UInt32 { tunerBoard.referenceHz }
    }

    /// Whether the demodulator's resampler can realize this sample rate.
    public static func supports(sampleRate: UInt32) -> Bool { Demodulator.isSupportedRate(sampleRate) }

    /// The dongle this radio holds.
    public nonisolated let dongle: Dongle

    private let queue: DispatchSerialQueue
    private let device: Device
    private let closed = Atomic<Bool>(false)
    private let reception = Mutex<CaptureRouter?>(nil)

    /// The sample rate the chip actually realizes, in samples per second.
    public private(set) var sampleRate: Double
    /// The center frequency the tuner was last set to, in hertz.
    public private(set) var frequency: Double
    /// The tuner gain last set.
    public private(set) var gain: Gain

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(dongle: Dongle, device: Device) {
        self.dongle = dongle
        self.device = device
        queue = DispatchSerialQueue(label: "RTL2832U.Radio.\(dongle.id)")
        sampleRate = device.realizedRate
        frequency = Double(device.centerFrequency)
        gain = device.gain
    }

    private func checkOpen() throws {
        guard !closed.load(ordering: .sequentiallyConsistent) else { throw RadioError.closed }
    }

    /// Starts streaming and returns the runs of contiguous blocks, one capture after each retune, rate change or
    /// loss. One task iterates them. The stream runs until that task is cancelled, `stopReceiving` or `close` is
    /// called, another reception starts, or the dongle is unplugged, which throws from the loop that reads it.
    public func receive(frequency: Double, sampleRate: Double, gain: Gain = .automatic) throws -> Captures {
        try checkOpen()
        let hertz = try wholeHertz(frequency, RadioError.frequencyOutOfRange)
        let rate = try wholeHertz(sampleRate, RadioError.unsupportedSampleRate)
        stopReceiving()
        try device.setSampleRate(rate)
        try device.setGain(gain)

        let router = CaptureRouter()
        device.onFailure = { router.finish(throwing: $0) }
        try device.startStreaming(centerHz: hertz) { router.accept($0) }
        reception.withLock { $0 = router }
        router.onTermination { [weak self, weak router] in
            Task { if let self, let router { await self.ended(router) } }
        }
        if closed.load(ordering: .sequentiallyConsistent) {
            router.finish()
            throw RadioError.closed
        }
        self.sampleRate = device.realizedRate
        self.frequency = Double(hertz)
        self.gain = gain
        return router.captures
    }

    /// Stops the stream and ends its captures. The dongle stays claimed and can receive again.
    public func stopReceiving() {
        guard let router = reception.withLock({ current in
            defer { current = nil }
            return current
        }) else { return }
        device.stopStreaming()
        router.finish()
    }

    /// The consumer of `router` stopped reading. A reception that started since is left alone.
    private func ended(_ router: CaptureRouter) {
        guard reception.withLock({ $0 === router }) else { return }
        stopReceiving()
    }

    /// Retunes the radio. The capture in progress ends, and the next one begins with the first block that was taken
    /// entirely at the new frequency.
    public func tune(to hertz: Double) throws {
        try checkOpen()
        let target = try wholeHertz(hertz, RadioError.frequencyOutOfRange)
        try device.setCenterFrequency(target)
        frequency = Double(target)
    }

    /// Sets the tuner gain. The change takes effect within the capture in progress.
    public func setGain(_ gain: Gain) throws {
        try checkOpen()
        try device.setGain(gain)
        self.gain = gain
    }

    /// Changes the sample rate. The capture in progress ends, and the next one carries the new rate.
    public func setSampleRate(_ rate: Double) throws {
        try checkOpen()
        try device.setSampleRate(try wholeHertz(rate, RadioError.unsupportedSampleRate))
        sampleRate = device.realizedRate
    }

    /// Switches the supply on the antenna port, for an active antenna.
    public func setBiasTee(_ on: Bool) throws {
        try checkOpen()
        try device.setBiasTee(on)
    }

    /// Switches the demodulator's gain loop after the ADC, which is separate from the tuner gain.
    public func setDigitalAGC(_ on: Bool) throws {
        try checkOpen()
        try device.setDigitalAGC(on)
    }

    /// Ends any reception and releases the dongle. It returns at once and the release proceeds in the background; an
    /// `open` of the same dongle waits for it. Later controls throw `RadioError.closed`.
    public nonisolated func close() {
        guard !closed.exchange(true, ordering: .sequentiallyConsistent) else { return }
        let router = reception.withLock { current in
            defer { current = nil }
            return current
        }
        claims.async { [device] in
            device.close()
            router?.finish()
        }
    }

    deinit { close() }
}

/// Claims and releases run one at a time in the order they were requested, so opening a dongle waits for a release
/// that is still in progress.
private let claims = DispatchQueue(label: "RTL2832U.claims")

extension Dongle {
    /// Claims the dongle and initializes its chips. Streaming starts with `Radio.receive`.
    public func open(options: Radio.Options = Radio.Options()) async throws -> Radio {
        let dongle = self
        let device = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Device, Error>) in
            claims.async {
                continuation.resume(with: Result { try Device(dongle: dongle, options: options) })
            }
        }
        return Radio(dongle: dongle, device: device)
    }

    /// Opens the dongle for the duration of `body` and returns once the dongle has been released, whether `body`
    /// returned or threw.
    public func withRadio<T>(options: Radio.Options = Radio.Options(),
                             _ body: (Radio) async throws -> T) async throws -> T {
        let radio = try await open(options: options)
        let result: Result<T, Error>
        do { result = .success(try await body(radio)) } catch { result = .failure(error) }
        radio.close()
        await withCheckedContinuation { continuation in claims.async { continuation.resume() } }
        return try result.get()
    }
}
