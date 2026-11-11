// The R828D's register tables. The values are those of librtlsdr's R82xx driver; see R828D.swift for the
// attribution.

import Foundation

extension R828D {
    /// Registers 0x05 to 0x22. The table is thirty bytes long, so the last three registers are written as zero.
    static let initialRegisters: [UInt8] = [
        0x83, 0x30, 0x75,
        0xc0, 0x40, 0xd6, 0x6c,
        0xf5, 0x63, 0x75, 0x68,
        0x6c, 0x83, 0x80, 0x00,
        0x0f, 0x00, 0xc0, 0x30,
        0x48, 0xcc, 0x60, 0x00,
        0x54, 0xae, 0x4a, 0xc0,
        0x00, 0x00, 0x00,
    ]

    /// The front-end settings that apply from `megahertz` of local-oscillator frequency up to the next row.
    struct Band {
        let megahertz: UInt32
        let openDrain: UInt8
        let rfMux: UInt8
        let trackingFilter: UInt8
    }

    static let bands: [Band] = [
        Band(megahertz: 0, openDrain: 0x08, rfMux: 0x02, trackingFilter: 0xdf),
        Band(megahertz: 50, openDrain: 0x08, rfMux: 0x02, trackingFilter: 0xbe),
        Band(megahertz: 55, openDrain: 0x08, rfMux: 0x02, trackingFilter: 0x8b),
        Band(megahertz: 60, openDrain: 0x08, rfMux: 0x02, trackingFilter: 0x7b),
        Band(megahertz: 65, openDrain: 0x08, rfMux: 0x02, trackingFilter: 0x69),
        Band(megahertz: 70, openDrain: 0x08, rfMux: 0x02, trackingFilter: 0x58),
        Band(megahertz: 75, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x44),
        Band(megahertz: 80, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x44),
        Band(megahertz: 90, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x34),
        Band(megahertz: 100, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x34),
        Band(megahertz: 110, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x24),
        Band(megahertz: 120, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x24),
        Band(megahertz: 140, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x14),
        Band(megahertz: 180, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x13),
        Band(megahertz: 220, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x13),
        Band(megahertz: 250, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x11),
        Band(megahertz: 280, openDrain: 0x00, rfMux: 0x02, trackingFilter: 0x00),
        Band(megahertz: 310, openDrain: 0x00, rfMux: 0x41, trackingFilter: 0x00),
        Band(megahertz: 450, openDrain: 0x00, rfMux: 0x41, trackingFilter: 0x00),
        Band(megahertz: 588, openDrain: 0x00, rfMux: 0x40, trackingFilter: 0x00),
        Band(megahertz: 650, openDrain: 0x00, rfMux: 0x40, trackingFilter: 0x00),
    ]

    /// The widths of the IF low-pass settings in hertz, widest first.
    static let lowPassBandwidths = [1_700_000, 1_600_000, 1_550_000, 1_450_000, 1_200_000,
                                            900_000, 700_000, 550_000, 450_000, 350_000]
    /// The width in hertz that each of the two high-pass settings adds to the passband when it is engaged.
    static let highPassBandwidth1 = 350_000
    static let highPassBandwidth2 = 380_000

    /// The gain that each successive LNA step and mixer step adds, in tenths of a decibel.
    static let lnaGainSteps = [0, 9, 13, 40, 38, 13, 31, 22, 26, 31, 26, 14, 19, 5, 35, 13]
    static let mixerGainSteps = [0, 5, 10, 10, 19, 9, 10, 25, 17, 10, 8, 16, 13, 6, 3, -8]
}
