// The USB layer of the driver, on IOUSBHost: ownership of the device and its interface 0, vendor control transfers
// for the register blocks, the demodulator pages and the I2C bridge, and the queue of bulk requests that carries the
// samples. docs/USB.md describes the layer and the measurements made through it.

import Foundation
import IOKit
@preconcurrency import IOUSBHost
import Synchronization

final class USBTransport {

    enum Failure: Error, CustomStringConvertible {
        case notFound
        case ioService(String)
        case control(String, NSError)
        case short(String, expected: Int, got: Int)
        case buffer(bytes: Int)
        case payload(String, bytes: Int)
        case disconnected

        var description: String {
            switch self {
            case .notFound: "the dongle is not on the USB bus"
            case .ioService(let what): what
            case .control(let what, let error): "\(what): \(error.localizedDescription) (\(error.domain) \(error.code))"
            case .short(let what, let expected, let got): "\(what): expected \(expected) bytes, transferred \(got)"
            case .buffer(let bytes): "could not allocate a \(bytes)-byte transfer buffer"
            case .payload(let what, let bytes): "\(what): \(bytes) bytes exceed the 65535 a control transfer carries"
            case .disconnected: "device disconnected"
            }
        }
    }

    /// The register blocks addressed by the high byte of wIndex.
    enum Block: UInt8 {
        case demod = 0, usb = 1, sys = 2, tuner = 3, rom = 4, ir = 5, i2c = 6
    }

    /// The outcome of reading the identification register of one candidate tuner address.
    struct TunerProbe {
        let address: UInt8
        let raw: UInt8?
        let failure: String?

        /// Register 0x00 reads 0x69 on the Rafael Micro R820T, R820T2 and R828D, which share the check value; the
        /// board is not implied.
        var isR82xx: Bool { raw == USBTransport.r82xxCheckValue }
    }

    /// Realtek's vendor ID and the two product IDs the RTL2832U enumerates with.
    static let vendorID = 0x0bda
    static let productIDs: Set<Int> = [0x2832, 0x2838]
    static let controlTimeout: TimeInterval = 0.3
    static let tunerAddresses: [UInt8] = [0x34, 0x74]
    static let r82xxCheckRegister: UInt8 = 0x00
    static let r82xxCheckValue: UInt8 = 0x69

    private static let vendorIn: UInt8 = 0xC0
    private static let vendorOut: UInt8 = 0x40
    private static let bulkInEndpoint = 0x81
    private static let serviceTerminated: UInt32 = 0xE000_0010

    private let link = Link()

    final class StreamState: Sendable {
        let gate = StreamGate()
        let status = Atomic<Int32>(0)
        let onFailure: (@Sendable (Int32) -> Void)?

        init(onFailure: (@Sendable (Int32) -> Void)?) { self.onFailure = onFailure }

        /// Closes the gate and records the first failure, which is the only one reported to `onFailure`.
        func fail(_ code: Int32) {
            gate.close()
            if status.compareExchange(expected: 0, desired: code, ordering: .acquiringAndReleasing).exchanged {
                onFailure?(code)
            }
        }
    }

    private var stream: StreamState?
    private var device: IOUSBHostDevice?
    private var interface: IOUSBHostInterface?
    private var bulkIn: IOUSBHostPipe?

    /// Called once when the device or its interface is terminated in the registry: on an IOUSBHost queue, or from
    /// the assignment itself when the device was already gone by then.
    var onDetach: (@Sendable () -> Void)? {
        get { link.handler }
        set { link.handler = newValue }
    }

    var isOpen: Bool { device != nil && !link.lost.load(ordering: .acquiring) }

    // MARK: - Ownership

    /// Opens the device with registry entry ID `entryID` and its interface 0. Any failure releases what was already
    /// acquired, so a thrown error leaves no partial ownership.
    init(entryID: UInt64) throws {
        do {
            try open(entryID: entryID)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// Releases the interface first, then the device. Safe to call repeatedly.
    func close() {
        stopStream()
        bulkIn = nil
        interface?.destroy()
        interface = nil
        device?.destroy()
        device = nil
    }

    private func open(entryID: UInt64) throws {
        guard let service = Self.service(entryID: entryID) else { throw Failure.notFound }
        defer { IOObjectRelease(service) }

        let link = self.link
        let interest: IOUSBHostInterestHandler = { _, message, _ in
            if message == USBTransport.serviceTerminated { link.markLost() }
        }

        do {
            device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: interest)
        } catch {
            throw Failure.ioService(
                "opening the device failed: \(error.localizedDescription) (\((error as NSError).code))")
        }

        guard let child = Self.interfaceService(of: service, number: 0) else {
            throw Failure.ioService("the device has no interface 0 in the registry")
        }
        defer { IOObjectRelease(child) }
        do {
            interface = try IOUSBHostInterface(__ioService: child, options: [], queue: nil, interestHandler: interest)
        } catch {
            throw Failure.ioService(
                "claiming interface 0 failed: \(error.localizedDescription) (\((error as NSError).code))")
        }
    }

    /// The device with this registry entry ID, if it is still on the bus and is an RTL2832U.
    private static func service(entryID: UInt64) -> io_service_t? {
        guard let matching = IORegistryEntryIDMatching(entryID) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        let vendor: Int = property(service, "idVendor") ?? 0
        let product: Int = property(service, "idProduct") ?? 0
        guard vendor == vendorID, productIDs.contains(product) else {
            IOObjectRelease(service)
            return nil
        }
        return service
    }

    private static func interfaceService(of device: io_service_t, number: Int) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            let value: Int? = property(child, "bInterfaceNumber")
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0, value == number { return child }
            IOObjectRelease(child)
        }
        return nil
    }

    // MARK: - Control transfers

    /// One vendor request with bRequest 0, the form every register access takes. A transfer that moves fewer
    /// bytes than asked for is reported as an error.
    func transfer(_ what: String, read: Bool, value: UInt16, index: UInt16, bytes: [UInt8]) throws -> [UInt8] {
        guard let device, !link.lost.load(ordering: .acquiring) else { throw Failure.disconnected }
        guard bytes.count <= Int(UInt16.max) else { throw Failure.payload(what, bytes: bytes.count) }

        let request = IOUSBDeviceRequest(
            bmRequestType: read ? Self.vendorIn : Self.vendorOut,
            bRequest: 0,
            wValue: value,
            wIndex: index,
            wLength: UInt16(bytes.count)
        )
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var moved = 0
        do {
            try device.__send(request, data: data, bytesTransferred: &moved, completionTimeout: Self.controlTimeout)
        } catch {
            throw Failure.control(what, error as NSError)
        }
        guard moved == bytes.count else { throw Failure.short(what, expected: bytes.count, got: moved) }
        return [UInt8](data)
    }

    // MARK: - Bulk samples

    /// The pipe of endpoint 0x81, opened on first use and released with the interface.
    private func bulkPipe() throws -> IOUSBHostPipe {
        guard let interface, !link.lost.load(ordering: .acquiring) else { throw Failure.disconnected }
        if let bulkIn { return bulkIn }
        do {
            let pipe = try interface.copyPipe(withAddress: Self.bulkInEndpoint)
            bulkIn = pipe
            return pipe
        } catch {
            throw Failure.control("open bulk endpoint 0x81", error as NSError)
        }
    }

    /// Keeps `depth` bulk requests of `blockLength` bytes queued on endpoint 0x81 so the controller always has a buffer
    /// to fill. `handler` runs on the pipe's completion queue once per filled buffer and must return before that buffer
    /// is queued again, so it should copy or convert and return. The stream stops on `stopStream`, on a failed request
    /// (reported by `streamStatus` and, once, by `onFailure` on the completion queue, which must return quickly) or
    /// when the interface closes.
    func startStream(
        blockLength: Int,
        depth: Int,
        onFailure: (@Sendable (Int32) -> Void)? = nil,
        handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) throws {
        stopStream()
        let pipe = try bulkPipe()
        let state = StreamState(onFailure: onFailure)
        stream = state
        for _ in 0..<depth {
            do {
                try Self.submit(pipe, try Self.buffer(bytes: blockLength), state, handler)
            } catch let failure as Failure {
                stopStream()
                throw failure
            } catch {
                stopStream()
                throw Failure.control("queue bulk request", error as NSError)
            }
        }
    }

    /// The IOReturn of the request that ended the last stream, or 0 while it runs or after a normal stop.
    var streamStatus: Int32 { stream?.status.load(ordering: .acquiring) ?? 0 }

    /// The longest `stopStream` waits for a handler that is already running.
    static let drainTimeout: TimeInterval = 2

    /// Closes the gate, aborts the queued requests, and waits up to `drainTimeout` until every request that was queued
    /// or running has finished, so the caller may reconfigure the device and reuse the handler's state. No handler call
    /// starts after this returns true. The abort is repeated while requests remain, because a completion that was
    /// already past its check can queue one more request after the first abort. The result is false when the abort was
    /// refused or a request was still pending at the deadline; the stream's buffers and state stay alive through the
    /// pending completions, so that case cannot touch freed memory. Must not be called from the handler.
    @discardableResult
    func stopStream() -> Bool {
        guard let state = stream else { return true }
        state.gate.close()
        var aborted = true
        if let bulkIn {
            do { try bulkIn.__abort(with: .synchronous) } catch { aborted = false }
        }
        let deadline = Date().addingTimeInterval(Self.drainTimeout)
        var polls = 0
        while state.gate.pendingCount > 0 {
            guard Date() < deadline else {
                stream = nil
                return false
            }
            usleep(200)
            polls += 1
            if polls % 5 == 0, state.gate.pendingCount > 0 { try? bulkIn?.__abort(with: .synchronous) }
        }
        stream = nil
        return aborted
    }

    /// A buffer for one transfer. An allocation that fails is thrown rather than trapped.
    private static func buffer(bytes: Int) throws -> NSMutableData {
        guard let data = NSMutableData(length: bytes) else { throw Failure.buffer(bytes: bytes) }
        return data
    }

    /// Bounds a byte count the kernel reports to the size of the buffer it wrote into.
    private static func clamp(_ moved: Int, to length: Int) -> Int {
        min(max(moved, 0), length)
    }

    private static func submit(_ pipe: IOUSBHostPipe, _ buffer: NSMutableData, _ state: StreamState,
                               _ handler: @escaping @Sendable (UnsafeRawBufferPointer) -> Void) throws {
        guard state.gate.enter() else { return }
        nonisolated(unsafe) let buffer = buffer
        do {
            try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { status, moved in
                defer { state.gate.leave() }
                guard state.gate.isOpen else { return }
                guard status == kIOReturnSuccess else {
                    state.fail(status)
                    return
                }
                handler(UnsafeRawBufferPointer(start: buffer.bytes, count: clamp(moved, to: buffer.length)))
                do { try submit(pipe, buffer, state, handler) } catch {
                    let code = Int32(truncatingIfNeeded: (error as NSError).code)
                    state.fail(code == kIOReturnSuccess ? kIOReturnError : code)
                }
            }
        } catch {
            state.gate.leave()
            throw error
        }
    }
}
