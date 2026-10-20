import Foundation
import Testing
@testable import InputPipelineCLI

@Test func generatedInputsAreReproducibleAndBounded() throws {
    let first = try syntheticFixture(.init())
    let second = try syntheticFixture(.init())
    #expect(first == second)
    #expect(try first.encoded() == second.encoded())
    #expect(first.frameCount == 60)
    #expect(first.inputs.filter { $0.kind == .anchor }.count == 9)
    #expect(first.inputs.contains { $0.kind == .imu })
    #expect(try ReplayFixture.decode(first.encoded()) == first)
}

@Test func malformedFixturesFailExplicitly() throws {
    let fixture = try syntheticFixture(.init())
    let data = try fixture.encoded()
    #expect(throws: (any Error).self) { try ReplayFixture.decode(Data("{}".utf8)) }
    #expect(throws: (any Error).self) { try ReplayFixture.decode(Data("[]".utf8)) }
    #expect(throws: (any Error).self) { try ReplayFixture.decode(Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)) }
    var bad = fixture
    bad.schemaVersion = 2
    #expect(throws: (any Error).self) { try bad.validate() }
    bad = fixture
    bad.inputs[0].evidence = "receiveTimestamp"
    #expect(throws: (any Error).self) { try bad.validate() }
    bad = fixture
    bad.inputs[0].deviceNS = -1
    #expect(throws: (any Error).self) { try bad.validate() }
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["typoField"] = 4
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try ReplayFixture.decode(unknown) }
}

@Test func syntheticOptionsRejectOverflowAndNonfiniteInputs() throws {
    var options = SyntheticOptions()
    options.cameraHz = .infinity
    #expect(throws: (any Error).self) { try syntheticFixture(options) }
    options = .init(); options.frames = Int.max
    #expect(throws: (any Error).self) { try syntheticFixture(options) }
    options = .init(); options.driftPPM = .nan
    #expect(throws: (any Error).self) { try syntheticFixture(options) }
    options = .init(); options.jitterNS = .max
    #expect(throws: (any Error).self) { try syntheticFixture(options) }
}

@Test func fullFixtureReplayExcludesHostTimingFromDeterministicBytes() async throws {
    let fixture = try syntheticFixture(.init())
    let first = try await runFixture(fixture)
    let second = try await runFixture(ReplayFixture.decode(fixture.encoded()))
    #expect(first.deterministic == second.deterministic)
    #expect(try canonicalJSON(first.deterministic) == canonicalJSON(second.deterministic))
    #expect(first.orchestration.ingress.admissionReconciles)
    #expect(first.orchestration.ingress.completionReconciles)
    #expect(first.orchestration.output.reconciles)
    #expect(first.orchestration.output.dropped == 0)
    #expect(first.deterministic.clock.inliers < first.deterministic.clock.anchors)
    #expect(abs(first.deterministic.clock.driftPPM - 120) < 1e-6)
    #expect(first.deterministic.frames.count == 60)
    // Independent signal law from fixture contract, not the native interpolation.
    for frame in first.deterministic.frames {
        let seconds = Double(frame.frameSequence) / 30
        #expect(frame.available)
        #expect(abs(frame.x - seconds) < 1e-7)
        #expect(abs(frame.y - (2 * seconds + 1)) < 1e-7)
        #expect(abs(frame.z + seconds) < 1e-7)
    }
}

@Test func missingIMUSamplesHaveExplicitUnavailableOutput() async throws {
    var options = SyntheticOptions(); options.frames = 4; options.missingEvery = 1
    let report = try await runFixture(syntheticFixture(options))
    #expect(report.deterministic.frames.count == 4)
    #expect(report.deterministic.frames.allSatisfy { !$0.available })
    #expect(report.deterministic.core.framesAccepted == report.deterministic.core.outputs)
}

@Test func explicitSourceStopsPermitGracefulFixtureCompletion() async throws {
    var options = SyntheticOptions(); options.frames = 4
    var fixture = try syntheticFixture(options)
    fixture.inputs.append(.init(kind: .source, source: "imu", state: "stopped"))
    fixture.inputs.append(.init(kind: .source, source: "camera", state: "stopped"))
    let report = try await runFixture(fixture)
    #expect(report.deterministic.finalStatus == .ok)
    #expect(report.deterministic.frames.count == 4)
    #expect(report.orchestration.ingress.completionReconciles)
}

@Test func missingOptionValuesCannotBecomeOutputFileNames() throws {
    #expect(throws: (any Error).self) { try Arguments(["generate", "--output", "--bogus"]) }
    #expect(throws: (any Error).self) { try Arguments(["demo", "--deterministic-output", "--help"]) }
    #expect(throws: (any Error).self) { try Arguments(["demo", "--frames"]) }
    #expect(throws: (any Error).self) { try Arguments(["demo", "--unknown", "12"]) }
    let arguments = try Arguments(["demo", "--drift-ppm", "-120"])
    #expect(try arguments.synthetic().driftPPM == -120)
}

@Test func fixtureIntegerTimestampsRemainExactNearInt64Maximum() throws {
    let timestamp = Int64.max - 350
    let fixture = ReplayFixture(label: "integer-precision", inputs: [
        .init(kind: .frame, sequence: .max, referenceNS: timestamp)
    ])
    let decoded = try ReplayFixture.decode(fixture.encoded())
    #expect(decoded.inputs[0].referenceNS == timestamp)
    #expect(decoded.inputs[0].sequence == UInt64.max)
}

@Test func replayClockResetReportsDiscontinuityRatherThanSuccessfulOutput() async throws {
    var options = SyntheticOptions(); options.frames = 2
    var fixture = try syntheticFixture(options)
    fixture.inputs.append(.init(kind: .anchor, sequence: 100,
                                deviceNS: 1, referenceNS: 2,
                                evidence: "trustedSameInstant"))
    do {
        _ = try await runFixture(fixture)
        Issue.record("clock discontinuity must terminate replay")
    } catch {
        #expect(String(describing: error) == "pipeline terminated: discontinuity")
    }
}
