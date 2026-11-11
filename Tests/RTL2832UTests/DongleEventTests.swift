import Foundation
import Testing
@testable import RTL2832U

/// Runs only with a dongle on the bus. The unplug half of the events needs a person and runs with
/// `RTL2832U_UNPLUG_TEST=1`, which waits for a departure after the first arrival.
struct DongleEventTests {
    private static let hasDongle = !Dongle.all.isEmpty
    private static let unplugRequested = hasDongle && ProcessInfo.processInfo.environment["RTL2832U_UNPLUG_TEST"] != nil

    @Test(.enabled(if: DongleEventTests.hasDongle), .timeLimit(.minutes(1)))
    func theEventsReportThePresentDongleAsConnected() async throws {
        let expected = try Dongle.first()
        var connected: [Dongle] = []
        for await event in Dongle.events {
            if case let .connected(dongle) = event {
                connected.append(dongle)
                if dongle.id == expected.id { break }
            }
        }
        #expect(connected.contains { $0.id == expected.id })
    }

    @Test(.enabled(if: DongleEventTests.unplugRequested), .timeLimit(.minutes(1)))
    func aDepartureIsReportedWithTheIDOfTheConnectedDongle() async throws {
        let expected = try Dongle.first()
        var arrived = false
        for await event in Dongle.events {
            switch event {
            case let .connected(dongle):
                if dongle.id == expected.id { arrived = true }
            case let .disconnected(id):
                if arrived, id == expected.id { return }
            }
        }
        Issue.record("the sequence ended without a departure")
    }
}
