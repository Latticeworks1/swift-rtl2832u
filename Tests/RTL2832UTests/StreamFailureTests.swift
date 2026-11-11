import Dispatch
import Foundation
import Synchronization
import Testing
@testable import RTL2832U

struct StreamFailureTests {
    @Test func theFirstFailureIsReportedOnceAndClosesTheGate() {
        let codes = Mutex<[Int32]>([])
        let state = USBTransport.StreamState { code in codes.withLock { $0.append(code) } }
        #expect(state.gate.enter())
        state.gate.leave()

        state.fail(-1)
        state.fail(-2)

        #expect(codes.withLock { $0 } == [-1])
        #expect(state.status.load(ordering: .acquiring) == -1)
        #expect(!state.gate.isOpen)
    }

    @Test func concurrentFailuresReportExactlyOne() {
        for _ in 0..<200 {
            let count = Atomic<Int>(0)
            let state = USBTransport.StreamState { _ in count.wrappingAdd(1, ordering: .relaxed) }
            DispatchQueue.concurrentPerform(iterations: 8) { state.fail(Int32($0 + 1)) }
            #expect(count.load(ordering: .relaxed) == 1)
        }
    }
}
