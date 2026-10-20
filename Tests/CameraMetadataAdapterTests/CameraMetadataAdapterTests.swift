import AVFoundation
import CoreMedia
import Testing
@testable import CameraMetadataAdapter
@testable import TemporalPipeline

private func adapter(port: InputPort, generation: UInt64 = 1,
                     nextSequence: UInt64 = 1) throws -> CameraMetadataAdapter {
    try CameraMetadataAdapter(sessionClock: CMClockGetHostTimeClock(), inputPort: port,
                              generation: generation, authorizationStatus: .authorized,
                              nextSequence: nextSequence)
}

private func nanoseconds(_ value: CMTime) throws -> HostNanoseconds {
    try CameraMetadataAdapter.hostNanoseconds(value).get()
}

@Test func creationRequiresExistingAuthorizationWithoutQueryingOrRequestingTCC() throws {
    for status: AVAuthorizationStatus in [.notDetermined, .restricted, .denied] {
        #expect(throws: CameraAdapterError.cameraNotAuthorized) {
            _ = try CameraMetadataAdapter(sessionClock: CMClockGetHostTimeClock(),
                                          inputPort: InputPort(), generation: 1,
                                          authorizationStatus: status)
        }
    }
    #expect(throws: CameraAdapterError.invalidGeneration) {
        _ = try adapter(port: InputPort(), generation: 0)
    }
    _ = try adapter(port: InputPort())
}

@Test func checkedRationalNanosecondsCoverRoundingAndInt64Limits() throws {
    #expect(try nanoseconds(.zero) == HostNanoseconds(value: 0, rounded: false))
    #expect(try nanoseconds(CMTime(value: 1, timescale: 3)) == HostNanoseconds(value: 333_333_333, rounded: true))
    #expect(try nanoseconds(CMTime(value: 2, timescale: 3)) == HostNanoseconds(value: 666_666_667, rounded: true))
    #expect(try nanoseconds(CMTime(value: 1, timescale: 2_000_000_000)) == HostNanoseconds(value: 1, rounded: true))
    #expect(try nanoseconds(CMTime(value: 3, timescale: 2_000_000_000)) == HostNanoseconds(value: 2, rounded: true))
    #expect(try nanoseconds(CMTime(value: 5, timescale: 2)) == HostNanoseconds(value: 2_500_000_000, rounded: false))
    #expect(try nanoseconds(CMTime(value: .max, timescale: 1_000_000_000)) == HostNanoseconds(value: .max, rounded: false))
    #expect(CameraMetadataAdapter.hostNanoseconds(CMTime(value: .max, timescale: 1)) == .failure(.timestampOverflow))
    #expect(CameraMetadataAdapter.hostNanoseconds(CMTime(value: 9_223_372_037, timescale: 1)) == .failure(.timestampOverflow))
    #expect(CameraMetadataAdapter.hostNanoseconds(CMTime(value: -1, timescale: 1)) == .failure(.negativeTimestamp))
    #expect(CameraMetadataAdapter.hostNanoseconds(CMTime(value: 1, timescale: 1, flags: .valid, epoch: 1)) == .failure(.unsupportedEpoch))
    for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
        #expect(CameraMetadataAdapter.hostNanoseconds(time) == .failure(.conversionFailed))
    }
}

@Test func synchronousBoundedPortAdmissionAndCaptureDropsAreCountedSeparately() async throws {
    let port = InputPort()
    let box = BoundedMailbox(generation: 1, capacity: 1)
    port.install(box)
    let value = try adapter(port: port)
    guard case .offered(.accepted(let ticket)) = value.submitPresentationTime(CMTime(value: 3, timescale: 2)) else {
        Issue.record("First copied metadata was not admitted"); return
    }
    #expect(value.submitPresentationTime(CMTime(value: 2, timescale: 1)) == .offered(.rejected(.full)))
    value.recordCaptureDrop()
    value.recordCaptureDrop()
    let work = try #require(await box.next())
    #expect(work.ticket == ticket)
    guard case .event(.frame(let copied)) = work.message else { Issue.record("Expected copied camera metadata"); return }
    #expect(copied == CameraFrame(sequence: 1, referenceNS: 1_500_000_000))
    box.complete(ticket)
    let metrics = value.metrics
    #expect(metrics.receivedFrames == 2 && metrics.acceptedFrames == 1 && metrics.ingressFull == 1)
    #expect(metrics.captureDroppedFrames == 2 && metrics.inFlightOffers == 0 && metrics.reconciles)
    box.closeForFinish()
}

@Test func invalidTimeRejectionsConsumeNoSequenceOrMailboxCapacity() async throws {
    let port = InputPort()
    let box = BoundedMailbox(generation: 1, capacity: 1)
    port.install(box)
    let value = try adapter(port: port)
    for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
        #expect(value.submitPresentationTime(time) == .rejected(.invalidPresentationTime))
    }
    #expect(value.submitPresentationTime(CMTime(value: 1, timescale: 1, flags: .valid, epoch: 2)) == .rejected(.unsupportedEpoch))
    #expect(value.submitPresentationTime(CMTime(value: -1, timescale: 1)) == .rejected(.negativeTimestamp))
    #expect(value.submitPresentationTime(CMTime(value: .max, timescale: 1)) == .rejected(.timestampOverflow))
    guard case .offered(.accepted(let ticket)) = value.submitPresentationTime(.zero) else {
        Issue.record("Valid zero metadata was not admitted"); return
    }
    let work = try #require(await box.next())
    guard case .event(.frame(let copied)) = work.message else { Issue.record("Expected frame"); return }
    #expect(copied.sequence == 1 && copied.referenceNS == 0)
    box.complete(ticket)
    let metrics = value.metrics
    #expect(metrics.receivedFrames == 8 && metrics.acceptedFrames == 1)
    #expect(metrics.invalidPresentationTime == 4 && metrics.unsupportedEpoch == 1)
    #expect(metrics.negativeTimestamp == 1 && metrics.timestampOverflow == 1 && metrics.reconciles)
    box.closeForFinish()
}

@Test func staleGenerationClosedPortInvalidationAndSequenceExhaustion() async throws {
    let port = InputPort()
    let old = try adapter(port: port)
    #expect(old.submitPresentationTime(.zero) == .offered(.rejected(.closed)))
    let box = BoundedMailbox(generation: 2, capacity: 2)
    port.install(box)
    #expect(old.submitPresentationTime(.zero) == .offered(.rejected(.staleGeneration)))
    old.invalidate()
    #expect(old.submitPresentationTime(.zero) == .rejected(.invalidated))
    #expect(old.metrics.ingressClosed == 1 && old.metrics.ingressStaleGeneration == 1)
    #expect(old.metrics.invalidatedFrames == 1 && old.metrics.reconciles)

    let last = try adapter(port: port, generation: 2, nextSequence: .max)
    guard case .offered(.accepted(let ticket)) = last.submitPresentationTime(.zero) else {
        Issue.record("Final representable sequence was not admitted"); return
    }
    #expect(last.submitPresentationTime(.zero) == .rejected(.sequenceExhausted))
    let work = try #require(await box.next())
    guard case .event(.frame(let copied)) = work.message else { Issue.record("Expected frame"); return }
    #expect(copied.sequence == .max)
    box.complete(ticket)
    #expect(last.metrics.acceptedFrames == 1 && last.metrics.sequenceExhausted == 1 && last.metrics.reconciles)
    box.closeForFinish()
}

@Test func counterSaturationIsExplicit() {
    var metrics = CameraAdapterMetrics()
    metrics.captureDroppedFrames = .max
    metrics.increment(\.captureDroppedFrames)
    #expect(metrics.captureDroppedFrames == .max && metrics.counterSaturated)
    #expect(!metrics.reconciles)
}

@Test func copiedHostMetadataReachesPipelineWithoutCalibratingTheIMU() async throws {
    let pipeline = Pipeline()
    let session = try await pipeline.start()
    let value = try adapter(port: pipeline.port, generation: session.generation)
    for timestamp in [CMTime.zero, CMTime(value: 3, timescale: 2)] {
        guard case .offered(.accepted(let ticket)) = value.submitPresentationTime(timestamp) else {
            Issue.record("Metadata was not admitted"); return
        }
        try await pipeline.wait(ticket, generation: session.generation)
    }
    value.invalidate()
    let report = try await pipeline.finish(generation: session.generation)
    var outputs: [AlignedFrame] = []
    for await output in session.outputs { outputs.append(output) }
    #expect(outputs.map(\.referenceNS) == [0, 1_500_000_000])
    #expect(outputs.map(\.frameSequence) == [1, 2])
    #expect(outputs.allSatisfy { $0.quality == .clockUnavailable && !$0.available })
    #expect(report.core.framesAccepted == 2 && report.core.clockUnavailable == 2)
    #expect(report.clock.state == 0 && report.ingress.processed == 2)
    #expect(value.metrics.acceptedFrames == 2 && value.metrics.reconciles)
}
