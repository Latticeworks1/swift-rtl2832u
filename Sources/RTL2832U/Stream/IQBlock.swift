// The public form of a block of complex baseband samples.

import Foundation

/// How a block was acquired, as four properties that vary independently. Whether every block reached the consumer is
/// a fifth property, carried by `IQBlock.Diagnostics.sequence`.
public struct IQAcquisition: Sendable, Equatable {
    /// Increases with every center-frequency change, counting from 0 at the start of the stream.
    public var tuningGeneration = 0
    /// The center frequency the tuner was last programmed to, or nil from a source that does not know it.
    public var centerHz: UInt32?
    /// Transport integrity: false when the transfer delivered fewer bytes than were requested.
    public var transferComplete = true
    /// Signal integrity: false when the block's capture interval may overlap a retune, so its samples can carry the
    /// previous frequency or the transition between the two.
    public var tuningSettled = true
    /// Timing integrity: the samples the sample clock says should have arrived and did not, as a persistent shortfall
    /// since the stream started. It rises when the controller loses samples, which leaves `sequence` unbroken, and it
    /// appears about one queue depth of blocks after the loss. Shortfalls under 2 ms of signal read as 0.
    public var clockShortfallSamples = 0

    public init(tuningGeneration: Int = 0, centerHz: UInt32? = nil, transferComplete: Bool = true,
                tuningSettled: Bool = true, clockShortfallSamples: Int = 0) {
        self.tuningGeneration = tuningGeneration
        self.centerHz = centerHz
        self.transferComplete = transferComplete
        self.tuningSettled = tuningSettled
        self.clockShortfallSamples = clockShortfallSamples
    }
}

/// A block of complex baseband samples in the converter's own format, owned by the receiver of the block.
public struct IQBlock: Sendable {
    /// What the driver recorded about how the block was acquired. A program that reads blocks from a `Capture` has no
    /// need for it, because the driver has already withheld damaged blocks and ended the capture at every break.
    public struct Diagnostics: Sendable, Equatable {
        /// Increases each time the sample rate is reconfigured, so state tied to a rate can be reset at the boundary.
        public let epoch: Int
        /// Increases by one per block the dongle delivered. A gap between two received blocks means blocks were
        /// dropped because the consumer fell behind.
        public let sequence: UInt64
        /// The transport, signal and timing properties of the block.
        public let acquisition: IQAcquisition

        public init(epoch: Int, sequence: UInt64, acquisition: IQAcquisition = IQAcquisition()) {
            self.epoch = epoch
            self.sequence = sequence
            self.acquisition = acquisition
        }
    }

    /// The samples as the converter produced them: for each complex sample, one unsigned 8-bit in-phase byte followed
    /// by one unsigned 8-bit quadrature byte. The bytes of each channel center near 127.5, and a deviation of 127.5
    /// from the center is the converter's full scale.
    public let bytes: [UInt8]
    /// The rate these samples were captured at, in samples per second.
    public let sampleRate: Double
    /// The center frequency in hertz, or nil from a source that does not know it.
    public let frequency: Double?
    /// The acquisition record of the block, for tools and tests.
    public let diagnostics: Diagnostics

    /// The number of complex samples in the block.
    public var count: Int { bytes.count / 2 }

    public init(bytes: [UInt8], sampleRate: Double, frequency: Double?, diagnostics: Diagnostics) {
        self.bytes = bytes
        self.sampleRate = sampleRate
        self.frequency = frequency
        self.diagnostics = diagnostics
    }
}
