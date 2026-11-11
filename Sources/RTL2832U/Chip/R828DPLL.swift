// The arithmetic of the R828D's frequency synthesizer, kept apart from the register writes so that it can be tested
// without a dongle. It follows the PLL code of librtlsdr's R82xx driver; see R828D.swift for the attribution.

import Foundation

extension R828D {
    /// The smallest power-of-two mixer divider that puts the VCO in its 1.77 to 3.54 GHz range, with the exponent
    /// the divider-number register starts from.
    static func mixerDivider(forKHz freqKHz: UInt32) -> (divider: UInt32, exponent: UInt8) {
        let vcoMin: UInt32 = 1_770_000, vcoMax = vcoMin * 2
        var divider: UInt32 = 2
        var exponent: UInt8 = 0
        while divider <= 64 {
            let vco = freqKHz * divider
            if vco >= vcoMin && vco < vcoMax {
                var buffer = divider
                while buffer > 2 {
                    buffer >>= 1
                    exponent += 1
                }
                break
            }
            divider <<= 1
        }
        return (divider, exponent)
    }

    /// The 16-bit sigma-delta word for the fractional part of the divider, in kilohertz of the VCO.
    static func sigmaDelta(fraction: UInt32, referenceKHz: UInt32) -> UInt16 {
        var remaining = fraction
        var word: UInt16 = 0
        var divider: UInt16 = 2
        while remaining > 1 {
            let step = 2 * referenceKHz / UInt32(divider)
            if remaining > step {
                word &+= 32768 / (divider / 2)
                remaining -= step
                if divider >= 0x8000 { break }
            }
            divider &<<= 1
            if divider == 0 { break }
        }
        return word
    }
}
