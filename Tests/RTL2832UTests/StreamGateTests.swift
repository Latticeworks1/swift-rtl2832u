import Foundation
import Synchronization
import Testing
@testable import RTL2832U

private protocol Gating: Sendable {
    func enter() -> Bool
    func leave()
    func close()
    var pendingCount: Int { get }
}

extension StreamGate: Gating {}

/// Checks the flag and registers afterwards, so a stop can close the flag and read zero between the two steps. It is
/// the positive control: the invariant test must fail on it.
private final class CheckThenRegisterGate: Gating {
    private let open = Atomic<Bool>(true)
    private let pending = Atomic<Int>(0)

    func enter() -> Bool {
        guard open.load(ordering: .sequentiallyConsistent) else { return false }
        sched_yield()
        pending.wrappingAdd(1, ordering: .sequentiallyConsistent)
        return true
    }

    func leave() { pending.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
    func close() { open.store(false, ordering: .sequentiallyConsistent) }
    var pendingCount: Int { pending.load(ordering: .sequentiallyConsistent) }
}

private final class Flag: Sendable {
    let value = Atomic<Bool>(false)
    let count = Atomic<Int>(0)
}

struct StreamGateTests {
    /// Workers register and release requests in a loop while one thread closes the gate and waits for it to drain.
    /// A registration that is held while the drain has already finished means the stop returned with a request live.
    private func violations(rounds: Int, workers: Int = 3, make: () -> any Gating) -> Int {
        let total = Flag()
        for _ in 0..<rounds {
            let gate = make()
            let drained = Flag()
            let done = Flag()
            let group = DispatchGroup()
            for _ in 0..<workers {
                group.enter()
                Thread.detachNewThread {
                    while !done.value.load(ordering: .sequentiallyConsistent) {
                        if gate.enter() {
                            if drained.value.load(ordering: .sequentiallyConsistent) {
                                total.count.wrappingAdd(1, ordering: .relaxed)
                            }
                            gate.leave()
                        }
                    }
                    group.leave()
                }
            }
            usleep(UInt32.random(in: 0..<200))
            gate.close()
            while gate.pendingCount > 0 {}
            drained.value.store(true, ordering: .sequentiallyConsistent)
            usleep(100)
            done.value.store(true, ordering: .sequentiallyConsistent)
            group.wait()
        }
        return total.count.load(ordering: .relaxed)
    }

    @Test func noRequestIsHeldAfterTheGateHasDrained() {
        #expect(violations(rounds: 3000) { StreamGate() } == 0)
    }

    @Test func theInvariantCheckCatchesACheckThenRegisterGate() {
        #expect(violations(rounds: 3000) { CheckThenRegisterGate() } > 0)
    }

    @Test func aClosedGateRefusesAndLeavesNothingPending() {
        let gate = StreamGate()
        #expect(gate.enter())
        gate.close()
        #expect(!gate.enter())
        #expect(gate.pendingCount == 1)
        gate.leave()
        #expect(gate.pendingCount == 0)
    }
}
