// Converts interleaved unsigned 8-bit I/Q bytes into zero-mean split-complex Float arrays in the layout the vDSP
// complex routines take. Each channel's offset is tracked with a one-pole average of the block means.

import Accelerate
import Foundation

package final class IQConverter {

    /// Full scale of the 8-bit samples about their offset.
    package static let fullScale: Float = 127.5

    let capacity: Int
    let i: UnsafeMutablePointer<Float>
    let q: UnsafeMutablePointer<Float>
    private(set) var offsetI: Float = 0
    private(set) var offsetQ: Float = 0

    /// Complex samples per second. It sets the averaging weight of each block and may change while the converter runs.
    var sampleRate: Double
    private let timeConstant: Double
    private var primed = false
    /// Negates Q, which mirrors the spectrum about the tuner center.
    var spectrumInverted = false

    /// - Parameters:
    ///   - capacity: the most complex samples one `convert` call accepts.
    ///   - sampleRate: the initial complex samples per second.
    ///   - timeConstant: seconds over which the offset estimate forgets earlier blocks.
    init(capacity: Int, sampleRate: Double, timeConstant: Double) {
        self.capacity = capacity
        self.sampleRate = sampleRate
        self.timeConstant = timeConstant
        i = .allocate(capacity: capacity)
        q = .allocate(capacity: capacity)
    }

    deinit {
        i.deallocate()
        q.deallocate()
    }

    /// Forgets the offset estimate, so the next block sets it afresh.
    func reset() { primed = false }

    var split: DSPSplitComplex { DSPSplitComplex(realp: i, imagp: q) }

    /// Fills `i` and `q` from the interleaved bytes and returns the number of complex samples written. A trailing
    /// unpaired byte is ignored.
    @discardableResult
    func convert(_ bytes: UnsafeRawBufferPointer) -> Int {
        let n = min(bytes.count / 2, capacity)
        guard n > 0, let base = bytes.baseAddress else { return 0 }
        let raw = base.assumingMemoryBound(to: UInt8.self)
        let length = vDSP_Length(n)

        vDSP_vfltu8(raw, 2, i, 1, length)
        vDSP_vfltu8(raw + 1, 2, q, 1, length)

        var meanI: Float = 0, meanQ: Float = 0
        vDSP_meanv(i, 1, &meanI, length)
        vDSP_meanv(q, 1, &meanQ, length)

        if primed {
            let weight = Float(1 - exp(-Double(n) / sampleRate / timeConstant))
            offsetI += weight * (meanI - offsetI)
            offsetQ += weight * (meanQ - offsetQ)
        } else {
            offsetI = meanI
            offsetQ = meanQ
            primed = true
        }

        var scale = 1 / Self.fullScale
        var biasI = -offsetI / Self.fullScale
        vDSP_vsmsa(i, 1, &scale, &biasI, i, 1, length)
        var scaleQ = spectrumInverted ? -scale : scale
        var biasQ = spectrumInverted ? offsetQ / Self.fullScale : -offsetQ / Self.fullScale
        vDSP_vsmsa(q, 1, &scaleQ, &biasQ, q, 1, length)
        return n
    }
}
