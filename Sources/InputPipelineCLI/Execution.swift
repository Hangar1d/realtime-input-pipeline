import Foundation
import TemporalPipeline

struct DeterministicResult: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let coreConfiguration: CoreConfiguration
    let frames: [AlignedFrame]
    let core: CoreMetrics
    let clock: ClockInfo
    let finalStatus: NativeStatus
}

struct RunDiagnostics: Codable, Sendable {
    let schemaVersion: Int
    let fixtureLabel: String
    let inputRecords: Int
    let cameraInputs: Int
    let deterministic: DeterministicResult
    // Queue occupancy and real host timings are deliberately outside replay bytes.
    let orchestration: PipelineReport
    let timingMethod: String
}

func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func runFixture(_ fixture: ReplayFixture, latenessNS: Int64 = 20_000_000,
                maxGapNS: Int64 = 30_000_000) async throws -> RunDiagnostics {
    try fixture.validate()
    guard (0...1_000_000_000).contains(latenessNS), (1...1_000_000_000).contains(maxGapNS) else {
        throw FixtureError.invalid("lateness/gap is outside the CLI bounds")
    }
    var core = CoreConfiguration()
    core.latenessNS = latenessNS
    core.maxInterpolationGapNS = maxGapNS
    let pipeline = Pipeline()
    // The offline fixture has <=512 frames. Reserving that explicit bounded
    // output budget makes its result independent of output-consumer scheduling.
    let session = try await pipeline.start(config: .init(ingressCapacity: 64,
                                                         outputCapacity: max(1, fixture.frameCount), core: core))
    do {
        for input in fixture.inputs {
            if input.kind == .source {
                let source: Source = input.source == "imu" ? .imu : .camera
                let state: SourceState
                switch input.state {
                case "active": state = .active
                case "idle": state = .idle
                default: state = .stopped
                }
                try await pipeline.setSource(source, state: state, generation: session.generation)
                continue
            }
            let event: InputEvent
            switch input.kind {
            case .anchor:
                event = .anchor(.init(sequence: input.sequence!, deviceNS: input.deviceNS!, referenceNS: input.referenceNS!))
            case .imu:
                event = .imu(.init(sequence: input.sequence!, deviceNS: input.deviceNS!, x: input.x!, y: input.y!, z: input.z!))
            case .frame:
                event = .frame(.init(sequence: input.sequence!, referenceNS: input.referenceNS!))
            case .source:
                throw FixtureError.invalid("unreachable source dispatch")
            }
            switch pipeline.port.offer(event, generation: session.generation) {
            case .accepted(let ticket):
                // One producer task, no per-input Task. This deterministic pump
                // deliberately avoids host-scheduling-dependent ingress overload.
                try await pipeline.wait(ticket, generation: session.generation)
            case .rejected(let reason):
                throw FixtureError.invalid("offline admission rejected: \(reason.rawValue)")
            }
        }
        let report = try await pipeline.finish(generation: session.generation)
        var frames: [AlignedFrame] = []
        for await output in session.outputs { frames.append(output) }
        guard report.finalStatus == .ok, report.ingress.admissionReconciles,
              report.ingress.completionReconciles, report.output.reconciles,
              report.output.dropped == 0, report.output.terminated == 0 else {
            throw FixtureError.invalid("offline pipeline did not finish with reconciled accounting")
        }
        return RunDiagnostics(schemaVersion: 1, fixtureLabel: fixture.label,
                              inputRecords: fixture.inputs.count, cameraInputs: fixture.frameCount,
                              deterministic: .init(schemaVersion: 1, coreConfiguration: core, frames: frames,
                                                   core: report.core, clock: report.clock, finalStatus: report.finalStatus),
                              orchestration: report,
                              timingMethod: "Host monotonic admission-to-dequeue wait and synchronous native service durations; Welford sample variance. Synthetic timestamps are not host latency. No percentiles.")
    } catch {
        if let report = try? await pipeline.cancel(generation: session.generation),
           report.finalStatus == .discontinuity || report.finalStatus == .internalError {
            throw FixtureError.invalid("pipeline terminated: \(report.finalStatus)")
        }
        throw error
    }
}
