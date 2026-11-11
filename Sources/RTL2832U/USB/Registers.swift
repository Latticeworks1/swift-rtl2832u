// The register protocol of the RTL2832U over vendor control transfers: the register blocks, the demodulator's paged
// registers, the I2C bridge to the tuner, and the tuner probe.

import Foundation

extension USBTransport {

    // MARK: - Block registers (USB, SYS, ROM, IR)

    /// wIndex is `block << 8`. The value is little-endian, and a one-byte read leaves the high byte zero.
    func readReg(_ block: Block, _ address: UInt16, length: Int = 1) throws -> UInt16 {
        let data = try transfer("read \(block) 0x\(hex(address))", read: true, value: address,
                                index: UInt16(block.rawValue) << 8, bytes: [UInt8](repeating: 0, count: length))
        return data.indices.reduce(0) { $0 | UInt16(data[$1]) << (8 * UInt16($1)) }
    }

    /// wIndex is `(block << 8) | 0x10`. A two-byte value is sent high byte first.
    func writeReg(_ block: Block, _ address: UInt16, _ value: UInt16, length: Int = 1) throws {
        _ = try transfer("write \(block) 0x\(hex(address))", read: false, value: address,
                         index: UInt16(block.rawValue) << 8 | 0x10, bytes: Self.packed(value, length: length))
    }

    // MARK: - Demodulator registers

    /// wValue is `(register << 8) | 0x20` and wIndex is the page.
    func demodRead(page: UInt8, _ register: UInt16, length: Int = 1) throws -> UInt16 {
        let data = try transfer("read demod \(page):0x\(hex(register))", read: true, value: register << 8 | 0x20,
                                index: UInt16(page), bytes: [UInt8](repeating: 0, count: length))
        return data.indices.reduce(0) { $0 | UInt16(data[$1]) << (8 * UInt16($1)) }
    }

    /// wValue is `(register << 8) | 0x20` and wIndex is `0x10 | page`. The write is followed by a read of page 0x0a,
    /// register 0x01, whose result is ignored; the write's own error is reported after it.
    func demodWrite(page: UInt8, _ register: UInt16, _ value: UInt16, length: Int = 1) throws {
        let outcome = Result {
            try transfer("write demod \(page):0x\(hex(register))", read: false, value: register << 8 | 0x20,
                         index: 0x10 | UInt16(page), bytes: Self.packed(value, length: length))
        }
        _ = try? demodRead(page: 0x0a, 0x01)
        _ = try outcome.get()
    }

    /// Powers the demodulator through its two control registers. Until they are written, demodulator page writes,
    /// and with them the I2C repeater, are refused with a pipe error.
    func powerOnDemodulator() throws {
        try writeReg(.sys, 0x300b, 0x22)
        try writeReg(.sys, 0x3000, 0xe8)
    }

    // MARK: - I2C bridge

    /// Switches the demodulator's I2C repeater, page 1 register 0x01: 0x18 passes the bus through to the tuner.
    func setRepeater(_ on: Bool) throws {
        try demodWrite(page: 1, 0x01, on ? 0x18 : 0x10)
    }

    /// Runs `body` with the repeater on and turns it off afterwards, on failure as well. When both the body and the
    /// switch-off fail, the body's error is the one reported.
    func withRepeater<T>(_ body: () throws -> T) throws -> T {
        try setRepeater(true)
        let result: T
        do {
            result = try body()
        } catch {
            try? setRepeater(false)
            throw error
        }
        try setRepeater(false)
        return result
    }

    /// Block 6 write with the device address in wValue.
    func i2cWrite(address: UInt8, _ bytes: [UInt8]) throws {
        _ = try transfer("i2c write 0x\(hex(address))", read: false, value: UInt16(address),
                         index: UInt16(Block.i2c.rawValue) << 8 | 0x10, bytes: bytes)
    }

    /// Block 6 read with the device address in wValue.
    func i2cRead(address: UInt8, length: Int) throws -> [UInt8] {
        try transfer("i2c read 0x\(hex(address))", read: true, value: UInt16(address),
                     index: UInt16(Block.i2c.rawValue) << 8, bytes: [UInt8](repeating: 0, count: length))
    }

    /// A one-byte write of the register number, then a one-byte read. Needs the repeater on.
    func i2cReadRegister(address: UInt8, _ register: UInt8) throws -> UInt8 {
        try i2cWrite(address: address, [register])
        return try i2cRead(address: address, length: 1)[0]
    }

    // MARK: - Tuner identification

    /// Powers the demodulator, then reads register 0x00 at each candidate address through the repeater and reports
    /// the raw byte or the failure for every address. Nothing is inferred beyond whether the byte equals the R82xx
    /// check value; the board revision and the tuner crystal are not decided here.
    func probeTuner() throws -> [TunerProbe] {
        try powerOnDemodulator()
        return try withRepeater {
            Self.tunerAddresses.map { address in
                do {
                    let byte = try i2cReadRegister(address: address, Self.r82xxCheckRegister)
                    return TunerProbe(address: address, raw: byte, failure: nil)
                } catch {
                    return TunerProbe(address: address, raw: nil, failure: "\(error)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// One byte is the low byte of the value, two bytes are high then low.
    private static func packed(_ value: UInt16, length: Int) -> [UInt8] {
        length == 1 ? [UInt8(value & 0xff)] : [UInt8(value >> 8), UInt8(value & 0xff)]
    }

    private func hex<T: BinaryInteger>(_ value: T) -> String { String(value, radix: 16) }
}
