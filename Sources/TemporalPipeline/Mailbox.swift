import Synchronization

enum Message: Sendable { case event(InputEvent), control(Source, SourceState) }
struct Work: Sendable {
    let ticket: Ticket
    let message: Message
    let admittedAt: ContinuousClock.Instant
    let controlResult: ControlResult?
    var queueWaitNS: Double = 0
}
final class ControlResult: Sendable {
    private let result = Mutex<NativeStatus?>(nil)
    func complete(_ status: NativeStatus) { result.withLock { $0 = status } }
    var status: NativeStatus? { result.withLock { $0 } }
}
func nanoseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000_000_000 + Double(components.attoseconds) / 1_000_000_000
}
final class ProgressCancellation: Sendable {
    private let value = Mutex(false)
    func cancel() { value.withLock { $0 = true } }
    var isCancelled: Bool { value.withLock { $0 } }
}

/// One synchronous bounded FIFO: B data entries and one reserved control entry.
/// Continuations are removed while locked and always resumed after unlocking.
final class BoundedMailbox: Sendable {
    enum Mode { case open, draining, cancelled }
    struct Waiter {
        let token: UInt64
        let ticket: Ticket
        let continuation: CheckedContinuation<Void, any Error>
    }
    struct State {
        var ring: [Work?]
        var head = 0
        var count = 0
        var mode = Mode.open
        var consumerCancelled = false
        var consumer: CheckedContinuation<Work?, Never>?
        var progress: Waiter?
        var lastTicket: UInt64 = 0
        var completedThrough: UInt64 = 0
        var current: Ticket?
        var metrics = IngressMetrics()
    }
    let generation: UInt64
    let capacity: Int
    private let state: Mutex<State>
    private let tokens = Mutex<UInt64>(0)
    init(generation: UInt64, capacity: Int) {
        self.generation = generation; self.capacity = capacity
        state = Mutex(State(ring: Array(repeating: nil, count: capacity + 1)))
    }
    private func pop(_ state: inout State) -> Work? {
        guard state.count > 0 else { return nil }
        var work = state.ring[state.head]!
        state.ring[state.head] = nil
        state.head = (state.head + 1) % state.ring.count
        state.count -= 1
        switch work.message {
        case .event: state.metrics.queuedData -= 1
        case .control: state.metrics.queuedControls -= 1
        }
        work.queueWaitNS = max(0, nanoseconds(work.admittedAt.duration(to: .now)))
        state.current = work.ticket
        state.metrics.inFlight = 1
        return work
    }
    func offer(_ event: InputEvent, generation: UInt64) -> OfferReceipt {
        admit(.event(event), generation: generation)
    }
    func offerControl(_ source: Source, state sourceState: SourceState, generation: UInt64,
                      completion: ControlResult? = nil) -> OfferReceipt {
        admit(.control(source, sourceState), generation: generation, completion: completion)
    }
    private func admit(_ message: Message, generation: UInt64, completion: ControlResult? = nil) -> OfferReceipt {
        let result = state.withLock { state in
            admit(message, generation: generation, completion: completion, to: &state)
        }
        if let continuation = result.1 { continuation.resume(returning: result.2) }
        return result.0
    }
    private func admit(_ message: Message, generation: UInt64, completion: ControlResult?, to state: inout State)
        -> (OfferReceipt, CheckedContinuation<Work?, Never>?, Work?) {
        state.metrics.attempts += 1
        guard generation == self.generation else {
            state.metrics.stale += 1; return (.rejected(.staleGeneration), nil, nil)
        }
        guard state.mode == .open else {
            state.metrics.closed += 1; return (.rejected(.closed), nil, nil)
        }
        switch message {
        case .event(let event):
            guard event.isValid else { state.metrics.invalid += 1; return (.rejected(.invalid), nil, nil) }
            guard state.metrics.queuedData < capacity else { state.metrics.full += 1; return (.rejected(.full), nil, nil) }
        case .control:
            guard state.metrics.queuedControls == 0 else { state.metrics.busy += 1; return (.rejected(.controlBusy), nil, nil) }
        }
        guard state.lastTicket < UInt64.max else { state.metrics.invalid += 1; return (.rejected(.invalid), nil, nil) }
        state.lastTicket += 1
        let ticket = Ticket(value: state.lastTicket)
        let work = Work(ticket: ticket, message: message, admittedAt: .now, controlResult: completion)
        state.ring[(state.head + state.count) % state.ring.count] = work
        state.count += 1
        switch message {
        case .event: state.metrics.queuedData += 1
        case .control: state.metrics.queuedControls += 1
        }
        state.metrics.accepted += 1
        state.metrics.queueHighWater = max(state.metrics.queueHighWater, state.count)
        let continuation = state.consumer
        state.consumer = nil
        return (.accepted(ticket), continuation, continuation == nil ? nil : pop(&state))
    }
    func controlAndWait(_ source: Source, state sourceState: SourceState, generation: UInt64,
                        completion: ControlResult) async throws {
        let token = try progressToken()
        let cancellation = ProgressCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerControl(source, state: sourceState, generation: generation, completion: completion,
                                token: token, continuation: continuation,
                                alreadyCancelled: Task.isCancelled, cancellation: cancellation)
            }
        } onCancel: {
            cancellation.cancel()
            self.cancelProgress(token: token)
        }
    }
    // Admission and waiter ownership share one lock. No worker can complete the
    // control before its continuation is stored, and conflicts consume no ticket.
    func registerControl(_ source: Source, state sourceState: SourceState, generation: UInt64,
                         completion: ControlResult, token: UInt64,
                         continuation: CheckedContinuation<Void, any Error>, alreadyCancelled: Bool = false,
                         cancellation: ProgressCancellation? = nil) {
        let result = state.withLock { state -> (PipelineError?, CheckedContinuation<Work?, Never>?, Work?) in
            // This check is the admission/cancellation linearization point. Later
            // cancellation removes only the waiter, leaving admitted FIFO work.
            if alreadyCancelled || cancellation?.isCancelled == true { return (.cancelled, nil, nil) }
            if generation == self.generation, state.mode == .open, state.progress != nil {
                state.metrics.attempts += 1; state.metrics.busy += 1
                return (.concurrentWaiter, nil, nil)
            }
            let admission = admit(.control(source, sourceState), generation: generation, completion: completion, to: &state)
            switch admission.0 {
            case .accepted(let ticket):
                state.progress = Waiter(token: token, ticket: ticket, continuation: continuation)
                return (nil, admission.1, admission.2)
            case .rejected(.controlBusy): return (.controlBusy, nil, nil)
            case .rejected(.staleGeneration): return (.staleGeneration, nil, nil)
            case .rejected: return (.closed, nil, nil)
            }
        }
        if let consumer = result.1 { consumer.resume(returning: result.2) }
        if let error = result.0 { continuation.resume(throwing: error) }
    }
    func next() async -> Work? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = state.withLock { state -> (Bool, Work?) in
                    if state.consumerCancelled || state.mode == .cancelled { return (true, nil) }
                    if let work = pop(&state) { return (true, work) }
                    if state.mode == .draining { return (true, nil) }
                    precondition(state.consumer == nil, "Only one consumer is permitted")
                    state.consumer = continuation
                    return (false, nil)
                }
                if result.0 { continuation.resume(returning: result.1) }
            }
        } onCancel: {
            self.wakeConsumerForCancellation()
        }
    }
    private func wakeConsumerForCancellation() {
        let continuation = state.withLock { state in
            state.consumerCancelled = true
            let continuation = state.consumer; state.consumer = nil
            return continuation
        }
        continuation?.resume(returning: nil)
    }
    func closeForFinish() {
        let continuation = state.withLock { state in
            if state.mode == .open { state.mode = .draining }
            let continuation = state.count == 0 ? state.consumer : nil
            if continuation != nil { state.consumer = nil }
            return continuation
        }
        continuation?.resume(returning: nil)
    }
    func cancel() {
        let result = state.withLock { state -> (CheckedContinuation<Work?, Never>?, CheckedContinuation<Void, any Error>?) in
            state.mode = .cancelled
            state.metrics.cancelledBuffered += UInt64(state.count)
            state.ring = Array(repeating: nil, count: capacity + 1)
            state.head = 0; state.count = 0
            state.metrics.queuedData = 0; state.metrics.queuedControls = 0
            let consumer = state.consumer; state.consumer = nil
            let progress = state.progress?.continuation; state.progress = nil
            return (consumer, progress)
        }
        result.0?.resume(returning: nil)
        result.1?.resume(throwing: PipelineError.cancelled)
    }
    func complete(_ ticket: Ticket, cancelled: Bool = false) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            precondition(state.current == ticket)
            state.current = nil; state.metrics.inFlight = 0
            if cancelled { state.metrics.cancelledInFlight += 1 } else { state.metrics.processed += 1 }
            if !cancelled { state.completedThrough = ticket.value }
            if let progress = state.progress, progress.ticket.value <= ticket.value {
                state.progress = nil; return progress.continuation
            }
            return nil
        }
        if cancelled { continuation?.resume(throwing: PipelineError.cancelled) }
        else { continuation?.resume() }
    }
    private func progressToken() throws -> UInt64 {
        let token = tokens.withLock { value -> UInt64? in
            guard value < UInt64.max else { return nil }
            value += 1
            return value
        }
        guard let token else { throw PipelineError.invalidTicket }
        return token
    }
    func wait(_ ticket: Ticket) async throws {
        let token = try progressToken()
        let cancellation = ProgressCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerProgress(ticket, token: token, continuation: continuation,
                                 alreadyCancelled: Task.isCancelled, cancellation: cancellation)
            }
        } onCancel: {
            cancellation.cancel()
            self.cancelProgress(token: token)
        }
    }
    // Separate registration makes the continuation linearization point directly testable.
    func registerProgress(_ ticket: Ticket, token: UInt64,
                          continuation: CheckedContinuation<Void, any Error>, alreadyCancelled: Bool = false,
                          cancellation: ProgressCancellation? = nil) {
        let result = state.withLock { state -> Result<Void, PipelineError>? in
            if alreadyCancelled || cancellation?.isCancelled == true { return .failure(.cancelled) }
            guard ticket.value > 0, ticket.value <= state.lastTicket else { return .failure(.invalidTicket) }
            if state.completedThrough >= ticket.value { return .success(()) }
            if state.mode == .cancelled { return .failure(.cancelled) }
            if state.progress != nil { return .failure(.concurrentWaiter) }
            state.progress = Waiter(token: token, ticket: ticket, continuation: continuation)
            return nil
        }
        if let result { continuation.resume(with: result.mapError { $0 as any Error }) }
    }
    func cancelProgress(token: UInt64) {
        let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            guard state.progress?.token == token else { return nil }
            let continuation = state.progress?.continuation; state.progress = nil
            return continuation
        }
        continuation?.resume(throwing: PipelineError.cancelled)
    }
    var metrics: IngressMetrics { state.withLock { $0.metrics } }
    var progressTicket: Ticket? { state.withLock { $0.progress?.ticket } }
    var isOpen: Bool { state.withLock { $0.mode == .open } }
    var isCancelled: Bool { state.withLock { $0.mode == .cancelled } }
}

/// Capture callbacks share this port across session generations. Admission is synchronous.
public final class InputPort: Sendable {
    private let mailbox = Mutex<BoundedMailbox?>(nil)
    public func offer(_ event: InputEvent, generation: UInt64) -> OfferReceipt {
        guard let current = mailbox.withLock({ $0 }) else { return .rejected(.closed) }
        return current.offer(event, generation: generation)
    }
    func install(_ current: BoundedMailbox) { mailbox.withLock { $0 = current } }
}
