// The record that a dongle has left the bus, shared between the transport and the interest handlers that IOUSBHost
// runs on its own queue.

import Synchronization

private struct DetachDelivery {
    var handler: (@Sendable () -> Void)?
    var delivered = false
}

extension USBTransport {

    /// Shared with the interest handler, which runs on an IOUSBHost queue.
    final class Link: Sendable {
        let lost = Atomic<Bool>(false)
        private let delivery = Mutex(DetachDelivery())

        var handler: (@Sendable () -> Void)? {
            get { delivery.withLock { $0.handler } }
            set {
                delivery.withLock { $0.handler = newValue }
                if lost.load(ordering: .acquiring) { deliver() }
            }
        }

        /// Marks the device gone and calls the detach handler, once however many services report termination.
        func markLost() {
            lost.store(true, ordering: .releasing)
            deliver()
        }

        /// Calls the handler once, whichever of the termination and the handler's assignment comes second.
        private func deliver() {
            let callback: (@Sendable () -> Void)? = delivery.withLock { state in
                guard !state.delivered, let handler = state.handler else { return nil }
                state.delivered = true
                return handler
            }
            callback?()
        }
    }
}
