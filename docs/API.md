# The RTL2832U interface

This describes the public interface of the `RTL2832U` module, which a program uses to receive samples from a dongle, and the reasoning behind its shape. `docs/USB.md` describes the layer underneath and the measurements the statements here rest on.

## Principle

A program using the dongle states what it wants to receive and reads samples. Everything the driver can decide on its own, it decides, so that the common program contains no code that inspects the state of the hardware. The three conditions the transport can detect are handled as follows.

A retune changes the signal under a block that is already in flight, and the driver knows which blocks those are. Blocks that may overlap a retune are withheld, so the first block a program sees after a retune carries the new frequency throughout. An incomplete transfer is withheld in the same way. A removal or a failed transfer ends the sample sequence with a thrown error, which a `for try await` loop already propagates.

One condition cannot be hidden. A consumer that stalls for longer than the queued requests can cover loses samples at the controller, and the loss is visible to the driver only about eight blocks later (`docs/USB.md`, acquisition integrity). Blocks that arrive before the loss is detected cannot be withheld, so the driver reports the loss and the program decides what a gap means for its own state. The same applies to a retune, because a filter that carries state across the old and the new frequency is wrong regardless of what the driver withheld. The interface therefore expresses a discontinuity in the structure of the sequence, so that resetting state needs no flag to be read.

## Shape

A capture is a run of blocks that are contiguous in time and tuned to one frequency at one sample rate. The radio delivers a sequence of captures, and each capture is itself a sequence of blocks. A new capture begins after a retune, a sample-rate change, a detected loss, or a consumer that fell far enough behind for its queue to discard blocks. State that belongs to one run is declared inside the outer loop and is discarded with it.

```swift
import RTL2832U

let dongle = try Dongle.first()
let radio = try await dongle.open()
let captures = try await radio.receive(frequency: 100.1e6, sampleRate: 2.4e6, gain: .automatic)

for try await capture in captures {
    var demodulator = Demodulator()            // state for one contiguous run
    for try await block in capture {
        demodulator.process(block.i, block.q)
    }
}
```

Opening claims the dongle and identifies its chips, and it does not start the stream. `receive(frequency:sampleRate:gain:)` starts the stream and returns the captures. The stream runs until the task reading it is cancelled, `stopReceiving()` or `close()` is called, another reception starts, or the dongle is unplugged.

Captures are nested sequences because the structure makes a reset impossible to forget: state declared inside the outer loop cannot outlive the run it describes. A program with no state between blocks, such as one that computes a spectrum, reads the flat view `samples` of the same captures.

```swift
for try await block in try await radio.receive(frequency: 100.1e6, sampleRate: 2.4e6).samples {
    spectrum.add(block)
}
```

Controls are asynchronous methods on the radio, which is an actor running on a queue of its own, so a call from the main actor suspends and does not block it.

```swift
try await radio.tune(to: 100.3e6)
try await radio.setGain(.manual(30))
```

`tune(to:)` returns once the tuner reports a locked PLL. The capture that was running ends, and the next capture begins with the first settled block at the new frequency. `setSampleRate(_:)` likewise ends the capture in progress and begins one at the new rate. `setGain(_:)`, `setBiasTee(_:)` and `setDigitalAGC(_:)` take effect within the capture in progress.

## Types

`Dongle` is a `Sendable`, `Hashable` value naming one device on the bus by its registry entry, with the descriptor strings and USB location read from the registry without opening the device. `Dongle.all` is a snapshot ordered by USB location, `Dongle.first()` returns its first element, and `Dongle.with(serial:)` returns the dongle with a given USB serial and throws `RadioError.ambiguous` when several dongles share that serial. Opening takes the dongle itself, so a position in a list cannot name a different device after a plug event. `withRadio(options:_:)` opens a radio for the duration of a closure and returns once the dongle has been released.

`Radio` is an actor. `Radio.Options` holds what belongs to the board and the connection: the board profile, the reference clock and its correction in parts per million, the tuner bandwidth, spectrum inversion, the bias tee and the demodulator's gain loop. Its read-only properties are `sampleRate`, the rate the chip actually realizes, `frequency`, and `gain`. `close()` is synchronous and returns at once. The release of the dongle completes in the background, and a later open of the same dongle waits for that release.

`Captures` is the sequence of captures returned by `receive(frequency:sampleRate:gain:)`, and one task should iterate it. Its `samples` property is the flat sequence of blocks across all captures. A `Capture` carries the `frequency` and `sampleRate` of every block in it.

Frequencies and rates are `Double` hertz. Gain is `.automatic`, which hands the gain to the tuner's own control loop, or `.manual(Double)` in decibels, which the driver realizes with the tuner's discrete LNA and mixer steps.

`IQBlock` carries `i` and `q` as arrays of `Float` with zero mean and full scale 1, the `sampleRate`, and the capture's `frequency`. The sequence number and the acquisition record stay available through a separate `IQBlock.Diagnostics` value for tools and tests, and the ordinary path does not require them.

`RadioError` is one error type with cases for no device found, several dongles sharing a serial, a device claimed elsewhere, removal, a transfer failure, a PLL that did not lock, a frequency or sample rate the chip cannot realize, a register access that failed, and a closed radio. It conforms to `LocalizedError`.

## Structure

The package is one module with no dependencies beyond the system frameworks. Its sources are in four folders: `USB` holds the IOUSBHost transport and the register protocol, `Chip` holds the RTL2832U's demodulator registers and the R828D tuner, `Stream` turns bulk transfers into blocks with their acquisition records, and `Radio` holds the public types described above. Demodulation, decoding and audio belong to the programs that use the driver.

## Limits

The interface has no notification of dongles arriving and leaving; a program that wants one reads `Dongle.all` again. The loss detector reports a loss about eight blocks after it happens, and that delay has been measured only at the default queue of 8 requests of 20 ms. The rule that withholds blocks after a retune was checked against a real carrier at three step sizes, at one location with one carrier. A loss at the controller has been produced on hardware only by stalling the stream's handler; a stalled consumer discards blocks from its own queue and does not cause one. The measurements were made on one RTL-SDR Blog V4.
