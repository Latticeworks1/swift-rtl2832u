# RTL2832U

A Swift driver for RTL-SDR dongles on macOS. It claims the device through IOUSBHost, programs the RTL2832U and its
R828D tuner, and delivers baseband samples as an asynchronous sequence. It depends only on Apple frameworks: no
librtlsdr, no libusb, no kernel extension.

## Requirements

- macOS 26, Swift 6.2 (Xcode 26)
- An RTL2832U dongle with an R828D tuner, such as the RTL-SDR Blog V4

## Installation

```swift
.package(url: "https://github.com/Latticeworks1/swift-rtl2832u.git", branch: "main")
```

Depend on the `RTL2832U` product.

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

## Controls

`Radio` is an actor, and its controls take effect while the stream runs.

```swift
try await radio.tune(to: 100.3e6)
try await radio.setGain(.manual(30))
```

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
