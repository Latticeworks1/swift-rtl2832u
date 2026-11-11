import Foundation
import Synchronization
import Testing
@testable import RTL2832U

/// Records short captures at explicit LNA, mixer and VGA gain codes. It runs only when `STAGE_GAIN_PLAN` names a plan
/// file and a dongle is on the bus. Each plan line is `label frequencyHz lna mixer vga`, where `auto` in the lna column
/// leaves the LNA and the mixer to the tuner's own control, and any further columns are tuner register writes as
/// hexadecimal `register:value:mask`; each capture is written to
/// `STAGE_GAIN_OUTPUT/<line number>_<label>.f32` as the I samples followed by the Q samples, 32-bit floats at full
/// scale 1. `status.txt` in the same folder holds the tuner's five status registers read before and after each capture.
@Suite(.serialized)
struct StageGainSweepTests {

    private static let planPath = ProcessInfo.processInfo.environment["STAGE_GAIN_PLAN"]
    private static let outputPath = ProcessInfo.processInfo.environment["STAGE_GAIN_OUTPUT"]
    private static let enabled = planPath != nil && outputPath != nil && !Dongle.all.isEmpty

    private static let sampleRate: UInt32 = 2_400_000
    private static let samplesPerPoint = 600_000
    private static let settleSeconds =
        ProcessInfo.processInfo.environment["STAGE_GAIN_SETTLE"].flatMap(Double.init) ?? 0.4

    private struct CollectorState {
        var i: [Float] = []
        var q: [Float] = []
        var wanted = 0
    }

    private final class Collector: Sendable {
        private let state = Mutex(CollectorState())

        func arm(_ count: Int) {
            state.withLock {
                $0.i.removeAll(keepingCapacity: true)
                $0.q.removeAll(keepingCapacity: true)
                $0.wanted = count
            }
        }

        func accept(_ block: IQStream.Block) {
            guard block.acquisition.tuningSettled, block.acquisition.transferComplete else { return }
            state.withLock {
                guard $0.i.count < $0.wanted else { return }
                $0.i.append(contentsOf: UnsafeBufferPointer(start: block.i, count: block.count))
                $0.q.append(contentsOf: UnsafeBufferPointer(start: block.q, count: block.count))
            }
        }

        /// The samples once the armed count has arrived, or nil while they are still being collected.
        func take() -> (i: [Float], q: [Float])? {
            state.withLock { $0.i.count >= $0.wanted && $0.wanted > 0 ? ($0.i, $0.q) : nil }
        }
    }

    @Test(.enabled(if: StageGainSweepTests.enabled), .timeLimit(.minutes(60)))
    func recordsEachPlanPoint() async throws {
        let plan = try String(contentsOfFile: Self.planPath!, encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { $0.count >= 5 }
        let output = URL(fileURLWithPath: Self.outputPath!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let first = UInt32(plan[0][1])!
        let device = try Device(dongle: try Dongle.first(), frequency: first, sampleRate: Self.sampleRate,
                                gain: .manual(0), options: Radio.Options())
        defer { device.close() }
        let collector = Collector()
        try device.startStreaming(centerHz: first) { collector.accept($0) }

        var tuned = first
        var statusLog = ""
        for (index, line) in plan.enumerated() {
            let frequency = UInt32(line[1])!
            if frequency != tuned {
                try device.setCenterFrequency(frequency)
                tuned = frequency
            }
            if line[2] == "auto" {
                try device.setGain(.automatic)
                try device.setVGACode(UInt8(line[4])!)
            } else {
                try device.setStageGain(lna: UInt8(line[2])!, mixer: UInt8(line[3])!, vga: UInt8(line[4])!)
            }
            for write in line.dropFirst(5) {
                let fields = write.split(separator: ":").map { UInt8($0, radix: 16)! }
                try device.setTunerRegister(fields[0], fields[1], mask: fields[2])
            }
            try await Task.sleep(for: .seconds(Self.settleSeconds))
            let before = try device.tunerStatus()
            collector.arm(Self.samplesPerPoint)
            var samples: (i: [Float], q: [Float])?
            while samples == nil {
                try await Task.sleep(for: .milliseconds(20))
                samples = collector.take()
            }
            var data = samples!.i.withUnsafeBufferPointer { Data(buffer: $0) }
            samples!.q.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
            try data.write(to: output.appendingPathComponent(String(format: "%04d_%@.f32", index, line[0])))
            let after = try device.tunerStatus()
            let hex = { (bytes: [UInt8]) in bytes.map { String(format: "%02x", $0) }.joined() }
            statusLog += String(format: "%04d %@ %@ %@\n", index, line[0], hex(before), hex(after))
            try statusLog.write(to: output.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
        }
        #expect(device.isConnected)
    }
}
