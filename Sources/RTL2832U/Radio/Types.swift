import Foundation

/// The tuner gain: chosen by the tuner's own control loop, or set by the program.
public enum Gain: Equatable, Sendable, CustomStringConvertible {
    case automatic
    /// A gain in decibels. The tuner has discrete steps and uses the first that reaches the request.
    case manual(Double)

    public var description: String {
        switch self {
        case .automatic: "auto"
        case .manual(let decibels): String(format: "%.1f dB", decibels)
        }
    }

    /// The tuner's gain tables are indexed in tenths of a decibel.
    var tenthsOfDecibel: Int? {
        if case .manual(let decibels) = self { Int((decibels * 10).rounded()) } else { nil }
    }
}

/// The dongle's board, which fixes the tuner's reference clock and its antenna switching.
public enum Board: String, Sendable {
    case generic
    case blogV4

    /// The tuner's reference clock in hertz when no other is given: 28.8 MHz for the Blog V4 and 16 MHz for a generic
    /// dongle.
    public var referenceHz: UInt32 {
        switch self {
        case .generic: R828D.Board.generic.referenceHz
        case .blogV4: R828D.Board.blogV4.referenceHz
        }
    }
}

/// Why an operation on a dongle failed.
public enum RadioError: Error, LocalizedError, Sendable, Equatable {
    /// No dongle is on the USB bus, or the one that was selected has gone.
    case noDongle
    /// More than one dongle on the bus reports this serial, so it does not name one.
    case ambiguous(serial: String, count: Int)
    /// The dongle is present but could not be opened, for example because another process has claimed it.
    case unavailable(String)
    /// The dongle was unplugged.
    case disconnected
    /// The radio was closed and its dongle released.
    case closed
    /// A bulk transfer failed while streaming. The value is the IOReturn code.
    case transfer(code: Int32)
    /// The tuner's PLL did not lock at the requested frequency.
    case notLocked(frequency: Double)
    /// The tuner cannot synthesize the requested frequency.
    case frequencyOutOfRange(Double)
    /// The demodulator's resampler cannot realize the requested rate.
    case unsupportedSampleRate(Double)
    /// A register access failed.
    case hardware(String)

    public var errorDescription: String? {
        switch self {
        case .noDongle: "no RTL-SDR dongle is connected"
        case .ambiguous(let serial, let count): "\(count) dongles report the serial \(serial)"
        case .unavailable(let reason): reason
        case .disconnected: "the dongle was unplugged"
        case .closed: "the radio was closed"
        case .transfer(let code): "a USB transfer failed (IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .notLocked(let hz): "the tuner PLL did not lock at \(hz) Hz"
        case .frequencyOutOfRange(let hz): "the tuner cannot reach \(hz) Hz"
        case .unsupportedSampleRate(let rate): "the sample rate \(rate) Hz is outside the supported range"
        case .hardware(let what): what
        }
    }

    /// Maps the errors of the lower layers to the public error.
    static func wrap(_ error: Error) -> RadioError {
        switch error {
        case let error as RadioError:
            return error
        case let error as USBTransport.Failure:
            return wrap(error)
        case let error as R828D.Failure:
            return wrap(error)
        case let error as Demodulator.Failure:
            if case .sampleRateOutOfRange(let rate) = error { return .unsupportedSampleRate(Double(rate)) }
            return .hardware(error.description)
        default:
            return .hardware(String(describing: error))
        }
    }

    private static func wrap(_ error: USBTransport.Failure) -> RadioError {
        switch error {
        case .notFound: .noDongle
        case .ioService(let what): .unavailable(what)
        case .disconnected: .disconnected
        default: .hardware(error.description)
        }
    }

    private static func wrap(_ error: R828D.Failure) -> RadioError {
        switch error {
        case .noPLLSolution(let hz): .frequencyOutOfRange(Double(hz))
        case .pllNotLocked(let hz): .notLocked(frequency: Double(hz))
        case .calibrationPLLNotLocked: .hardware(error.description)
        }
    }
}

/// Converts a frequency or rate in hertz to the integer the chip works in.
func wholeHertz(_ value: Double, _ error: (Double) -> RadioError) throws -> UInt32 {
    guard value.isFinite, value > 0, value < Double(UInt32.max) else { throw error(value) }
    return UInt32(value.rounded())
}
