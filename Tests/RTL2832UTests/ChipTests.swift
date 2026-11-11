import Testing
@testable import RTL2832U

@Suite struct ChipTests {
    @Test(arguments: [2_400_000, 1_024_000, 250_000, 3_200_000, 225_001, 300_000, 900_001])
    func acceptsRealizableRates(rate: UInt32) {
        #expect(Demodulator.isSupportedRate(rate))
    }

    @Test(arguments: [100_000, 225_000, 300_001, 500_000, 900_000, 3_200_001])
    func rejectsUnrealizableRates(rate: UInt32) {
        #expect(!Demodulator.isSupportedRate(rate))
    }

    /// The divider is the smallest power of two that places the VCO between 1.77 and 3.54 GHz.
    @Test func mixerDividerPlacesTheVCOInRange() {
        for freqKHz in stride(from: 24_000 as UInt32, through: 1_700_000, by: 7_919) {
            let (divider, _) = R828D.mixerDivider(forKHz: freqKHz)
            let vco = freqKHz * divider
            if divider <= 64 { #expect(vco >= 1_770_000 && vco < 3_540_000) }
        }
        #expect(R828D.mixerDivider(forKHz: 94_970) == (32, 4))
        #expect(R828D.mixerDivider(forKHz: 166_020) == (16, 3))
    }

    /// The sigma-delta word approximates the fraction as a 16-bit binary fraction of twice the reference.
    @Test func sigmaDeltaApproximatesTheFraction() {
        #expect(R828D.sigmaDelta(fraction: 0, referenceKHz: 28_800) == 0)
        for fraction: UInt32 in [1, 17, 500, 4_000, 20_000] {
            let word = R828D.sigmaDelta(fraction: fraction, referenceKHz: 28_800)
            let ideal = Double(fraction) / (2 * 28_800) * 65_536
            #expect(abs(Double(word) - ideal) <= 2)
        }
    }

    @Test func bandTableAscendsInFrequency() {
        let starts = R828D.bands.map(\.megahertz)
        #expect(starts == starts.sorted())
        #expect(starts.first == 0)
    }
}
