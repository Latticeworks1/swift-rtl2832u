import Testing
@testable import RTL2832U

@Suite struct IQConverterTests {
    private func convert(inverted: Bool, bytes: [UInt8]) -> (i: [Float], q: [Float]) {
        let converter = IQConverter(capacity: bytes.count / 2, sampleRate: 1_000, timeConstant: 1)
        converter.spectrumInverted = inverted
        let n = bytes.withUnsafeBytes { converter.convert($0) }
        return (Array(UnsafeBufferPointer(start: converter.i, count: n)),
                Array(UnsafeBufferPointer(start: converter.q, count: n)))
    }

    private let bytes: [UInt8] = {
        var result: [UInt8] = []
        for k in 0..<256 {
            result.append(UInt8(128 + k % 40))
            result.append(UInt8(100 + (k * 7) % 55))
        }
        return result
    }()

    @Test func invertingNegatesQAndLeavesIUntouched() {
        let straight = convert(inverted: false, bytes: bytes)
        let mirrored = convert(inverted: true, bytes: bytes)
        #expect(mirrored.i == straight.i)
        for (a, b) in zip(straight.q, mirrored.q) {
            #expect(abs(a + b) < 1e-6)
        }
        #expect(straight.q.contains { abs($0) > 0.01 })
    }

    @Test func bothOrientationsAreZeroMean() {
        for inverted in [false, true] {
            let result = convert(inverted: inverted, bytes: bytes)
            #expect(abs(result.q.reduce(0, +) / Float(result.q.count)) < 1e-5)
            #expect(abs(result.i.reduce(0, +) / Float(result.i.count)) < 1e-5)
        }
    }
}
