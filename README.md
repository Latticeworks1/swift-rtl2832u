# RTL2832U

A driver for the Realtek RTL2832U on macOS, written in Swift. The RTL2832U is the USB chip in the receivers sold as
RTL-SDR dongles. The driver claims the device through IOUSBHost, programs the chip and the R828D tuner behind it, and
delivers baseband samples as an asynchronous sequence. It links only Apple frameworks and the Swift runtime: no
librtlsdr, no libusb, no kernel extension, and no package dependencies.

## Status

The driver has been developed and measured on one RTL-SDR Blog V4, which pairs the RTL2832U with an R828D tuner on a
28.8 MHz reference. The `generic` board profile, for an R828D on a 16 MHz reference, exists and has not been run on
hardware. Other tuners (the R820T at I2C address 0x34, the E4000, the FC0012 and the rest) are not driven.
`docs/USB.md` records what was measured, on what, and what was left unmeasured.

## Requirements

macOS 26 and Swift 6.2 or later (Xcode 26). The driver has been used from a command-line tool and from an app
without the App Sandbox; it has not been tried from a sandboxed app. Only one process can hold a dongle, so opening
one that another program has claimed fails with `RadioError.unavailable`.

## Use

Add the package and depend on the `RTL2832U` product.

```swift
.package(url: "https://github.com/Latticeworks1/swift-rtl2832u.git", branch: "main")
```

Opening claims the dongle and identifies its chips. `receive` starts the stream and returns captures. A capture is a
run of blocks that are contiguous in time at one frequency and one sample rate, and a new capture begins after a
retune, a sample-rate change, or a loss of samples. State that belongs to one run is declared inside the outer loop,
so it cannot outlive the run it describes.

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

Controls are asynchronous methods on the radio, which is an actor, so calling one from the main actor does not block
it.

```swift
try await radio.tune(to: 100.3e6)
try await radio.setGain(.manual(30))
```

Blocks that overlap a retune or arrive short are withheld, so the first block of a capture is tuned to the capture's
frequency throughout. Unplugging the dongle ends the loop with `RadioError.disconnected`. `docs/API.md` describes the
interface in full, and `docs/USB.md` describes the USB layer underneath it.

## Layout

```
Sources/RTL2832U/
  USB/      IOUSBHost transport: ownership, the register protocol, the bulk request queue
  Chip/     the RTL2832U's demodulator registers and the R828D tuner
  Stream/   sample conversion, the stream, the acquisition record of each block
  Radio/    the public interface: Dongle, Radio, Captures, RadioError
Tests/RTL2832UTests/
docs/API.md   the interface and the reasoning behind its shape
docs/USB.md   the USB layer, the acquisition record, and the measurements
```

## Tests and lint

```
swift test
swiftlint lint
```

The tests in `RadioTests` need hardware. They run when a dongle is on the bus and are skipped otherwise. The unplug
test needs a person and runs only with `RTL2832U_UNPLUG_TEST=1`.

## License and acknowledgements

This driver is free software under the GNU General Public License, version 2 or (at your option) any later version.
The text is in `LICENSE`.

The register sequences and tables for the RTL2832U and the R828D follow
[librtlsdr](https://osmocom.org/projects/rtl-sdr/wiki) and the
[RTL-SDR Blog fork](https://github.com/rtlsdrblog/rtl-sdr-blog), by Steve Markgraf, Dimitri Stolnikov and
contributors, whose tuner code derives from the Linux kernel's r820t driver by Mauro Carvalho Chehab. Those works
carry the same license. The USB layer, the stream and the public interface are written for this package.
