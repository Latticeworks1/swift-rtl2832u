// The Rafael Micro R828D tuner: register access through the RTL2832U's I2C repeater, initialization, the PLL, band
// switching, the IF filter and the gain.
//
// The register sequences and tables follow the R82xx tuner driver of librtlsdr (osmocom rtl-sdr and the RTL-SDR Blog
// fork), which derives from the r820t driver of the Linux kernel: Copyright (C) 2013 Mauro Carvalho Chehab and
// Copyright (C) 2013 Steve Markgraf, GPL-2.0-or-later. See LICENSE and the acknowledgements in README.md.

import Foundation

/// The tuner behind the RTL2832U. Every method that touches the chip switches the I2C repeater on for its duration.
final class R828D {

    enum RFPath { case airAndCable1, blogV4 }

    /// What differs between boards that carry the same tuner. The reference oscillator feeds the PLL; the HF
    /// conversion offset is added to requests below it; the RF path selects how the antenna inputs are switched.
    struct Board {
        var referenceHz: UInt32
        var hfConversionHz: UInt32?
        var rfPath: RFPath

        static let generic = Board(referenceHz: 16_000_000, hfConversionHz: nil, rfPath: .airAndCable1)
        static let blogV4 = Board(referenceHz: 28_800_000, hfConversionHz: 28_800_000, rfPath: .blogV4)
    }

    enum Failure: Error, CustomStringConvertible {
        case noPLLSolution(hz: UInt32)
        case pllNotLocked(hz: UInt32)
        case calibrationPLLNotLocked

        var description: String {
            switch self {
            case .noPLLSolution(let hz): "no PLL divider for \(hz) Hz"
            case .pllNotLocked(let hz): "PLL did not lock at \(hz) Hz"
            case .calibrationPLLNotLocked: "PLL did not lock at the 56 MHz filter calibration frequency"
            }
        }
    }

    static let i2cAddress: UInt8 = 0x74

    private static let registerBase = 5
    private static let maxWrite = 7
    private static let versionNumber: UInt8 = 49

    let demodulator: Demodulator
    let board: Board

    private(set) var intermediateHz: Int = 3_570_000
    private(set) var filterCalibrationCode: UInt8 = 0
    private(set) var locked = false
    private(set) var vcoFineTune: UInt8 = 0
    private var shadow = [UInt8](repeating: 0, count: 30)
    private var input: UInt8 = 0

    init(_ demodulator: Demodulator, board: Board) {
        self.demodulator = demodulator
        self.board = board
    }

    private var transport: USBTransport { demodulator.transport }

    // MARK: - Register access

    private func write(_ register: UInt8, _ bytes: [UInt8]) throws {
        let offset = Int(register) - Self.registerBase
        for (i, byte) in bytes.enumerated() where offset + i >= 0 && offset + i < shadow.count {
            shadow[offset + i] = byte
        }

        var position = 0
        var current = register
        while position < bytes.count {
            let size = min(Self.maxWrite, bytes.count - position)
            try transport.i2cWrite(address: Self.i2cAddress, [current] + bytes[position..<position + size])
            current &+= UInt8(size)
            position += size
        }
    }

    private func write(_ register: UInt8, _ value: UInt8) throws {
        try write(register, [value])
    }

    /// Read-modify-write against the shadow copy: the tuner does not return the registers it was given.
    private func write(_ register: UInt8, _ value: UInt8, mask: UInt8) throws {
        let cached = shadow[Int(register) - Self.registerBase]
        try write(register, [(cached & ~mask) | (value & mask)])
    }

    /// Status registers from 0x00 upward. The tuner returns each byte bit-reversed.
    private func read(count: Int) throws -> [UInt8] {
        try transport.i2cWrite(address: Self.i2cAddress, [0x00])
        return try transport.i2cRead(address: Self.i2cAddress, length: count).map(Self.bitReversed)
    }

    private static func bitReversed(_ byte: UInt8) -> UInt8 {
        var value = byte, result: UInt8 = 0
        for _ in 0..<8 {
            result = result << 1 | value & 1
            value >>= 1
        }
        return result
    }

    // MARK: - Initialization

    /// The register table, then the digital-TV filter calibration and the system frequency settings.
    func initialize() throws {
        try transport.withRepeater {
            try write(0x05, Self.initialRegisters)
            try setStandard()
            try selectSystemFrequency()
        }
    }

    /// The settings for channels narrower than 6 MHz, including the filter calibration at 56 MHz.
    private func setStandard() throws {
        shadow = Self.initialRegisters

        try write(0x0c, 0x00, mask: 0x0f)
        try write(0x13, Self.versionNumber, mask: 0x3f)
        try write(0x1d, 0x00, mask: 0x38)
        intermediateHz = 3_570_000

        for _ in 0..<2 {
            try write(0x0b, 0x6b, mask: 0x60)
            try write(0x0f, 0x04, mask: 0x04)
            try write(0x10, 0x00, mask: 0x03)

            try setPLL(56_000_000)
            guard locked else { throw Failure.calibrationPLLNotLocked }

            try write(0x0b, 0x10, mask: 0x10)
            try write(0x0b, 0x00, mask: 0x10)
            try write(0x0f, 0x00, mask: 0x04)

            let status = try read(count: 5)
            filterCalibrationCode = status[4] & 0x0f
            if filterCalibrationCode != 0 && filterCalibrationCode != 0x0f { break }
        }
        if filterCalibrationCode == 0x0f { filterCalibrationCode = 0 }

        try write(0x0a, 0x10 | filterCalibrationCode, mask: 0x1f)
        try write(0x0b, 0x6b, mask: 0xef)
        try write(0x07, 0x00, mask: 0x80)
        try write(0x06, 0x30, mask: 0x30)
        try write(0x1e, 0x60, mask: 0x60)
        try write(0x05, 0x80, mask: 0x80)
        try write(0x1f, 0x00, mask: 0x80)
        try write(0x0f, 0x00, mask: 0x80)
        try write(0x19, 0x60, mask: 0x60)
    }

    /// The mixer, LNA and filter operating points the tuner starts from, with the Blog V4's divider-buffer current.
    private func selectSystemFrequency() throws {
        let mixerTop: UInt8 = 0x24
        try write(0x1d, 0xe5, mask: 0xc7)
        try write(0x1c, mixerTop, mask: 0xf8)
        try write(0x0d, 0x53)
        try write(0x0e, 0x75)

        input = 0
        try write(0x05, 0x00, mask: 0x60)
        try write(0x06, 0x00, mask: 0x08)
        try write(0x11, 0x38, mask: 0x38)
        try write(0x17, 0xa0, mask: 0x30)
        try write(0x0a, 0x40, mask: 0x60)

        try write(0x1d, 0x00, mask: 0x38)
        try write(0x1c, 0x00, mask: 0x04)
        try write(0x06, 0x00, mask: 0x40)
        try write(0x1a, 0x30, mask: 0x30)
        try write(0x1d, 0x18, mask: 0x38)
        try write(0x1c, mixerTop, mask: 0x04)
        try write(0x1e, 14, mask: 0x1f)
        try write(0x1a, 0x20, mask: 0x30)
    }

    // MARK: - Tuning

    /// Throws when the PLL does not lock.
    func setFrequency(_ hz: UInt32) throws {
        try transport.withRepeater {
            var request = hz
            if let conversion = board.hfConversionHz, hz < conversion { request = hz + conversion }
            let localOscillator = UInt32(Int(request) + intermediateHz)

            try setMux(localOscillator)
            try setPLL(localOscillator)
            guard locked else { throw Failure.pllNotLocked(hz: localOscillator) }

            switch board.rfPath {
            case .blogV4: try switchBlogV4(hz)
            case .airAndCable1: try switchAirAndCable1(hz)
            }
        }
    }

    private func switchAirAndCable1(_ hz: UInt32) throws {
        let selected: UInt8 = hz > 345_000_000 ? 0x00 : 0x60
        if selected != input {
            input = selected
            try write(0x05, selected, mask: 0x60)
        }
    }

    /// The V4 input selection: notch filters, tracking-filter bypass on HF, and the cable, air and upconverter
    /// switches.
    private func switchBlogV4(_ hz: UInt32) throws {
        let notchOff = hz <= 2_200_000
            || (85_000_000...112_000_000).contains(hz)
            || (172_000_000...242_000_000).contains(hz)
        try write(0x17, notchOff ? 0x00 : 0x08, mask: 0x08)

        let hfBand: UInt8 = 1, vhfBand: UInt8 = 2, uhfBand: UInt8 = 3
        let band = hz <= 28_800_000 ? hfBand : (hz < 250_000_000 ? vhfBand : uhfBand)

        if band == hfBand {
            try write(0x1a, 0x40, mask: 0xc3)
            try write(0x1b, 0x00)
        }

        if band != input {
            input = band
            let cable2: UInt8 = band == hfBand ? 0x08 : 0x00
            try write(0x06, cable2, mask: 0x08)
            try demodulator.setGPIO(5, cable2 == 0)
            try write(0x05, band == vhfBand ? 0x40 : 0x00, mask: 0x40)
            try write(0x05, band == uhfBand ? 0x00 : 0x20, mask: 0x20)
        }
    }

    /// Band-dependent open drain, RF mux, tracking filter and crystal capacitor.
    private func setMux(_ localOscillator: UInt32) throws {
        let megahertz = localOscillator / 1_000_000
        var index = 0
        while index < Self.bands.count - 1, megahertz >= Self.bands[index + 1].megahertz { index += 1 }
        let band = Self.bands[index]

        try write(0x17, band.openDrain, mask: 0x08)
        try write(0x1a, band.rfMux, mask: 0xc3)
        try write(0x1b, band.trackingFilter)
        try write(0x10, 0x00, mask: 0x0b)
        try write(0x08, 0x00, mask: 0x3f)
        try write(0x09, 0x00, mask: 0x3f)
    }

    /// The result is left in `locked`; the integer and fractional divider words follow the reference oscillator in
    /// `board`.
    private func setPLL(_ hz: UInt32) throws {
        let freqKHz = (hz + 500) / 1000
        let reference = UInt64(board.referenceHz)
        let referenceKHz = (board.referenceHz + 500) / 1000
        let vcoPowerRef: UInt8 = 1

        try write(0x10, 0x00, mask: 0x10)
        try write(0x1a, 0x00, mask: 0x0c)
        try write(0x12, 0x06, mask: 0xff)

        var (mixDiv, divNum) = Self.mixerDivider(forKHz: freqKHz)

        let status = try read(count: 5)
        vcoFineTune = (status[4] & 0x30) >> 4
        if vcoFineTune > vcoPowerRef {
            divNum &-= 1
        } else if vcoFineTune < vcoPowerRef {
            divNum &+= 1
        }
        try write(0x10, UInt8(truncatingIfNeeded: Int(divNum) << 5), mask: 0xe0)

        let vco = UInt64(hz) * UInt64(mixDiv)
        let nint = UInt8(truncatingIfNeeded: vco / (2 * reference))
        let fraction = UInt32(truncatingIfNeeded: (vco &- 2 * reference &* UInt64(nint)) / 1000)

        guard nint <= 128 / vcoPowerRef - 1 else { throw Failure.noPLLSolution(hz: hz) }

        let integerStep = UInt8(truncatingIfNeeded: (Int(nint) - 13) / 4)
        let stepSelect = UInt8(truncatingIfNeeded: Int(nint) - 4 * Int(integerStep) - 13)
        try write(0x14, UInt8(truncatingIfNeeded: Int(integerStep) + (Int(stepSelect) << 6)))

        try write(0x12, fraction == 0 ? 0x08 : 0x00, mask: 0x08)

        let sdm = Self.sigmaDelta(fraction: fraction, referenceKHz: referenceKHz)
        try write(0x16, UInt8(sdm >> 8))
        try write(0x15, UInt8(sdm & 0xff))

        locked = false
        locked = try waitForLock()
        guard locked else { return }

        try write(0x1a, 0x08, mask: 0x08)
    }

    /// Reads the lock bit, retrying once after rewriting the VCO register.
    private func waitForLock() throws -> Bool {
        for attempt in 0..<2 {
            let data = try read(count: 3)
            if data[2] & 0x40 != 0 { return true }
            if attempt == 0 { try write(0x12, 0x06, mask: 0xff) }
        }
        return false
    }

    // MARK: - Bandwidth and gain

    /// Programs the filter, then updates the RTL2832U intermediate frequency to match.
    func setBandwidth(_ hz: Int) throws {
        var bandwidth = hz
        var register0a: UInt8, register0b: UInt8
        let low = Self.lowPassBandwidths, hp1 = Self.highPassBandwidth1, hp2 = Self.highPassBandwidth2

        if bandwidth > 7_000_000 {
            register0a = 0x10
            register0b = 0x0b
            intermediateHz = 4_570_000
        } else if bandwidth > 6_000_000 {
            register0a = 0x10
            register0b = 0x2a
            intermediateHz = 4_570_000
        } else if bandwidth > low[0] + hp1 + hp2 {
            register0a = 0x10
            register0b = 0x6b
            intermediateHz = 3_570_000
        } else {
            register0a = 0x00
            register0b = 0x80
            intermediateHz = 2_300_000
            var realBandwidth = 0

            if bandwidth > low[0] + hp1 {
                bandwidth -= hp2
                intermediateHz += hp2
                realBandwidth += hp2
            } else {
                register0b |= 0x20
            }

            if bandwidth > low[0] {
                bandwidth -= hp1
                intermediateHz += hp1
                realBandwidth += hp1
            } else {
                register0b |= 0x40
            }

            var i = 0
            while i < low.count, bandwidth <= low[i] { i += 1 }
            i = max(i - 1, 0)
            register0b |= UInt8(15 - i)
            realBandwidth += low[i]

            intermediateHz -= realBandwidth / 2
        }

        try transport.withRepeater {
            try write(0x0a, register0a, mask: 0x10)
            try write(0x0b, register0b, mask: 0xef)
        }
        try demodulator.setIntermediateFrequency(UInt32(intermediateHz))
    }

    /// The VGA gain code in effect, 0 to 15. The gain functions set it and a retune leaves it alone.
    var vgaCode: UInt8 { shadow[0x0c - Self.registerBase] & 0x0f }

    /// The VGA code written under both gain modes. Using one code in both modes keeps the level independent of the
    /// order in which gain and tuning calls were made.
    static let defaultVGACode: UInt8 = 0x08

    /// Enables the tuner's own gain control for the LNA and the mixer, with the VGA at a fixed code.
    func setAutomaticGain() throws {
        try transport.withRepeater {
            try write(0x05, 0x00, mask: 0x10)
            try write(0x07, 0x10, mask: 0x10)
            try write(0x0c, Self.defaultVGACode, mask: 0x9f)
        }
    }

    /// Switches the tuner's gain control off and steps the LNA and the mixer alternately until their combined gain
    /// reaches `tenthsOfDecibel`.
    func setManualGain(tenthsOfDecibel gain: Int) throws {
        try transport.withRepeater {
            try write(0x05, 0x10, mask: 0x10)
            try write(0x07, 0x00, mask: 0x10)
            _ = try read(count: 4)
            try write(0x0c, Self.defaultVGACode, mask: 0x9f)

            var total = 0, mixer = 0, lna = 0
            for _ in 0..<15 {
                if total >= gain { break }
                lna += 1
                total += Self.lnaGainSteps[lna]
                if total >= gain { break }
                mixer += 1
                total += Self.mixerGainSteps[mixer]
            }
            try write(0x05, UInt8(lna), mask: 0x0f)
            try write(0x07, UInt8(mixer), mask: 0x0f)
        }
    }

    /// Writes the masked bits of one tuner register, 0x05 to 0x1f, for measurements of settings the driver holds
    /// constant.
    func setRegister(_ register: UInt8, _ value: UInt8, mask: UInt8) throws {
        try transport.withRepeater { try write(register, value, mask: mask) }
    }

    /// Status register 0x00 to 0x04 as the tuner reports it, for diagnostics.
    func status() throws -> [UInt8] {
        try transport.withRepeater { try read(count: 5) }
    }
}
