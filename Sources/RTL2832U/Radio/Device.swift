import Foundation
import Synchronization

/// An opened dongle with the baseband and tuner configured. The center frequency is not programmed here; the stream
/// programs it when it starts, so a caller that streams and a caller that only reports get the same tuner.
///
/// The controls and the stream calls may be made from any thread. They run one at a time, because the tuner is
/// reached through the demodulator's I2C repeater and two interleaved sequences would corrupt each other.
package final class Device: @unchecked Sendable {

    /// The result of reading register 0x00 at one tuner address.
    package struct TunerProbe: Sendable {
        package let address: UInt8
        /// The byte read, or nil when the address did not respond.
        package let register: UInt8?
    }

    let transport: USBTransport
    let demodulator: Demodulator
    let tuner: R828D
    package let probes: [TunerProbe]
    /// The sample rate the RTL2832U realizes, which can differ slightly from the requested rate.
    package private(set) var realizedRate: Double
    package private(set) var centerFrequency: UInt32
    package private(set) var gain: Gain

    private let control = NSLock()
    private let invertIQ: Bool
    private let bandwidthHz: UInt32?
    private var requestedRate: UInt32
    private var biasTee: Bool
    private var activeStream: IQStream?
    private let failureHandler = Mutex<(@Sendable (RadioError) -> Void)?>(nil)
    private let detachHandler = Mutex<(@Sendable () -> Void)?>(nil)

    package init(dongle: Dongle, frequency: UInt32 = 100_000_000, sampleRate: UInt32 = 2_400_000,
                 gain: Gain = .automatic, options: Radio.Options) throws {
        do {
            transport = try USBTransport(entryID: dongle.id)
            demodulator = Demodulator(transport, correctionPPM: options.correctionPPM)
            invertIQ = options.invertIQ
            bandwidthHz = options.bandwidthHz
            requestedRate = sampleRate
            centerFrequency = frequency
            self.gain = gain
            biasTee = options.biasTee
            try demodulator.initializeBaseband()
            probes = try transport.probeTuner().map {
                TunerProbe(address: $0.address, register: $0.failure == nil ? $0.raw : nil)
            }
            try demodulator.configureForR82xxTuner()
            tuner = R828D(demodulator, board: options.tunerBoard)
            try tuner.initialize()
            try tuner.setBandwidth(Int(options.bandwidthHz ?? sampleRate))
            realizedRate = try demodulator.setSampleRate(sampleRate)
            try demodulator.setDigitalAGC(options.digitalAGC)
            try demodulator.setBiasTee(options.biasTee)
            try Self.apply(gain, to: tuner)
        } catch {
            throw RadioError.wrap(error)
        }
        transport.onDetach = { [weak self] in self?.detached() }
    }

    deinit { close() }

    /// Stops streaming, switches the bias tee off, and releases the dongle. Safe to call repeatedly; later controls
    /// throw.
    package func close() {
        stopStreaming()
        control.lock()
        defer { control.unlock() }
        if biasTee, transport.isOpen { try? demodulator.setBiasTee(false) }
        biasTee = false
        transport.close()
    }

    private static func apply(_ gain: Gain, to tuner: R828D) throws {
        if let tenths = gain.tenthsOfDecibel {
            try tuner.setManualGain(tenthsOfDecibel: tenths)
        } else {
            try tuner.setAutomaticGain()
        }
    }

    // MARK: - Controls

    package func setCenterFrequency(_ hz: UInt32) throws {
        control.lock()
        defer { control.unlock() }
        do {
            if let activeStream {
                try activeStream.retune(to: hz)
            } else {
                try tuner.setFrequency(hz)
            }
        } catch {
            throw RadioError.wrap(error)
        }
        centerFrequency = hz
    }

    package func setGain(_ gain: Gain) throws {
        control.lock()
        defer { control.unlock() }
        do { try Self.apply(gain, to: tuner) } catch { throw RadioError.wrap(error) }
        self.gain = gain
    }

    /// Changes the sample rate and returns the rate the chip realizes. While streaming, blocks of the old rate stop
    /// arriving before the first block of the new rate, and the epoch increases.
    @discardableResult
    package func setSampleRate(_ rate: UInt32) throws -> Double {
        control.lock()
        defer { control.unlock() }
        do {
            if let activeStream {
                try activeStream.setSampleRate(rate)
                realizedRate = activeStream.sampleRate
            } else {
                try tuner.setBandwidth(Int(bandwidthHz ?? rate))
                realizedRate = try demodulator.setSampleRate(rate)
            }
        } catch {
            throw RadioError.wrap(error)
        }
        requestedRate = rate
        return realizedRate
    }

    package func setBiasTee(_ on: Bool) throws {
        control.lock()
        defer { control.unlock() }
        do { try demodulator.setBiasTee(on) } catch { throw RadioError.wrap(error) }
        biasTee = on
    }

    package func setDigitalAGC(_ on: Bool) throws {
        control.lock()
        defer { control.unlock() }
        do { try demodulator.setDigitalAGC(on) } catch { throw RadioError.wrap(error) }
    }

    package var isConnected: Bool { transport.isOpen }
    package var pllLocked: Bool { tuner.locked }

    // MARK: - Streaming

    /// Starts streaming, tuned to `centerHz` when given. `handler` runs on the USB completion queue and its block is
    /// valid only for the duration of the call.
    package func startStreaming(centerHz: UInt32? = nil, handler: @escaping @Sendable (IQStream.Block) -> Void) throws {
        control.lock()
        defer { control.unlock() }
        guard activeStream == nil else { throw RadioError.unavailable("the dongle is already streaming") }
        guard isConnected else { throw RadioError.disconnected }
        if let centerHz { centerFrequency = centerHz }

        let stream = IQStream(demodulator: demodulator, tuner: tuner, spectrumInverted: invertIQ)
        stream.onFailure = { [weak self] code in self?.transferFailed(code) }
        do {
            try stream.start(sampleRate: requestedRate, centerHz: centerFrequency, handler: handler)
        } catch {
            stream.stop()
            throw RadioError.wrap(error)
        }
        realizedRate = stream.sampleRate
        activeStream = stream
    }

    /// Stops the stream. The result is false when a handler was still running at the transport's drain deadline.
    @discardableResult
    package func stopStreaming() -> Bool {
        endStream() ?? true
    }

    /// Stops the stream if one is running and returns whether it drained, or nil when none was running.
    private func endStream() -> Bool? {
        control.lock()
        defer { control.unlock() }
        guard let stream = activeStream else { return nil }
        activeStream = nil
        return stream.stop()
    }

    /// Called once, from a system queue, when the stream ends because the dongle was unplugged or a transfer failed.
    package var onFailure: (@Sendable (RadioError) -> Void)? {
        get { failureHandler.withLock { $0 } }
        set { failureHandler.withLock { $0 = newValue } }
    }

    /// Called once, on a system queue, when the dongle is unplugged, whether or not a stream is running.
    package var onDetach: (@Sendable () -> Void)? {
        get { detachHandler.withLock { $0 } }
        set { detachHandler.withLock { $0 = newValue } }
    }

    /// An unplug fails the bulk transfers a moment before the registry reports the device terminated, so the cause is
    /// decided after `Self.terminationGrace`: a device that has left the registry by then was unplugged, and one that
    /// is still there failed a transfer.
    private func transferFailed(_ code: Int32) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            guard let self else { return }
            self.end(with: self.isConnected ? .transfer(code: code) : .disconnected)
        }
    }

    private static let terminationGrace = 0.25

    private func detached() {
        onDetach?()
        DispatchQueue.global().async { [weak self] in self?.end(with: .disconnected) }
    }

    /// Reports the end of a running stream once, however many causes report it.
    private func end(with error: RadioError) {
        if endStream() != nil { onFailure?(error) }
    }
}
