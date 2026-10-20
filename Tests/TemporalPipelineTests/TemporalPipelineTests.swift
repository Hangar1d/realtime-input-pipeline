import Testing
import Synchronization
import PipelineCore
@testable import TemporalPipeline

private final class Signal: Sendable {
    private struct State { var signalled = false; var waiter: CheckedContinuation<Void, Never>? }
    private let state = Mutex(State())
    func signal() {
        let waiter = state.withLock { state in
            state.signalled = true
            let waiter = state.waiter; state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.signalled { return true }
                precondition(state.waiter == nil)
                state.waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
private final class WeakPipelineReference {
    weak var value: Pipeline?
    init(_ value: Pipeline?) { self.value = value }
}
private func frame(_ sequence: UInt64) -> InputEvent { .frame(CameraFrame(sequence: sequence, referenceNS: Int64(sequence))) }
private func accepted(_ receipt: OfferReceipt) throws -> Ticket {
    guard case .accepted(let ticket) = receipt else { throw PipelineError.closed }
    return ticket
}
private func smallConfig(outputCapacity: Int = 16) -> PipelineConfiguration {
    var core = CoreConfiguration()
    core.anchorCapacity = 8; core.minAnchors = 3; core.minAnchorSpanNS = 20
    core.maxQueryDistanceNS = 1_000; core.maxDriftPPM = 100; core.maxAnchorResidualNS = 0
    core.latenessNS = 1_000; core.maxInterpolationGapNS = 100
    return PipelineConfiguration(ingressCapacity: 8, outputCapacity: outputCapacity, core: core)
}
private func pump(_ events: [InputEvent], pipeline: Pipeline, generation: UInt64) async throws {
    for event in events {
        let ticket = try accepted(pipeline.port.offer(event, generation: generation))
        try await pipeline.wait(ticket, generation: generation)
    }
}

private final class ConsumerGate: Sendable {
    let entered = Signal()
    let mailbox = Mutex<BoundedMailbox?>(nil)
    private let proceed = Signal()
    func observeStart(_ mailbox: BoundedMailbox) async {
        self.mailbox.withLock { $0 = mailbox }
        entered.signal()
        await proceed.wait()
    }
    func open() { proceed.signal() }
}
private struct HeldSession: Sendable {
    let pipeline: Pipeline
    let session: Session
    let mailbox: BoundedMailbox
    let gate: ConsumerGate
}
private func heldSession() async throws -> HeldSession {
    let gate = ConsumerGate()
    let pipeline = Pipeline(beforeConsumerStart: { await gate.observeStart($0) })
    let session = try await pipeline.start(config: smallConfig())
    await gate.entered.wait()
    do {
        let mailbox = try #require(gate.mailbox.withLock { $0 })
        return HeldSession(pipeline: pipeline, session: session, mailbox: mailbox, gate: gate)
    } catch { gate.open(); throw error }
}
private func waitForProgress(_ mailbox: BoundedMailbox, ticket: Ticket) async throws {
    while mailbox.progressTicket != ticket {
        try Task.checkCancellation()
        await Task.yield()
    }
}

@Test(.timeLimit(.minutes(1))) func publicWaitConflictRejectsSourceControlBeforeAdmission() async throws {
    let held = try await heldSession()
    defer { held.gate.open() }
    let pipeline = held.pipeline, generation = held.session.generation
    let first = try accepted(pipeline.port.offer(frame(1), generation: generation))
    let waiting = Task { try await pipeline.wait(first, generation: generation) }
    try await waitForProgress(held.mailbox, ticket: first)
    do {
        try await pipeline.setSource(.imu, state: .stopped, generation: generation)
        Issue.record("A conflicting control was admitted")
    } catch { #expect(error as? PipelineError == .concurrentWaiter) }
    let rejected = held.mailbox.metrics
    #expect(rejected.attempts == 2 && rejected.accepted == 1 && rejected.busy == 1)
    #expect(rejected.queuedControls == 0 && rejected.admissionReconciles && rejected.completionReconciles)
    let second = try accepted(pipeline.port.offer(frame(2), generation: generation))
    #expect(second.value == first.value + 1) // The rejection consumed no ticket.
    held.gate.open()
    try await waiting.value
    try await pipeline.wait(second, generation: generation)
    // Stopped is terminal within a native session. Successful activation proves
    // that the rejected stop never changed the source state.
    try await pipeline.setSource(.imu, state: .active, generation: generation)
    let report = try await pipeline.finish(generation: generation)
    #expect(report.ingress.attempts == 4 && report.ingress.accepted == 3 && report.ingress.processed == 3)
    #expect(report.ingress.busy == 1 && report.core.rejectedSourceInactive == 0)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
}

@Test func controlCancellationBeforeAdmissionConsumesNoTicketOrIngressAttempt() async throws {
    let pipeline = Pipeline()
    let session = try await pipeline.start(config: smallConfig())
    let proceed = Signal()
    let cancelled = Task {
        await proceed.wait()
        try await pipeline.setSource(.imu, state: .stopped, generation: session.generation)
    }
    cancelled.cancel()
    proceed.signal()
    do { try await cancelled.value; Issue.record("Pre-admission cancellation succeeded") }
    catch { #expect(error as? PipelineError == .cancelled) }
    let first = try accepted(pipeline.port.offer(frame(1), generation: session.generation))
    #expect(first.value == 1)
    try await pipeline.wait(first, generation: session.generation)
    try await pipeline.setSource(.imu, state: .active, generation: session.generation)
    let report = try await pipeline.finish(generation: session.generation)
    #expect(report.ingress.attempts == 2 && report.ingress.accepted == 2 && report.ingress.processed == 2)
    #expect(report.ingress.busy == 0 && report.core.rejectedSourceInactive == 0)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)

    // Covers onCancel winning before continuation registration, independently
    // of the already-cancelled Task check above.
    let box = BoundedMailbox(generation: 1, capacity: 1)
    let cancellation = ProgressCancellation(); cancellation.cancel()
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.registerControl(.imu, state: .stopped, generation: 1, completion: ControlResult(),
                                token: 1, continuation: continuation, cancellation: cancellation)
        }
        Issue.record("Pre-registration cancellation admitted a control")
    } catch { #expect(error as? PipelineError == .cancelled) }
    #expect(box.metrics.attempts == 0 && box.metrics.accepted == 0 && box.progressTicket == nil)
    #expect(try accepted(box.offer(frame(1), generation: 1)).value == 1)
    box.cancel()
    #expect(box.metrics.admissionReconciles && box.metrics.completionReconciles)
}

@Test(.timeLimit(.minutes(1))) func controlCancellationAfterAdmissionCancelsWaitWithoutRollback() async throws {
    let held = try await heldSession()
    defer { held.gate.open() }
    let pipeline = held.pipeline, generation = held.session.generation
    let control = Task { try await pipeline.setSource(.imu, state: .stopped, generation: generation) }
    let ticket = Ticket(value: 1)
    try await waitForProgress(held.mailbox, ticket: ticket)
    control.cancel()
    do { try await control.value; Issue.record("A cancelled control waiter succeeded before execution") }
    catch { #expect(error as? PipelineError == .cancelled) }
    #expect(held.mailbox.progressTicket == nil && held.mailbox.metrics.accepted == 1)
    held.gate.open()
    try await pipeline.wait(ticket, generation: generation)
    do {
        try await pipeline.setSource(.imu, state: .active, generation: generation)
        Issue.record("Cancelling a waiter rolled back its admitted stop")
    } catch { #expect(error as? PipelineError == .native(.sourceInactive)) }
    let report = try await pipeline.finish(generation: generation)
    #expect(report.ingress.attempts == 2 && report.ingress.accepted == 2 && report.ingress.processed == 2)
    #expect(report.core.rejectedSourceInactive == 1 && report.ingress.cancelledBuffered == 0)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
}

@Test(.timeLimit(.minutes(1))) func finishDrainsAnOutstandingControlWaiter() async throws {
    let held = try await heldSession()
    defer { held.gate.open() }
    let pipeline = held.pipeline, generation = held.session.generation
    let control = Task { try await pipeline.setSource(.imu, state: .idle, generation: generation) }
    try await waitForProgress(held.mailbox, ticket: Ticket(value: 1))
    let finishing = Task { try await pipeline.finish(generation: generation) }
    while held.mailbox.isOpen { try Task.checkCancellation(); await Task.yield() }
    held.gate.open()
    try await control.value
    let report = try await finishing.value
    #expect(!report.cancelled && report.finalStatus == .ok && held.mailbox.progressTicket == nil)
    #expect(report.ingress.accepted == 1 && report.ingress.processed == 1)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
}

@Test(.timeLimit(.minutes(1))) func restartCancelsAnOutstandingControlWaiterAndIsolatesGeneration() async throws {
    let held = try await heldSession()
    defer { held.gate.open() }
    let pipeline = held.pipeline, generation = held.session.generation
    let control = Task { try await pipeline.setSource(.imu, state: .stopped, generation: generation) }
    try await waitForProgress(held.mailbox, ticket: Ticket(value: 1))
    let restarting = Task { try await pipeline.restart(config: smallConfig()) }
    while !held.mailbox.isCancelled { try Task.checkCancellation(); await Task.yield() }
    do { try await control.value; Issue.record("Restart left an outstanding old control waiter successful") }
    catch { #expect(error as? PipelineError == .cancelled) }
    #expect(held.mailbox.progressTicket == nil)
    held.gate.open()
    let fresh = try await restarting.value
    #expect(fresh.generation == generation + 1)
    #expect(pipeline.port.offer(frame(1), generation: generation) == .rejected(.staleGeneration))
    try await pipeline.setSource(.imu, state: .active, generation: fresh.generation)
    let report = try await pipeline.finish(generation: fresh.generation)
    #expect(report.core.rejectedSourceInactive == 0 && report.ingress.accepted == 1 && report.ingress.stale == 1)
    #expect(held.mailbox.metrics.inFlight == 0 && held.mailbox.metrics.queuedControls == 0)
    #expect(held.mailbox.metrics.admissionReconciles && held.mailbox.metrics.completionReconciles)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
}

@Test func atomicControlWaiterPreservesReservedCapacityAndFIFO() async throws {
    let box = BoundedMailbox(generation: 1, capacity: 1)
    let first = try accepted(box.offer(frame(1), generation: 1))
    let registered = Signal(), completion = ControlResult()
    let control = Task {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.registerControl(.imu, state: .idle, generation: 1, completion: completion,
                                token: 100, continuation: continuation)
            registered.signal()
        }
    }
    await registered.wait()
    #expect(box.progressTicket == Ticket(value: 2))
    #expect(box.metrics.queuedData == 1 && box.metrics.queuedControls == 1 && box.metrics.queueHighWater == 2)
    #expect(box.offer(frame(2), generation: 1) == .rejected(.full))
    do {
        try await box.controlAndWait(.camera, state: .stopped, generation: 1, completion: ControlResult())
        Issue.record("A second control waiter was admitted")
    } catch { #expect(error as? PipelineError == .concurrentWaiter) }
    for expected in [first, Ticket(value: 2)] {
        let work = try #require(await box.next())
        #expect(work.ticket == expected)
        if work.ticket.value == 2 {
            guard case .control(.imu, .idle) = work.message else { Issue.record("Control changed or overtook data"); return }
            work.controlResult?.complete(.ok)
        }
        box.complete(work.ticket)
    }
    try await control.value
    #expect(completion.status == .ok && box.progressTicket == nil)
    do {
        try await box.controlAndWait(.camera, state: .idle, generation: 2, completion: ControlResult())
        Issue.record("Stale control generation was admitted")
    } catch { #expect(error as? PipelineError == .staleGeneration) }
    let third = try accepted(box.offer(frame(3), generation: 1))
    #expect(third.value == 3)
    let work = try #require(await box.next()); box.complete(work.ticket)
    box.closeForFinish()
    do {
        try await box.controlAndWait(.camera, state: .idle, generation: 1, completion: ControlResult())
        Issue.record("Closed control admission succeeded")
    } catch { #expect(error as? PipelineError == .closed) }
    #expect(box.metrics.attempts == 7 && box.metrics.accepted == 3 && box.metrics.processed == 3)
    #expect(box.metrics.busy == 1 && box.metrics.full == 1 && box.metrics.stale == 1 && box.metrics.closed == 1)
    #expect(box.progressTicket == nil && box.metrics.admissionReconciles && box.metrics.completionReconciles)
}

@Test func controlCancellationRegistrationAndCompletionRacesDoNotLeakWaiters() async throws {
    for _ in 0..<40 {
        let box = BoundedMailbox(generation: 1, capacity: 1)
        let control = Task {
            try await box.controlAndWait(.imu, state: .idle, generation: 1, completion: ControlResult())
        }
        control.cancel()
        do { try await control.value; Issue.record("A cancelled waiter completed without a consumer") }
        catch { #expect(error as? PipelineError == .cancelled) }
        #expect(box.progressTicket == nil && box.metrics.accepted <= 1)
        if box.metrics.accepted == 1 {
            let work = try #require(await box.next())
            box.complete(work.ticket)
        }
        box.cancel()
        #expect(box.metrics.admissionReconciles && box.metrics.completionReconciles)
    }
    for _ in 0..<40 {
        let box = BoundedMailbox(generation: 1, capacity: 1)
        let registered = Signal()
        let control = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                box.registerControl(.imu, state: .idle, generation: 1, completion: ControlResult(),
                                    token: 1, continuation: continuation)
                registered.signal()
            }
        }
        await registered.wait()
        let work = try #require(await box.next())
        let cancellation = Task { box.cancelProgress(token: 1) }
        box.complete(work.ticket)
        await cancellation.value
        do { try await control.value }
        catch { #expect(error as? PipelineError == .cancelled) }
        try await box.wait(work.ticket)
        #expect(box.progressTicket == nil && box.metrics.completionReconciles)
        box.cancel()
    }
}

@Test func boundedFIFOAndReservedControlSlot() async throws {
    let box = BoundedMailbox(generation: 7, capacity: 2)
    let a = try accepted(box.offer(frame(1), generation: 7))
    let b = try accepted(box.offer(frame(2), generation: 7))
    #expect(box.offer(frame(3), generation: 7) == .rejected(.full))
    let c = try accepted(box.offerControl(.imu, state: .idle, generation: 7))
    #expect(box.offerControl(.camera, state: .idle, generation: 7) == .rejected(.controlBusy))
    #expect(box.metrics.queuedData == 2 && box.metrics.queuedControls == 1)
    #expect(box.metrics.queueHighWater == 3)
    for ticket in [a, b, c] {
        let work = try #require(await box.next())
        #expect(work.ticket == ticket)
        if ticket == c {
            guard case .control(.imu, .idle) = work.message else { Issue.record("Control overtaken or changed"); return }
        }
        box.complete(ticket)
    }
    box.closeForFinish()
    #expect(await box.next() == nil)
    #expect(box.metrics.processed == 3)
    #expect(box.metrics.admissionReconciles && box.metrics.completionReconciles)
}

@Test func mailboxRejectionsAndCancellationAccounting() async throws {
    let box = BoundedMailbox(generation: 2, capacity: 2)
    #expect(box.offer(frame(1), generation: 1) == .rejected(.staleGeneration))
    #expect(box.offer(.imu(IMUSample(sequence: 1, deviceNS: 0, x: .nan, y: 0, z: 0)), generation: 2) == .rejected(.invalid))
    let first = try accepted(box.offer(frame(1), generation: 2))
    _ = try accepted(box.offer(frame(2), generation: 2))
    _ = try accepted(box.offerControl(.camera, state: .stopped, generation: 2))
    #expect((await box.next())?.ticket == first)
    box.cancel()
    box.complete(first, cancelled: true)
    #expect(box.offer(frame(3), generation: 2) == .rejected(.closed))
    #expect(await box.next() == nil)
    let metrics = box.metrics
    #expect(metrics.accepted == 3 && metrics.cancelledBuffered == 2 && metrics.cancelledInFlight == 1)
    #expect(metrics.queuedData == 0 && metrics.queuedControls == 0 && metrics.inFlight == 0)
    #expect(metrics.admissionReconciles && metrics.completionReconciles)
    do { try await box.wait(first); Issue.record("Cancelled in-flight value was reported processed") }
    catch { #expect(error as? PipelineError == .cancelled) }
}

@Test func progressSingleWaiterAndCancellationLinearization() async throws {
    let box = BoundedMailbox(generation: 1, capacity: 1)
    let ticket = try accepted(box.offer(frame(1), generation: 1))
    let registered = Signal()
    let first = Task {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            box.registerProgress(ticket, token: 100, continuation: continuation)
            registered.signal()
        }
    }
    await registered.wait()
    do { try await box.wait(ticket); Issue.record("Concurrent waiter unexpectedly accepted") }
    catch { #expect(error as? PipelineError == .concurrentWaiter) }
    box.cancelProgress(token: 100)
    do { try await first.value; Issue.record("Cancelled waiter unexpectedly succeeded") }
    catch { #expect(error as? PipelineError == .cancelled) }
    let work = try #require(await box.next())
    box.complete(work.ticket)
    try await box.wait(ticket)

    // Cancellation that linearizes before registration must not leave a waiter behind.
    let earlyBox = BoundedMailbox(generation: 2, capacity: 1)
    let earlyTicket = try accepted(earlyBox.offer(frame(1), generation: 2))
    let cancellation = ProgressCancellation(); cancellation.cancel()
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            earlyBox.registerProgress(earlyTicket, token: 1, continuation: continuation, cancellation: cancellation)
        }
        Issue.record("Pre-registration cancellation unexpectedly succeeded")
    } catch { #expect(error as? PipelineError == .cancelled) }
    earlyBox.cancel()
}

@Test func cancellationAndCompletionRacesDoNotLeakWaiters() async throws {
    for index in 1...40 {
        let box = BoundedMailbox(generation: UInt64(index), capacity: 1)
        let ticket = try accepted(box.offer(frame(1), generation: UInt64(index)))
        let work = try #require(await box.next())
        let waiter = Task { try await box.wait(ticket) }
        waiter.cancel()
        box.complete(work.ticket)
        do { try await waiter.value }
        catch { #expect(error as? PipelineError == .cancelled) }
        try await box.wait(ticket)
        #expect(box.metrics.completionReconciles)
    }
    let box = BoundedMailbox(generation: 1, capacity: 1)
    let waitingConsumer = Task { await box.next() }
    waitingConsumer.cancel()
    #expect(await waitingConsumer.value == nil)
    box.cancel()
}

@Test func outputChannelDropsNewAndCountsTermination() async {
    let channel = OutputChannel(capacity: 2)
    var values: [AlignedFrame] = []
    for sequence in 1...3 {
        var native = RIPOutput(); native.frame_sequence = UInt64(sequence); native.quality = 0
        values.append(AlignedFrame(native))
    }
    channel.publish(values)
    channel.finish()
    var received: [UInt64] = []
    for await value in channel.stream { received.append(value.frameSequence) }
    #expect(received == [1, 2])
    #expect(channel.metrics.produced == 3 && channel.metrics.enqueued == 2 && channel.metrics.dropped == 1)
    channel.publish([values[0]])
    #expect(channel.metrics.terminated == 1 && channel.metrics.reconciles)
}

@Test func deterministicEndToEndAndHostStatistics() async throws {
    let pipeline = Pipeline()
    let session = try await pipeline.start(config: smallConfig())
    try await pump([
        .anchor(ClockAnchor(sequence: 1, deviceNS: 0, referenceNS: 100)),
        .anchor(ClockAnchor(sequence: 2, deviceNS: 10, referenceNS: 110)),
        .anchor(ClockAnchor(sequence: 3, deviceNS: 20, referenceNS: 120)),
        .imu(IMUSample(sequence: 1, deviceNS: 0, x: 0, y: 0, z: 0)),
        .imu(IMUSample(sequence: 2, deviceNS: 20, x: 20, y: 40, z: 60)),
        .frame(CameraFrame(sequence: 1, referenceNS: 110)),
    ], pipeline: pipeline, generation: session.generation)
    try await pipeline.setSource(.camera, state: .idle, generation: session.generation)
    let report = try await pipeline.finish(generation: session.generation)
    var frames: [AlignedFrame] = []
    for await frame in session.outputs { frames.append(frame) }
    #expect(frames.count == 1)
    let aligned = try #require(frames.first)
    #expect(aligned.quality == .interpolated && aligned.available)
    #expect(aligned.x == 10 && aligned.y == 20 && aligned.z == 30)
    #expect(aligned.leftSequence == 1 && aligned.rightSequence == 2)
    #expect(report.clock.state == 1 && report.clock.slope == 1)
    #expect(report.core.outputs == 1 && report.core.framesAccepted == 1)
    #expect(report.ingress.accepted == 7 && report.ingress.processed == 7)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
    #expect(report.output.reconciles && report.output.dropped == 0)
    #expect(report.serviceTime.count == 8 && report.queueWait.count == 7)
    for stats in [report.serviceTime, report.queueWait] {
        #expect(stats.meanNS.isFinite && stats.sampleVarianceNS2.isFinite)
        #expect(stats.minNS >= 0 && stats.maxNS >= stats.minNS && stats.sampleVarianceNS2 >= 0)
    }
    #expect(report.finalStatus == .ok && !report.cancelled)
    #expect(try await pipeline.finish(generation: session.generation) == report)
}

@Test func pipelineJoinRestartAndStaleCallbacks() async throws {
    let pipeline = Pipeline()
    let first = try await pipeline.start(config: smallConfig())
    do { _ = try await pipeline.start(config: smallConfig()); Issue.record("Started overlapping generation") }
    catch { #expect(error as? PipelineError == .alreadyRunning) }
    let second = try await pipeline.restart(config: smallConfig())
    #expect(second.generation == first.generation + 1)
    #expect(pipeline.port.offer(frame(1), generation: first.generation) == .rejected(.staleGeneration))
    var oldCount = 0
    for await _ in first.outputs { oldCount += 1 }
    #expect(oldCount == 0)
    let ticket = try accepted(pipeline.port.offer(frame(1), generation: second.generation))
    try await pipeline.wait(ticket, generation: second.generation)
    let report = try await pipeline.cancel(generation: second.generation)
    #expect(report.cancelled && report.ingress.stale == 1)
    #expect(report.ingress.inFlight == 0 && report.ingress.queuedData == 0 && report.ingress.queuedControls == 0)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
    do { _ = try await pipeline.finish(generation: first.generation); Issue.record("Old lifecycle generation accepted") }
    catch { #expect(error as? PipelineError == .staleGeneration) }
    let third = try await pipeline.start(config: smallConfig())
    #expect(third.generation > second.generation)
    _ = try await pipeline.finish(generation: third.generation)
}

@Test func droppingCoordinatorCancelsConsumerWithoutRetainCycle() async throws {
    var pipeline: Pipeline? = Pipeline()
    let reference = WeakPipelineReference(pipeline)
    let session = try await pipeline!.start(config: smallConfig())
    pipeline = nil
    #expect(reference.value == nil)
    var count = 0
    for await _ in session.outputs { count += 1 }
    #expect(count == 0)
}

@Test func oldLifecycleCompletionsCannotOverwriteRestartedGeneration() async throws {
    for _ in 0..<24 {
        let pipeline = Pipeline()
        let first = try await pipeline.start(config: smallConfig())
        let finishing = Task { try await pipeline.finish(generation: first.generation) }
        let restarting = Task { try await pipeline.restart(config: smallConfig()) }
        let second = try await restarting.value
        do { #expect(try await finishing.value.generation == first.generation) }
        catch { #expect(error as? PipelineError == .staleGeneration) }
        let report = try await pipeline.finish(generation: second.generation)
        #expect(report.generation == second.generation && second.generation > first.generation)
        #expect(report.ingress.completionReconciles)
    }
}

@Test func sourceControlReportsNativeRefusalAfterFIFOCompletion() async throws {
    let pipeline = Pipeline()
    let session = try await pipeline.start(config: smallConfig())
    try await pipeline.setSource(.imu, state: .stopped, generation: session.generation)
    do {
        try await pipeline.setSource(.imu, state: .active, generation: session.generation)
        Issue.record("A terminal source was restarted without a new session")
    } catch { #expect(error as? PipelineError == .native(.sourceInactive)) }
    let report = try await pipeline.finish(generation: session.generation)
    #expect(report.ingress.accepted == 2 && report.ingress.processed == 2)
    #expect(report.core.rejectedSourceInactive == 1)
}

@Test func gracefulFinishAfterBothSourcesStoppedIsSuccessful() async throws {
    let pipeline = Pipeline()
    let session = try await pipeline.start(config: smallConfig())
    try await pipeline.setSource(.imu, state: .stopped, generation: session.generation)
    try await pipeline.setSource(.camera, state: .stopped, generation: session.generation)
    let report = try await pipeline.finish(generation: session.generation)
    #expect(report.finalStatus == .ok && !report.cancelled)
    #expect(report.core.terminal && !report.core.faulted)
    #expect(report.ingress.accepted == 2 && report.ingress.processed == 2)
    #expect(report.ingress.admissionReconciles && report.ingress.completionReconciles)
    #expect(report.output.reconciles)
    #expect(try await pipeline.finish(generation: session.generation) == report)
}

@Test func clockDiscontinuityClosesAdmissionAndRestartRequiresFreshAnchors() async throws {
    let pipeline = Pipeline()
    let old = try await pipeline.start(config: smallConfig())
    try await pump([
        .anchor(ClockAnchor(sequence: 1, deviceNS: 0, referenceNS: 100)),
        .anchor(ClockAnchor(sequence: 2, deviceNS: 10, referenceNS: 110)),
        .anchor(ClockAnchor(sequence: 3, deviceNS: 20, referenceNS: 120)),
        .imu(IMUSample(sequence: 1, deviceNS: 0, x: 0, y: 0, z: 0)),
        .frame(CameraFrame(sequence: 1, referenceNS: 110)),
    ], pipeline: pipeline, generation: old.generation)
    let reset = try accepted(pipeline.port.offer(
        .anchor(ClockAnchor(sequence: 4, deviceNS: 5, referenceNS: 105)), generation: old.generation))
    var acceptedAfterReset: UInt64 = 0
    for sequence in 2...65 {
        let staleEpoch = InputEvent.imu(IMUSample(sequence: UInt64(sequence), deviceNS: 10,
                                                  x: 1, y: 2, z: 3))
        switch pipeline.port.offer(staleEpoch, generation: old.generation) {
        case .accepted: acceptedAfterReset += 1
        case .rejected(let reason): #expect(reason == .full || reason == .closed)
        }
    }
    // Registration may race the terminal operation's completed barrier. Either
    // result is valid; admission must already be closed when it resumes.
    do { try await pipeline.wait(reset, generation: old.generation) }
    catch { #expect(error as? PipelineError == .cancelled) }
    #expect(pipeline.port.offer(frame(99), generation: old.generation) == .rejected(.closed))
    let failed = try await pipeline.finish(generation: old.generation)
    #expect(failed.finalStatus == .discontinuity && failed.cancelled)
    #expect(failed.ingress.processed == 6 && failed.ingress.cancelledBuffered == acceptedAfterReset)
    #expect(failed.ingress.cancelledInFlight == 0)
    #expect(failed.ingress.admissionReconciles && failed.ingress.completionReconciles)
    #expect(failed.core.clockDiscontinuities == 1 && failed.core.framesDiscardedReset == 1)
    #expect(failed.core.imuReceived == 1 && failed.core.framesReceived == 1)
    #expect(failed.core.outputs == 0 && failed.core.terminal)
    var oldOutputs = 0
    for await _ in old.outputs { oldOutputs += 1 }
    #expect(oldOutputs == 0)

    let fresh = try await pipeline.restart(config: smallConfig())
    #expect(fresh.generation > old.generation)
    #expect(pipeline.port.offer(frame(100), generation: old.generation) == .rejected(.staleGeneration))
    try await pump([
        .imu(IMUSample(sequence: 100, deviceNS: 5, x: 5, y: 5, z: 5)),
        .frame(CameraFrame(sequence: 1, referenceNS: 105)),
        .anchor(ClockAnchor(sequence: 1, deviceNS: 0, referenceNS: 100)),
        .anchor(ClockAnchor(sequence: 2, deviceNS: 10, referenceNS: 110)),
        .anchor(ClockAnchor(sequence: 3, deviceNS: 20, referenceNS: 120)),
        .imu(IMUSample(sequence: 1, deviceNS: 0, x: 0, y: 0, z: 0)),
        .imu(IMUSample(sequence: 2, deviceNS: 20, x: 20, y: 40, z: 60)),
        .frame(CameraFrame(sequence: 2, referenceNS: 110)),
    ], pipeline: pipeline, generation: fresh.generation)
    let recovered = try await pipeline.finish(generation: fresh.generation)
    var outputs: [AlignedFrame] = []
    for await output in fresh.outputs { outputs.append(output) }
    #expect(recovered.finalStatus == .ok && !recovered.cancelled)
    #expect(recovered.core.rejectedUncalibrated == 1 && recovered.clock.epoch == 1)
    #expect(recovered.ingress.stale == 1 && recovered.ingress.completionReconciles)
    #expect(outputs.map(\.quality) == [.clockUnavailable, .interpolated])
    #expect(outputs.last?.x == 10)
}

@Test func nativeBoundaryCopiesInputsAndOwnsHandle() throws {
    var config = smallConfig().core.native
    var status = RIP_INTERNAL_ERROR
    let handle = try #require(rip_core_create(config, &status))
    defer { rip_core_destroy(handle) }
    #expect(status == RIP_OK)
    config.min_anchors = 64 // Mutating caller storage cannot affect the copied config.
    for index in 0...2 {
        var anchor = RIPAnchor(sequence: UInt64(index + 1), device_ns: Int64(index * 10), reference_ns: Int64(100 + index * 10))
        let result = rip_core_add_anchor(handle, anchor)
        #expect(result == RIP_UNCALIBRATED || result == RIP_OK)
        anchor.device_ns = -1 // No reference to this local remains in the core.
    }
    var mapped: Int64 = 0
    #expect(rip_core_map_time(handle, 5, &mapped) == RIP_OK && mapped == 105)
    #expect(rip_core_cancel(handle) == RIP_OK)
    rip_core_destroy(nil)
    var invalid = config; invalid.reorder_capacity = 0
    #expect(rip_core_create(invalid, &status) == nil && status == RIP_INVALID_ARGUMENT)
}

@Test func welfordUsesSampleVarianceAndFiniteEmptyValues() {
    var stats = ServiceAccumulator()
    #expect(stats.snapshot.count == 0 && stats.snapshot.meanNS == 0 && stats.snapshot.sampleVarianceNS2 == 0)
    for value in [1.0, 2.0, 3.0] { stats.add(value) }
    stats.add(.nan); stats.add(-1)
    #expect(stats.snapshot.count == 3 && stats.snapshot.meanNS == 2 && stats.snapshot.sampleVarianceNS2 == 1)
    #expect(stats.snapshot.minNS == 1 && stats.snapshot.maxNS == 3)
}
