// The Realtek RTL2832U demodulator used as a sample source: baseband initialization, the intermediate frequency, the
// resampler that sets the sample rate, the FIR, the GPIO pins and the digital gain loop.
//
// The register sequences and the FIR coefficients follow librtlsdr (osmocom rtl-sdr and the RTL-SDR Blog fork):
// Copyright (C) 2012-2014 Steve Markgraf and Copyright (C) 2012 Dimitri Stolnikov, GPL-2.0-or-later. See LICENSE and
// the acknowledgements in README.md.

import Foundation

final class Demodulator {

    enum Failure: Error, CustomStringConvertible {
        case sampleRateOutOfRange(UInt32)
        case coefficientOutOfRange(Int)
        case gpioOutOfRange(Int)

        var description: String {
            switch self {
            case .sampleRateOutOfRange(let rate): "sample rate \(rate) Hz is outside the resampler range"
            case .coefficientOutOfRange(let value): "FIR coefficient \(value) does not fit in 12 bits"
            case .gpioOutOfRange(let bit): "GPIO pin \(bit) does not exist; the chip has eight"
            }
        }
    }

    private static let nominalCrystalHz: UInt32 = 28_800_000
    private static let r82xxIntermediateHz: UInt32 = 3_570_000
    /// The intermediate-frequency translator and the resampler both express their setting as a 22-bit fraction of the
    /// crystal.
    private static let fractionScale = 4_194_304.0

    private static let firDefault: InlineArray<16, Int> = [
        -54, -36, -41, -40, -32, -14, 14, 53,
        101, 156, 215, 273, 327, 372, 404, 421
    ]

    /// A register together with the block it lives in, so an address cannot be paired with the wrong block.
    private struct Register {
        let block: USBTransport.Block
        let address: UInt16

        static let usbSysctl = Register(block: .usb, address: 0x2000)
        static let usbEndpointAControl = Register(block: .usb, address: 0x2148)
        static let usbEndpointAMaxPacket = Register(block: .usb, address: 0x2158)
        static let sysDemodControl = Register(block: .sys, address: 0x3000)
        static let sysGPO = Register(block: .sys, address: 0x3001)
        static let sysGPOEnable = Register(block: .sys, address: 0x3003)
        static let sysGPODirection = Register(block: .sys, address: 0x3004)
        static let sysDemodControl1 = Register(block: .sys, address: 0x300b)
    }

    let transport: USBTransport
    /// The demodulator clock with the frequency correction applied.
    let crystalHz: Double

    init(_ transport: USBTransport, correctionPPM: Double = 0) {
        self.transport = transport
        crystalHz = Double(Self.nominalCrystalHz) * (1 + correctionPPM / 1e6)
    }

    /// Rates above 225 kS/s and at most 3.2 MS/s, excluding the 300 to 900 kS/s band the resampler cannot realize.
    static func isSupportedRate(_ rate: UInt32) -> Bool {
        rate > 225_000 && rate <= 3_200_000 && !(rate > 300_000 && rate <= 900_000)
    }

    /// Zero-IF mode, DC cancellation and IQ compensation start enabled; a tuner that needs an intermediate
    /// frequency switches them off.
    func initializeBaseband() throws {
        try write(.usbSysctl, 0x09)
        try write(.usbEndpointAMaxPacket, 0x0002, length: 2)
        try write(.usbEndpointAControl, 0x1002, length: 2)

        try write(.sysDemodControl1, 0x22)
        try write(.sysDemodControl, 0xe8)

        try softReset()

        try transport.demodWrite(page: 1, 0x15, 0x00)
        try transport.demodWrite(page: 1, 0x16, 0x0000, length: 2)
        for i in 0..<6 { try transport.demodWrite(page: 1, UInt16(0x16 + i), 0x00) }

        try setFIR(Self.firDefault)

        try setDigitalAGC(false)
        try transport.demodWrite(page: 1, 0x93, 0xf0)
        try transport.demodWrite(page: 1, 0x94, 0x0f)
        try transport.demodWrite(page: 1, 0x11, 0x00)
        try transport.demodWrite(page: 1, 0x04, 0x00)
        try transport.demodWrite(page: 0, 0x61, 0x60)
        try transport.demodWrite(page: 0, 0x06, 0x80)
        try transport.demodWrite(page: 1, 0xb1, 0x1b)
        try transport.demodWrite(page: 0, 0x0d, 0x83)
    }

    /// Zero-IF off, the in-phase ADC input only, the 3.57 MHz intermediate frequency and spectrum inversion, as
    /// the R820T and R828D need.
    func configureForR82xxTuner() throws {
        try transport.demodWrite(page: 1, 0xb1, 0x1a)
        try transport.demodWrite(page: 0, 0x08, 0x4d)
        try setIntermediateFrequency(Self.r82xxIntermediateHz)
        try transport.demodWrite(page: 1, 0x15, 0x01)
    }

    /// Eight signed bytes, then eight signed 12-bit values packed in pairs into three bytes.
    private func setFIR(_ coefficients: InlineArray<16, Int>) throws {
        var packed: [UInt8] = []
        for index in 0..<8 {
            let value = coefficients[index]
            guard (-128...127).contains(value) else { throw Failure.coefficientOutOfRange(value) }
            packed.append(UInt8(bitPattern: Int8(value)))
        }
        for pair in stride(from: 8, to: 16, by: 2) {
            let a = coefficients[pair], b = coefficients[pair + 1]
            for value in [a, b] where !(-2048...2047).contains(value) {
                throw Failure.coefficientOutOfRange(value)
            }
            packed.append(UInt8(truncatingIfNeeded: a >> 4))
            packed.append(UInt8(truncatingIfNeeded: (a << 4) | ((b >> 8) & 0x0f)))
            packed.append(UInt8(truncatingIfNeeded: b))
        }
        for (i, byte) in packed.enumerated() {
            try transport.demodWrite(page: 1, UInt16(0x1c + i), UInt16(byte))
        }
    }

    /// A 22-bit signed fraction of the crystal, negated, split over registers 0x19 to 0x1b.
    func setIntermediateFrequency(_ hz: UInt32) throws {
        let value = Int32(-(Double(hz) * Self.fractionScale / crystalHz))
        try transport.demodWrite(page: 1, 0x19, UInt16((value >> 16) & 0x3f))
        try transport.demodWrite(page: 1, 0x1a, UInt16((value >> 8) & 0xff))
        try transport.demodWrite(page: 1, 0x1b, UInt16(value & 0xff))
    }

    /// Programs the resampler without touching the tuner bandwidth, which the caller sets first. Returns the
    /// realized rate.
    @discardableResult
    func setSampleRate(_ rate: UInt32) throws -> Double {
        guard Self.isSupportedRate(rate) else { throw Failure.sampleRateOutOfRange(rate) }

        var ratio = UInt32(crystalHz * Self.fractionScale / Double(rate))
        ratio &= 0x0fff_fffc
        let realRatio = ratio | ((ratio & 0x0800_0000) << 1)
        let realRate = crystalHz * Self.fractionScale / Double(realRatio)

        try transport.demodWrite(page: 1, 0x9f, UInt16(ratio >> 16), length: 2)
        try transport.demodWrite(page: 1, 0xa1, UInt16(ratio & 0xffff), length: 2)

        try transport.demodWrite(page: 1, 0x3f, 0x00)
        try transport.demodWrite(page: 1, 0x3e, 0x00)

        try softReset()
        return realRate
    }

    /// Pulses the endpoint A control register so the next bulk read starts on a sample boundary.
    func resetBuffer() throws {
        try write(.usbEndpointAControl, 0x1002, length: 2)
        try write(.usbEndpointAControl, 0x0000, length: 2)
    }

    /// The pin that switches the supply on the antenna port of the Blog V4.
    private static let biasTeeGPIO = 0

    /// Powers the antenna port, which puts 4.5 V on the center conductor for an active antenna.
    func setBiasTee(_ on: Bool) throws {
        try setGPIO(Self.biasTeeGPIO, on)
    }

    /// The demodulator's own gain loop, after the ADC. It is separate from the tuner's gain loop.
    func setDigitalAGC(_ on: Bool) throws {
        try transport.demodWrite(page: 0, 0x19, on ? 0x25 : 0x05)
    }

    /// Sets a GPIO pin as an output and drives it. The chip has eight pins.
    func setGPIO(_ bit: Int, _ on: Bool) throws {
        guard (0..<8).contains(bit) else { throw Failure.gpioOutOfRange(bit) }
        let mask = UInt16(1 << bit)
        let direction = try read(.sysGPODirection)
        try write(.sysGPODirection, direction & ~mask)
        let enable = try read(.sysGPOEnable)
        try write(.sysGPOEnable, enable | mask)
        let level = try read(.sysGPO)
        try write(.sysGPO, on ? level | mask : level & ~mask)
    }

    /// Pulses the demodulator's soft reset, page 1 register 0x01.
    private func softReset() throws {
        try transport.demodWrite(page: 1, 0x01, 0x14)
        try transport.demodWrite(page: 1, 0x01, 0x10)
    }

    private func write(_ register: Register, _ value: UInt16, length: Int = 1) throws {
        try transport.writeReg(register.block, register.address, value, length: length)
    }

    private func read(_ register: Register) throws -> UInt16 {
        try transport.readReg(register.block, register.address)
    }
}
