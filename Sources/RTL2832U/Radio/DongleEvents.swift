// Reports dongles as they are plugged in and unplugged, from IOKit matching notifications on the USB device class.
// The sequence opens no device, so it runs whether or not any program holds a dongle.

import Foundation
import IOKit

/// A change in the dongles on the bus.
public enum DongleEvent: Sendable, Hashable {
    /// A dongle is on the bus. The first events of a sequence describe the dongles already present.
    case connected(Dongle)
    /// A dongle has left the bus. The ID is the `Dongle.id` it had while it was connected.
    case disconnected(id: UInt64)
}

extension Dongle {
    /// Dongles arriving and leaving, beginning with the dongles already on the bus. The sequence ends when the
    /// consumer stops iterating.
    public static var events: AsyncStream<DongleEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let watch = DongleWatch(continuation: continuation)
            continuation.onTermination = { _ in watch.stop() }
            watch.start()
        }
    }
}

/// The IOKit notifications behind one event sequence. The notification port, the iterators and `known` are touched
/// only on `queue`, which is also the queue the port delivers its callbacks on, so the callbacks and `stop` never run
/// concurrently. The unchecked conformance rests on that confinement. The port holds a retained reference to the
/// watch from `start` until `stop` has destroyed the port.
final class DongleWatch: @unchecked Sendable {
    private let continuation: AsyncStream<DongleEvent>.Continuation
    private let queue = DispatchQueue(label: "RTL2832U.DongleEvents")
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var known: Set<UInt64> = []
    private var retained: Unmanaged<DongleWatch>?

    init(continuation: AsyncStream<DongleEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        queue.async {
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                self.continuation.finish()
                return
            }
            IONotificationPortSetDispatchQueue(port, self.queue)
            self.port = port
            self.retained = Unmanaged.passRetained(self)
            self.arm(kIOFirstMatchNotification, callback: DongleWatch.arrived, connected: true)
            self.arm(kIOTerminatedNotification, callback: DongleWatch.departed, connected: false)
        }
    }

    func stop() {
        queue.async {
            for iterator in self.iterators { IOObjectRelease(iterator) }
            self.iterators = []
            if let port = self.port { IONotificationPortDestroy(port) }
            self.port = nil
            self.known = []
            // A callback the port queued before it was destroyed runs ahead of this release.
            if let retained = self.retained {
                self.retained = nil
                self.queue.async { retained.release() }
            }
        }
    }

    private func arm(_ type: String, callback: IOServiceMatchingCallback, connected: Bool) {
        guard let port, let retained else { return }
        var iterator: io_iterator_t = 0
        var name = Array(type.utf8CString)
        guard IOServiceAddMatchingNotification(
            port, &name, IOServiceMatching("IOUSBHostDevice"), callback, retained.toOpaque(), &iterator
        ) == KERN_SUCCESS else { return }
        iterators.append(iterator)
        drain(iterator, connected: connected)
    }

    private func drain(_ iterator: io_iterator_t, connected: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if connected {
                guard let dongle = Dongle(service: service) else { continue }
                known.insert(dongle.id)
                continuation.yield(.connected(dongle))
            } else {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &id)
                guard known.remove(id) != nil else { continue }
                continuation.yield(.disconnected(id: id))
            }
        }
    }

    private static let arrived: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<DongleWatch>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, connected: true)
    }

    private static let departed: IOServiceMatchingCallback = { refcon, iterator in
        guard let refcon else { return }
        Unmanaged<DongleWatch>.fromOpaque(refcon).takeUnretainedValue().drain(iterator, connected: false)
    }
}
