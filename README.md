# RTL2832U

A Swift driver for RTL-SDR dongles on macOS. It claims the device through IOUSBHost, programs the RTL2832U and its
R828D tuner, and delivers baseband samples as an asynchronous sequence. It depends only on Apple frameworks: no
librtlsdr, no libusb, no kernel extension.

## Requirements

- macOS 26, Swift 6.2 (Xcode 26)
- An RTL2832U dongle with an R828D tuner, such as the RTL-SDR Blog V4

## Installation

```swift
.package(url: "https://github.com/Latticeworks1/swift-rtl2832u.git", from: "0.1.0")
```

Depend on the `RTL2832U` product. Releases are tagged with semantic versions, and the interface may change between
minor versions while the major version is 0.

## Choosing a dongle

`Dongle.all` lists the dongles on the bus in order of USB location, read from the IOKit registry without opening
them, so a dongle another process holds is still listed. Each carries its `name`, `vendor`, `product`, `serial`,
`usbID` and `location`.

```swift
for dongle in Dongle.all { print(dongle.name, dongle.serial, dongle.location) }
let radio = try await Dongle.with(serial: "00000001").open()
```

`Dongle.with(serial:)` throws `RadioError.ambiguous` when several dongles report the same serial, which factory
units often do. One process holds a dongle at a time, and a second open throws `RadioError.unavailable`.

## Receiving

```swift
import RTL2832U

let radio = try await Dongle.first().open()
let captures = try await radio.receive(frequency: 100.1e6, sampleRate: 2.4e6, gain: .automatic)

for try await capture in captures {
    var demodulator = FMDemodulator()          // your state for one contiguous run
    for try await block in capture {
        demodulator.process(block.i, block.q)  // zero-mean Float samples, full scale 1
    }
}
```

A capture is a run of blocks that are contiguous in time at one frequency and one sample rate. A new capture begins
after a retune, a sample-rate change, or a loss of samples, so state declared inside the outer loop is reset exactly
when it must be. Unplugging the dongle ends the loop with `RadioError.disconnected`.

A program with no state between blocks reads the flat sequence `captures.samples`.

## Getting audio

The driver delivers the radio signal itself, as complex baseband samples centered on the tuned frequency, and the
program that uses it turns those samples into sound. For a broadcast FM station that takes three steps: reduce the
2.4 MS/s stream to a rate that just holds one station, measure how fast the phase of the signal turns from sample to
sample, which is the audio, and reduce that to the sound card's rate. The demodulator below does this with plain
averages, 2.4 MS/s to 240 kS/s to 48 kS/s.

```swift
struct FMAudio {
    private var sumI: Float = 0, sumQ: Float = 0, count = 0
    private var lastI: Float = 0, lastQ: Float = 0
    private var sumPhase: Float = 0, phases = 0, level: Float = 0

    mutating func process(_ i: [Float], _ q: [Float]) -> [Float] {
        var audio: [Float] = []
        for k in i.indices {
            sumI += i[k]; sumQ += q[k]; count += 1
            guard count == 10 else { continue }
            // The angle between successive samples is the instantaneous frequency.
            sumPhase += atan2(sumQ * lastI - sumI * lastQ, sumI * lastI + sumQ * lastQ)
            (lastI, lastQ, sumI, sumQ, count) = (sumI, sumQ, 0, 0, 0)
            phases += 1
            guard phases == 5 else { continue }
            level += (sumPhase / 5 - level) * 0.2425      // 75 microsecond de-emphasis at 48 kS/s
            audio.append(level / 2)
            (sumPhase, phases) = (0, 0)
        }
        return audio
    }
}
```

Its output goes to the system through AVFoundation. This is the whole `main.swift` of a command-line FM receiver.

```swift
import AVFoundation
import RTL2832U

let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
let engine = AVAudioEngine(), player = AVAudioPlayerNode()
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
try engine.start()
player.play()

@MainActor func play(_ audio: [Float]) {
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(audio.count)) else { return }
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].update(from: audio, count: audio.count)
    player.scheduleBuffer(buffer, completionHandler: nil)
}

let radio = try await Dongle.first().open()
for try await capture in try await radio.receive(frequency: 100.1e6, sampleRate: 2.4e6) {
    var fm = FMAudio()
    for try await block in capture {
        play(fm.process(block.i, block.q))
    }
}
```

### Feeding another program

Sending the audio to a virtual audio device, such as BlackHole or VB-Cable, makes the radio an audio input that
decoders, recorders and conferencing software can select. The receiver above needs one more call before
`engine.start()`, and a function that finds the device by name.

```swift
import CoreAudio

func audioDevice(named name: String) -> AudioDeviceID? {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices)
    address.mSelector = kAudioObjectPropertyName
    return devices.first { device in
        var label: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &label)
        return label?.takeRetainedValue() as String? == name
    }
}

if let device = audioDevice(named: "BlackHole 2ch") {
    try engine.outputNode.auAudioUnit.setDeviceID(device)
}
```

### Beyond the minimum

A receiver meant for listening replaces the averages with channel filters, adds stereo decoding, and matches the
dongle's sample clock to the sound card's. AM, sideband and digital modes follow the same pattern with a different
demodulator between the samples and the output.

This package stays at the level of the hardware. A receiver library built on it is in development: it takes a
frequency and a mode and delivers audio in a few lines, and its filter, demodulator and resampling chains are written
for Accelerate and Apple silicon and chosen by the library for the signal at hand.

## Samples, rates and loss

Each `IQBlock` holds `i` and `q` as `Float` arrays with zero mean, scaled so that the converter's full scale is 1.
Levels are therefore relative to the 8-bit converter at the gain in effect. Blocks within a capture are contiguous,
so time within a capture follows from the sample count and `sampleRate`.

The resampler realizes rates above 225 kS/s up to 300 kS/s and above 900 kS/s up to 3.2 MS/s.
`Radio.supports(sampleRate:)` tests a rate, `radio.sampleRate` reports the rate the chip realized, which differs
slightly from the request, and `setSampleRate(_:)` changes it while streaming and begins a new capture.

The driver keeps eight bulk requests of 20 ms queued at the controller and a queue of eight blocks per capture. A
consumer that falls behind loses the oldest blocks from its queue, and the next block begins a new capture. Blocks
that overlap a retune are withheld. Samples lost at the controller, which takes a stall of about 140 ms on the
completion path, end the capture about eight blocks after the loss. `block.diagnostics` carries the sequence number
and the acquisition record behind those decisions.

## Errors

Every failure is a `RadioError`. The stream ends by throwing `.disconnected` when the dongle is removed and
`.transfer(code:)` with the IOReturn code when a bulk transfer fails on a dongle that is still present; the driver
decides between the two one second after the first failed transfer. Controls throw `.notLocked`,
`.frequencyOutOfRange` or `.unsupportedSampleRate` for a request the chips cannot realize, `.hardware` for a failed
register access, and `.closed` after `close()`.

## Controls

`Radio` is an actor, and its controls take effect while the stream runs.

```swift
try await radio.tune(to: 100.3e6)
try await radio.setGain(.manual(30))
```

`.automatic` hands the LNA and the mixer to the tuner's own gain loop. `.manual` takes decibels and is realized with
the tuner's discrete LNA and mixer steps, using the first combination that reaches the request. `radio.close()`
releases the dongle, and `dongle.withRadio { radio in ... }` opens it for the duration of a closure.

## Board and options

`Radio.Options` holds what belongs to the board and the connection, and is passed when the dongle is opened.

```swift
var options = Radio.Options()
options.correctionPPM = 1.5   // error of the reference clock
options.bandwidth = 1.2e6     // tuner filter; nil follows the sample rate
options.biasTee = true        // power on the antenna port for an active antenna
let radio = try await Dongle.first().open(options: options)
```

On the RTL-SDR Blog V4 the driver operates the board's signal path from the tuned frequency. A request below 28.8 MHz
goes through the built-in upconverter and the HF input, so `tune(to: 7.1e6)` receives 7.1 MHz with no offset in the
caller. The board's broadcast notch filters (below 2.2 MHz, 85 to 112 MHz, and 172 to 242 MHz) are switched in while
the radio is tuned outside those bands and out while it is tuned inside them. The bias tee and the demodulator's gain
loop also switch while a stream runs, through `setBiasTee(_:)` and `setDigitalAGC(_:)`, and closing the radio
switches the bias tee off.

## Dongle events

`Dongle.events` reports dongles arriving and leaving. It opens no device, so it works while no receiver is running.

```swift
for await event in Dongle.events {
    switch event {
    case let .connected(dongle): print("connected", dongle.name)
    case let .disconnected(id): print("disconnected", id)
    }
}
```

## Documentation

- [docs/API.md](docs/API.md): the public interface and the reasoning behind its shape
- [docs/USB.md](docs/USB.md): the USB layer and the measurements made on hardware

## Source layout

```
Sources/RTL2832U/
  USB/      IOUSBHost transport, the register protocol, the bulk request queue
  Chip/     the RTL2832U demodulator registers and the R828D tuner
  Stream/   sample conversion and the stream
  Radio/    the public interface: Dongle, Radio, Captures, RadioError
```

## Testing

```
swift test
```

Tests that need hardware run when a dongle is connected and are skipped otherwise.

## License

GPL-2.0-or-later; see [LICENSE](LICENSE).

The register sequences and tables for the RTL2832U and the R828D follow
[librtlsdr](https://osmocom.org/projects/rtl-sdr/wiki) and the
[RTL-SDR Blog fork](https://github.com/rtlsdrblog/rtl-sdr-blog) by Steve Markgraf, Dimitri Stolnikov and contributors,
whose tuner code derives from the Linux kernel's r820t driver by Mauro Carvalho Chehab.
