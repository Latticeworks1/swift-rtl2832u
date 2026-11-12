import Foundation
import Synchronization

/// A run of blocks that are contiguous in time and tuned to one frequency at one sample rate. State that belongs to
/// one run, such as a filter's memory, is declared inside the loop over the captures and is discarded with the run.
///
/// A capture ends when the radio is retuned, when the sample rate changes, when samples were lost at the controller,
/// and when the consumer fell far enough behind that blocks were discarded. Iterating a capture throws the error that
/// ended the radio, if one did.
public struct Capture: AsyncSequence, Sendable {
    public typealias Element = IQBlock

    /// The center frequency of every block in the capture, in hertz.
    public let frequency: Double
    /// The sample rate of every block in the capture, in samples per second.
    public let sampleRate: Double
    let blocks: AsyncThrowingStream<IQBlock, Error>

    public func makeAsyncIterator() -> AsyncThrowingStream<IQBlock, Error>.Iterator {
        blocks.makeAsyncIterator()
    }
}

/// The captures a radio delivers, one after another. A single consumer should iterate them.
public struct Captures: AsyncSequence, Sendable {
    public typealias Element = Capture
    let stream: AsyncThrowingStream<Capture, Error>

    /// Every block in order, for a program that keeps no state between blocks.
    public var samples: Samples { Samples(captures: self) }

    public func makeAsyncIterator() -> AsyncThrowingStream<Capture, Error>.Iterator {
        stream.makeAsyncIterator()
    }
}

/// The blocks of every capture in order, for a program that keeps no state between blocks.
public struct Samples: AsyncSequence, Sendable {
    public typealias Element = IQBlock
    let captures: Captures

    public struct AsyncIterator: AsyncIteratorProtocol {
        var outer: AsyncThrowingStream<Capture, Error>.Iterator
        var inner: AsyncThrowingStream<IQBlock, Error>.Iterator?

        public mutating func next() async throws -> IQBlock? {
            while true {
                if inner != nil {
                    if let block = try await inner!.next() { return block }
                    inner = nil
                }
                guard let capture = try await outer.next() else { return nil }
                inner = capture.makeAsyncIterator()
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(outer: captures.makeAsyncIterator(), inner: nil)
    }
}

/// Turns the stream of raw blocks into captures. A block is withheld when its transfer was short or when its capture
/// interval may overlap a retune. A capture ends and a new one begins before the next block that is kept when the
/// tuning generation or the sample-rate epoch changed, when blocks were withheld, when the consumer's queue discarded a
/// block, or when the sample clock shows a loss that earlier blocks did not. A loss is detected about one queue depth
/// of blocks after it happened, so the capture that ends at the detection already holds the blocks that followed it.
final class CaptureRouter: Sendable {
    private struct State {
        var inner: AsyncThrowingStream<IQBlock, Error>.Continuation?
        var generation = 0
        var epoch = 0
        var shortfall = 0
        var needsNewCapture = true
        var sequence: UInt64 = 0
        var finished = false
    }

    let captures: Captures
    private let outer: AsyncThrowingStream<Capture, Error>.Continuation
    private let buffering: Int
    private let state = Mutex(State())

    init(buffering: Int = 8) {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Capture.self, throwing: Error.self,
                                                                    bufferingPolicy: .unbounded)
        captures = Captures(stream: stream)
        outer = continuation
        self.buffering = max(1, buffering)
    }

    /// Called on the USB completion queue. The block is valid only for the duration of the call.
    func accept(_ block: IQStream.Block) {
        let acquisition = block.acquisition
        state.withLock { state in
            guard !state.finished else { return }
            guard acquisition.transferComplete, acquisition.tuningSettled else {
                state.needsNewCapture = true
                return
            }
            if state.needsNewCapture
                || acquisition.tuningGeneration != state.generation
                || block.epoch != state.epoch
                || acquisition.clockShortfallSamples > state.shortfall {
                begin(block, acquisition, &state)
            }
            state.sequence &+= 1
            let owned = IQBlock(
                bytes: Array(block.bytes.prefix(block.count * 2)),
                sampleRate: block.sampleRate, frequency: acquisition.centerHz.map(Double.init),
                diagnostics: IQBlock.Diagnostics(epoch: block.epoch, sequence: state.sequence,
                                                 acquisition: acquisition))
            if case .dropped = state.inner?.yield(owned) { state.needsNewCapture = true }
        }
    }

    private func begin(_ block: IQStream.Block, _ acquisition: IQAcquisition, _ state: inout State) {
        state.inner?.finish()
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: IQBlock.self, throwing: Error.self, bufferingPolicy: .bufferingNewest(buffering))
        state.inner = continuation
        state.generation = acquisition.tuningGeneration
        state.epoch = block.epoch
        state.shortfall = acquisition.clockShortfallSamples
        state.needsNewCapture = false
        outer.yield(Capture(frequency: acquisition.centerHz.map(Double.init) ?? 0, sampleRate: block.sampleRate,
                            blocks: stream))
    }

    /// Runs `handler` once when the captures end, whether they were finished or their consumer was cancelled.
    func onTermination(_ handler: @escaping @Sendable () -> Void) {
        outer.onTermination = { _ in handler() }
    }

    /// Ends the captures. With an error, the consumer's loop throws it.
    func finish(throwing error: Error? = nil) {
        state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            state.inner?.finish(throwing: error)
            state.inner = nil
        }
        outer.finish(throwing: error)
    }
}
