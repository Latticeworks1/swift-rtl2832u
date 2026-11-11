import Synchronization

/// Counts the bulk requests a stream has queued or is handling, from the moment a request is registered until its
/// completion has returned, so a stop can wait for every one of them. A request is registered before it is queued and
/// registration fails once the gate is closed. Registering first and then checking the flag, against a stop that closes
/// the flag and then reads the count, means at least one side sees the other: either the request is refused, or the
/// stop sees it pending. The sequentially consistent ordering is what makes that guarantee hold; acquire and release
/// alone allow both sides to miss each other.
final class StreamGate: Sendable {
    private let open = Atomic<Bool>(true)
    private let pending = Atomic<Int>(0)

    var isOpen: Bool { open.load(ordering: .sequentiallyConsistent) }
    var pendingCount: Int { pending.load(ordering: .sequentiallyConsistent) }

    /// Registers one request. False when the gate is closed; the caller must then not queue the request.
    func enter() -> Bool {
        pending.wrappingAdd(1, ordering: .sequentiallyConsistent)
        if open.load(ordering: .sequentiallyConsistent) { return true }
        pending.wrappingSubtract(1, ordering: .sequentiallyConsistent)
        return false
    }

    /// Ends a registered request, whether it completed or was never queued.
    func leave() { pending.wrappingSubtract(1, ordering: .sequentiallyConsistent) }

    /// Refuses every later registration.
    func close() { open.store(false, ordering: .sequentiallyConsistent) }
}
