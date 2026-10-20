/// Coordinates session lifetime. The single consumer task captures mailbox,
/// worker, and output values only, so it cannot retain this coordinator.
public actor Pipeline {
    public nonisolated let port = InputPort()
    private enum Phase: Sendable { case running, finishing, cancelling, finished }
    private struct Context: Sendable {
        let generation: UInt64
        let mailbox: BoundedMailbox
        let output: OutputChannel
        let task: Task<WorkerReport, Never>
        var phase: Phase
        var report: PipelineReport?
    }
    private var nextGeneration: UInt64 = 0
    private var context: Context?
    private let beforeConsumerStart: (@Sendable (BoundedMailbox) async -> Void)?
    public init() { beforeConsumerStart = nil }
    // Internal test scheduling hook; public sessions never install one. Tests
    // can hold consumer startup without blocking a cooperative executor thread.
    init(beforeConsumerStart: @escaping @Sendable (BoundedMailbox) async -> Void) {
        self.beforeConsumerStart = beforeConsumerStart
    }
    deinit {
        // Nonisolated deinit only touches Sendable context values.
        context?.mailbox.cancel()
        context?.task.cancel()
    }
    public func start(config: PipelineConfiguration = .init()) throws -> Session {
        if let context, context.phase != .finished { throw PipelineError.alreadyRunning }
        guard config.ingressCapacity > 0, config.ingressCapacity <= 1_000_000,
              config.outputCapacity > 0, config.outputCapacity <= 1_000_000,
              nextGeneration < UInt64.max else { throw PipelineError.invalidConfiguration }
        let worker = try EngineWorker(config: config.core)
        nextGeneration += 1
        let generation = nextGeneration
        let mailbox = BoundedMailbox(generation: generation, capacity: config.ingressCapacity)
        let output = OutputChannel(capacity: config.outputCapacity)
        let beforeConsumerStart = self.beforeConsumerStart
        let task = Task.detached {
            await beforeConsumerStart?(mailbox)
            var terminalStatus: NativeStatus?
            while let work = await mailbox.next() {
                if Task.isCancelled || mailbox.isCancelled {
                    mailbox.complete(work.ticket, cancelled: true)
                    break
                }
                let status = await worker.process(work, output: output)
                work.controlResult?.complete(status)
                if status == .discontinuity || status == .internalError {
                    // Native clock epochs cannot label callbacks already queued by
                    // capture producers. Close this generation before waking its
                    // producer barrier; restart must establish a new clock map.
                    terminalStatus = status
                    mailbox.cancel()
                    mailbox.complete(work.ticket)
                    break
                }
                mailbox.complete(work.ticket)
            }
            let report = await worker.close(cancelled: Task.isCancelled || mailbox.isCancelled,
                                            output: output, terminalStatus: terminalStatus)
            output.finish()
            return report
        }
        context = Context(generation: generation, mailbox: mailbox, output: output, task: task, phase: .running)
        port.install(mailbox)
        return Session(generation: generation, outputs: output.stream)
    }
    public func wait(_ ticket: Ticket, generation: UInt64) async throws {
        let current = try requireContext(generation)
        try await current.mailbox.wait(ticket)
        guard context?.generation == generation else { throw PipelineError.staleGeneration }
    }
    /// Waiter conflicts and cancellation observed before admission enqueue nothing.
    /// After admission, cancelling this call stops its wait without rolling back
    /// the control. Pipeline cancellation can discard queued work, but cannot undo
    /// an in-flight transition.
    public func setSource(_ source: Source, state: SourceState, generation: UInt64) async throws {
        let current = try requireContext(generation)
        let completion = ControlResult()
        try await current.mailbox.controlAndWait(source, state: state, generation: generation, completion: completion)
        guard context?.generation == generation else { throw PipelineError.staleGeneration }
        if let status = completion.status, status != .ok { throw PipelineError.native(status) }
    }
    public func finish(generation: UInt64) async throws -> PipelineReport {
        var current = try requireContext(generation)
        if let report = current.report { return report }
        if current.phase == .running {
            current.phase = .finishing; context = current
            current.mailbox.closeForFinish()
        }
        return try await join(current)
    }
    public func cancel(generation: UInt64) async throws -> PipelineReport {
        var current = try requireContext(generation)
        if let report = current.report { return report }
        current.phase = .cancelling; context = current
        current.mailbox.cancel()
        current.task.cancel()
        return try await join(current)
    }
    public func restart(config: PipelineConfiguration = .init()) async throws -> Session {
        if let current = context, current.phase != .finished {
            _ = try await cancel(generation: current.generation)
            guard context?.generation == current.generation else { throw PipelineError.staleGeneration }
        }
        return try start(config: config)
    }
    private func requireContext(_ generation: UInt64) throws -> Context {
        guard let context else { throw PipelineError.noSession }
        guard context.generation == generation else { throw PipelineError.staleGeneration }
        return context
    }
    private func join(_ joining: Context) async throws -> PipelineReport {
        let native = await joining.task.value
        // Another waiter may have joined and a caller may already have restarted.
        // That old completion must never overwrite the new generation.
        guard var current = context, current.generation == joining.generation else { throw PipelineError.staleGeneration }
        if let report = current.report { return report }
        let report = PipelineReport(generation: current.generation, cancelled: current.mailbox.isCancelled,
                                    ingress: current.mailbox.metrics, output: current.output.metrics,
                                    core: native.core, clock: native.clock, serviceTime: native.serviceTime,
                                    queueWait: native.queueWait, finalStatus: native.status)
        current.phase = .finished; current.report = report; context = current
        return report
    }
}
