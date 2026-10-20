import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import TemporalPipeline

public enum CameraAdapterError: Error, Sendable, Equatable {
    case cameraNotAuthorized
    case invalidGeneration
}

public enum CameraMetadataRejection: String, Sendable, Codable {
    case invalidPresentationTime, unsupportedEpoch, conversionFailed
    case negativeTimestamp, timestampOverflow, sequenceExhausted, invalidated
}

/// An admission receipt describes the bounded Swift ingress, not native alignment.
public enum CameraMetadataReceipt: Sendable, Equatable {
    case offered(OfferReceipt)
    case rejected(CameraMetadataRejection)
}

public struct CameraAdapterMetrics: Sendable, Codable, Equatable {
    public internal(set) var receivedFrames: UInt64 = 0
    public internal(set) var captureDroppedFrames: UInt64 = 0
    public internal(set) var acceptedFrames: UInt64 = 0
    public internal(set) var invalidPresentationTime: UInt64 = 0
    public internal(set) var unsupportedEpoch: UInt64 = 0
    public internal(set) var conversionFailed: UInt64 = 0
    public internal(set) var negativeTimestamp: UInt64 = 0
    public internal(set) var timestampOverflow: UInt64 = 0
    public internal(set) var sequenceExhausted: UInt64 = 0
    public internal(set) var invalidatedFrames: UInt64 = 0
    public internal(set) var ingressFull: UInt64 = 0
    public internal(set) var ingressStaleGeneration: UInt64 = 0
    public internal(set) var ingressClosed: UInt64 = 0
    public internal(set) var ingressOtherRejected: UInt64 = 0
    public internal(set) var nanosecondsRounded: UInt64 = 0
    public internal(set) var inFlightOffers: UInt64 = 0
    public internal(set) var counterSaturated = false

    /// Capture-framework drops are separate from delivered-frame admission.
    public var reconciles: Bool {
        guard !counterSaturated else { return false }
        let decisions = [acceptedFrames, invalidPresentationTime, unsupportedEpoch,
                         conversionFailed, negativeTimestamp, timestampOverflow,
                         sequenceExhausted, invalidatedFrames, ingressFull,
                         ingressStaleGeneration, ingressClosed, ingressOtherRejected,
                         inFlightOffers]
        var total: UInt64 = 0
        for value in decisions {
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return false }
            total = sum.partialValue
        }
        return receivedFrames == total
    }

    mutating func increment(_ field: WritableKeyPath<Self, UInt64>) {
        if self[keyPath: field] == .max { counterSaturated = true }
        else { self[keyPath: field] += 1 }
    }
}

struct HostNanoseconds: Equatable {
    let value: Int64
    let rounded: Bool
}

/// Copies camera timing metadata synchronously into an existing bounded input port.
/// The host retains session ownership and installs this delegate on a serial queue.
public final class CameraMetadataAdapter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    public let generation: UInt64
    private let sessionClock: CMClock
    private let inputPort: InputPort
    private struct State {
        var nextSequence: UInt64
        var exhausted = false
        var active = true
        var metrics = CameraAdapterMetrics()
    }
    private let state: Mutex<State>

    /// `sessionClock` must come from the host's active session.synchronizationClock.
    /// This checks existing authorization; it never requests access or starts capture.
    public convenience init(sessionClock: CMClock, inputPort: InputPort,
                            generation: UInt64) throws {
        try self.init(sessionClock: sessionClock, inputPort: inputPort, generation: generation,
                      authorizationStatus: AVCaptureDevice.authorizationStatus(for: .video))
    }

    // Tests inject a status and host clock, so they never query TCC or camera hardware.
    init(sessionClock: CMClock, inputPort: InputPort, generation: UInt64,
         authorizationStatus: AVAuthorizationStatus, nextSequence: UInt64 = 1) throws {
        guard authorizationStatus == .authorized else { throw CameraAdapterError.cameraNotAuthorized }
        guard generation > 0 else { throw CameraAdapterError.invalidGeneration }
        self.sessionClock = sessionClock // ARC retains this immutable, Sendable clock.
        self.inputPort = inputPort
        self.generation = generation
        state = Mutex(State(nextSequence: nextSequence))
        super.init()
    }

    public var metrics: CameraAdapterMetrics { state.withLock { $0.metrics } }

    /// Prevents new conversion/admission attempts. The host must also detach and
    /// fence its callback queue before finishing/restarting the pipeline.
    public func invalidate() { state.withLock { $0.active = false } }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        _ = submitPresentationTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        recordCaptureDrop()
    }

    func recordCaptureDrop() { state.withLock { $0.metrics.increment(\.captureDroppedFrames) } }

    /// Internal pure-input boundary also used by deterministic no-camera tests.
    @discardableResult
    func submitPresentationTime(_ presentationTime: CMTime) -> CameraMetadataReceipt {
        let prepared: Result<CameraFrame, CameraMetadataRejection> = state.withLock { current in
            current.metrics.increment(\.receivedFrames)
            guard current.active else { return Self.reject(.invalidated, state: &current) }
            guard !current.exhausted else { return Self.reject(.sequenceExhausted, state: &current) }
            guard presentationTime.isNumeric, presentationTime.timescale > 0 else {
                return Self.reject(.invalidPresentationTime, state: &current)
            }
            guard presentationTime.epoch == 0 else { return Self.reject(.unsupportedEpoch, state: &current) }
            guard presentationTime.value >= 0 else { return Self.reject(.negativeTimestamp, state: &current) }
            let hostTime = CMSyncConvertTime(presentationTime, from: sessionClock,
                                             to: CMClockGetHostTimeClock())
            let converted = Self.hostNanoseconds(hostTime)
            switch converted {
            case .failure(let reason): return Self.reject(reason, state: &current)
            case .success(let nanoseconds):
                let frame = CameraFrame(sequence: current.nextSequence, referenceNS: nanoseconds.value)
                if current.nextSequence == .max { current.exhausted = true }
                else { current.nextSequence += 1 }
                if nanoseconds.rounded { current.metrics.increment(\.nanosecondsRounded) }
                current.metrics.increment(\.inFlightOffers)
                return .success(frame)
            }
        }
        switch prepared {
        case .failure(let reason): return .rejected(reason)
        case .success(let frame):
            // offer may wake the pipeline consumer. No adapter mutex is held.
            let receipt = inputPort.offer(.frame(frame), generation: generation)
            state.withLock { current in
                current.metrics.inFlightOffers -= 1
                switch receipt {
                case .accepted: current.metrics.increment(\.acceptedFrames)
                case .rejected(.full): current.metrics.increment(\.ingressFull)
                case .rejected(.staleGeneration): current.metrics.increment(\.ingressStaleGeneration)
                case .rejected(.closed): current.metrics.increment(\.ingressClosed)
                case .rejected(.controlBusy), .rejected(.invalid): current.metrics.increment(\.ingressOtherRejected)
                }
            }
            return .offered(receipt)
        }
    }

    private static func reject(_ reason: CameraMetadataRejection, state: inout State)
        -> Result<CameraFrame, CameraMetadataRejection> {
        switch reason {
        case .invalidPresentationTime: state.metrics.increment(\.invalidPresentationTime)
        case .unsupportedEpoch: state.metrics.increment(\.unsupportedEpoch)
        case .conversionFailed: state.metrics.increment(\.conversionFailed)
        case .negativeTimestamp: state.metrics.increment(\.negativeTimestamp)
        case .timestampOverflow: state.metrics.increment(\.timestampOverflow)
        case .sequenceExhausted: state.metrics.increment(\.sequenceExhausted)
        case .invalidated: state.metrics.increment(\.invalidatedFrames)
        }
        return .failure(reason)
    }

    /// Checked rational scaling avoids floating absolute timestamps and avoids
    /// CMTime scale-conversion overflow or a silently reduced output timescale.
    static func hostNanoseconds(_ time: CMTime) -> Result<HostNanoseconds, CameraMetadataRejection> {
        guard time.isNumeric, time.timescale > 0 else { return .failure(.conversionFailed) }
        guard time.epoch == 0 else { return .failure(.unsupportedEpoch) }
        guard time.value >= 0 else { return .failure(.negativeTimestamp) }
        let scale = Int64(time.timescale)
        let seconds = time.value / scale
        let whole = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .failure(.timestampOverflow) }
        // remainder < Int32.max, so multiplication by 1e9 fits signed Int64.
        let numerator = (time.value % scale) * 1_000_000_000
        var fraction = numerator / scale
        let remainder = numerator % scale
        if remainder * 2 >= scale { fraction += 1 } // positive half-away tie
        let result = whole.partialValue.addingReportingOverflow(fraction)
        guard !result.overflow else { return .failure(.timestampOverflow) }
        return .success(HostNanoseconds(value: result.partialValue, rounded: remainder != 0))
    }
}

extension CameraMetadataRejection: Error {}
