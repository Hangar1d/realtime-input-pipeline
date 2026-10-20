import PipelineCore
import Synchronization

final class OutputChannel: Sendable {
    let stream: AsyncStream<AlignedFrame>
    private let continuation: AsyncStream<AlignedFrame>.Continuation
    private let counters = Mutex(OutputMetrics())
    init(capacity: Int) {
        let pair = AsyncStream<AlignedFrame>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        stream = pair.stream; continuation = pair.continuation
    }
    func publish(_ frames: [AlignedFrame]) {
        for frame in frames {
            let result = continuation.yield(frame)
            counters.withLock { metrics in
                metrics.produced += 1
                switch result {
                case .enqueued: metrics.enqueued += 1
                case .dropped: metrics.dropped += 1
                case .terminated: metrics.terminated += 1
                @unknown default: metrics.terminated += 1
                }
            }
        }
    }
    func finish() { continuation.finish() }
    var metrics: OutputMetrics { counters.withLock { $0 } }
}

/// This non-Sendable owner never leaves EngineWorker's isolation domain.
/// No native pointer, borrowed memory, or native closure is exposed to callers.
private final class NativeOwner {
    private let handle: OpaquePointer
    init(config: CoreConfiguration) throws {
        var status = RIP_OK
        guard let handle = rip_core_create(config.native, &status) else {
            throw PipelineError.native(NativeStatus(status))
        }
        self.handle = handle
    }
    deinit { rip_core_destroy(handle) }
    func process(_ message: Message) -> NativeStatus {
        switch message {
        case .event(.anchor(let value)):
            NativeStatus(rip_core_add_anchor(handle, RIPAnchor(sequence: value.sequence, device_ns: value.deviceNS, reference_ns: value.referenceNS)))
        case .event(.imu(let value)):
            NativeStatus(rip_core_push_imu(handle, RIPIMUSample(sequence: value.sequence, device_ns: value.deviceNS, x: value.x, y: value.y, z: value.z)))
        case .event(.frame(let value)):
            NativeStatus(rip_core_push_frame(handle, RIPFrame(sequence: value.sequence, reference_ns: value.referenceNS)))
        case .control(let source, let state):
            NativeStatus(rip_core_set_source(handle, source.rawValue, state.rawValue))
        }
    }
    func drain() -> [AlignedFrame] {
        var result: [AlignedFrame] = []
        var output = RIPOutput()
        while rip_core_pop_output(handle, &output) == RIP_OK { result.append(AlignedFrame(output)) }
        return result
    }
    func close(cancelled: Bool) -> NativeStatus {
        let status = NativeStatus(cancelled ? rip_core_cancel(handle) : rip_core_finish(handle))
        // Explicitly stopping both sources may already have completed the native stream.
        // Normalize only a verified healthy terminal stream during graceful close.
        if !cancelled, status == .finished {
            var metrics = RIPMetrics()
            if rip_core_metrics(handle, &metrics) == RIP_OK, metrics.terminal != 0, metrics.faulted == 0 {
                return .ok
            }
        }
        return status
    }
    func snapshot() -> (CoreMetrics, ClockInfo) {
        var metrics = RIPMetrics(); var clock = RIPClockInfo()
        _ = rip_core_metrics(handle, &metrics); _ = rip_core_clock_info(handle, &clock)
        return (CoreMetrics(metrics), ClockInfo(clock))
    }
}
struct WorkerReport: Sendable {
    let core: CoreMetrics
    let clock: ClockInfo
    let serviceTime: ServiceTimeStatistics
    let queueWait: ServiceTimeStatistics
    let status: NativeStatus
}
actor EngineWorker {
    private let owner: NativeOwner
    private var service = ServiceAccumulator()
    private var queueWait = ServiceAccumulator()
    init(config: CoreConfiguration) throws { owner = try NativeOwner(config: config) }
    func process(_ work: Work, output: OutputChannel) -> NativeStatus {
        queueWait.add(work.queueWaitNS)
        let start = ContinuousClock.now
        let status = owner.process(work.message)
        let frames = owner.drain()
        service.add(nanoseconds(start.duration(to: .now)))
        output.publish(frames)
        return status
    }
    func close(cancelled: Bool, output: OutputChannel, terminalStatus: NativeStatus? = nil) -> WorkerReport {
        let start = ContinuousClock.now
        let status = owner.close(cancelled: cancelled)
        let frames = owner.drain()
        service.add(nanoseconds(start.duration(to: .now)))
        output.publish(frames)
        let snapshot = owner.snapshot()
        return WorkerReport(core: snapshot.0, clock: snapshot.1, serviceTime: service.snapshot,
                            queueWait: queueWait.snapshot, status: terminalStatus ?? status)
    }
}
