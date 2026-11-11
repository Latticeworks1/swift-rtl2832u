import Synchronization
import Testing
@testable import RTL2832U

struct DetachLinkTests {

    @Test func aHandlerAssignedBeforeTheLossIsCalledOnceForSeveralTerminations() {
        let link = USBTransport.Link()
        let calls = Atomic<Int>(0)
        link.handler = { calls.add(1, ordering: .relaxed) }

        #expect(calls.load(ordering: .relaxed) == 0)
        link.markLost()
        link.markLost()

        #expect(calls.load(ordering: .relaxed) == 1)
        let lost = link.lost.load(ordering: .acquiring)
        #expect(lost)
    }

    @Test func aHandlerAssignedAfterTheLossIsCalledOnAssignment() {
        let link = USBTransport.Link()
        let calls = Atomic<Int>(0)
        link.markLost()

        link.handler = { calls.add(1, ordering: .relaxed) }
        #expect(calls.load(ordering: .relaxed) == 1)

        link.handler = { calls.add(1, ordering: .relaxed) }
        link.markLost()
        #expect(calls.load(ordering: .relaxed) == 1)
    }

    @Test func concurrentTerminationAndAssignmentDeliverExactlyOnce() async {
        for _ in 0..<2_000 {
            let link = USBTransport.Link()
            let calls = Counter()

            await withTaskGroup(of: Void.self) { group in
                group.addTask { link.markLost() }
                group.addTask { link.handler = { calls.value.add(1, ordering: .relaxed) } }
            }
            #expect(calls.value.load(ordering: .relaxed) == 1)
        }
    }
}

/// A count that concurrent tasks can share, which a noncopyable `Atomic` local cannot be.
private final class Counter: Sendable {
    let value = Atomic<Int>(0)
}
