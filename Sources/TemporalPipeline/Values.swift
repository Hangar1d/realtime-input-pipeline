import PipelineCore

public struct ClockAnchor: Sendable, Codable, Equatable {
    public var sequence: UInt64
    public var deviceNS: Int64
    public var referenceNS: Int64
    public init(sequence: UInt64, deviceNS: Int64, referenceNS: Int64) {
        self.sequence = sequence; self.deviceNS = deviceNS; self.referenceNS = referenceNS
    }
}
public struct IMUSample: Sendable, Codable, Equatable {
    public var sequence: UInt64
    public var deviceNS: Int64
    public var x: Double
    public var y: Double
    public var z: Double
    public init(sequence: UInt64, deviceNS: Int64, x: Double, y: Double, z: Double) {
        self.sequence = sequence; self.deviceNS = deviceNS; self.x = x; self.y = y; self.z = z
    }
}
public struct CameraFrame: Sendable, Codable, Equatable {
    public var sequence: UInt64
    public var referenceNS: Int64
    public init(sequence: UInt64, referenceNS: Int64) { self.sequence = sequence; self.referenceNS = referenceNS }
}
public enum InputEvent: Sendable, Equatable {
    case anchor(ClockAnchor), imu(IMUSample), frame(CameraFrame)
    var isValid: Bool {
        switch self {
        case .anchor(let value): value.deviceNS >= 0 && value.referenceNS >= 0
        case .imu(let value): value.deviceNS >= 0 && value.x.isFinite && value.y.isFinite && value.z.isFinite
        case .frame(let value): value.referenceNS >= 0
        }
    }
}
public enum Source: UInt32, Sendable, Codable { case imu = 0, camera = 1 }
public enum SourceState: UInt32, Sendable, Codable { case active = 0, idle = 1, stopped = 2 }
public enum NativeStatus: UInt32, Sendable, Codable, Error {
    case ok = 0, empty, uncalibrated, invalidArgument, duplicate, late, capacity, staleSequence
    case sourceInactive, finished, outputPending, discontinuity, clockRange, internalError
    init(_ status: RIPStatus) { self = Self(rawValue: status.rawValue) ?? .internalError }
}
public enum AlignmentQuality: UInt32, Sendable, Codable {
    case exact = 0, interpolated, missingLeft, missingRight, gapTooLarge, clockUnavailable, pendingOverflow, historyEvicted
}
public struct AlignedFrame: Sendable, Codable, Equatable {
    public let frameSequence: UInt64
    public let referenceNS: Int64
    public let quality: AlignmentQuality
    public let available: Bool
    public let x: Double
    public let y: Double
    public let z: Double
    public let hasLeft: Bool
    public let hasRight: Bool
    public let leftSequence: UInt64
    public let rightSequence: UInt64
    public let leftDeviceNS: Int64
    public let rightDeviceNS: Int64
    public let leftNormalizedNS: Int64
    public let rightNormalizedNS: Int64
    public let clockEpoch: UInt64
    public let leftClockRevision: UInt64
    public let rightClockRevision: UInt64
    init(_ value: RIPOutput) {
        frameSequence = value.frame_sequence; referenceNS = value.reference_ns
        quality = AlignmentQuality(rawValue: value.quality) ?? .clockUnavailable
        available = value.available != 0; x = value.x; y = value.y; z = value.z
        hasLeft = value.has_left != 0; hasRight = value.has_right != 0
        leftSequence = value.left_sequence; rightSequence = value.right_sequence
        leftDeviceNS = value.left_device_ns; rightDeviceNS = value.right_device_ns
        leftNormalizedNS = value.left_normalized_ns; rightNormalizedNS = value.right_normalized_ns
        clockEpoch = value.clock_epoch; leftClockRevision = value.left_clock_revision; rightClockRevision = value.right_clock_revision
    }
}
public struct CoreConfiguration: Sendable, Codable, Equatable {
    public var anchorCapacity: UInt32
    public var minAnchors: UInt32
    public var minAnchorSpanNS: Int64
    public var maxQueryDistanceNS: Int64
    public var maxDriftPPM: Double
    public var maxAnchorResidualNS: Double
    public var minInlierFraction: Double
    public var reorderCapacity: UInt32
    public var historyCapacity: UInt32
    public var pendingFrameCapacity: UInt32
    public var dedupCapacity: UInt32
    public var latenessNS: Int64
    public var maxInterpolationGapNS: Int64
    public init() {
        let value = rip_default_config()
        anchorCapacity = value.anchor_capacity; minAnchors = value.min_anchors
        minAnchorSpanNS = value.min_anchor_span_ns; maxQueryDistanceNS = value.max_query_distance_ns
        maxDriftPPM = value.max_drift_ppm; maxAnchorResidualNS = value.max_anchor_residual_ns
        minInlierFraction = value.min_inlier_fraction; reorderCapacity = value.reorder_capacity
        historyCapacity = value.history_capacity; pendingFrameCapacity = value.pending_frame_capacity
        dedupCapacity = value.dedup_capacity; latenessNS = value.lateness_ns
        maxInterpolationGapNS = value.max_interpolation_gap_ns
    }
    var native: RIPConfig {
        RIPConfig(anchor_capacity: anchorCapacity, min_anchors: minAnchors,
                  min_anchor_span_ns: minAnchorSpanNS, max_query_distance_ns: maxQueryDistanceNS,
                  max_drift_ppm: maxDriftPPM, max_anchor_residual_ns: maxAnchorResidualNS,
                  min_inlier_fraction: minInlierFraction, reorder_capacity: reorderCapacity,
                  history_capacity: historyCapacity, pending_frame_capacity: pendingFrameCapacity,
                  dedup_capacity: dedupCapacity, lateness_ns: latenessNS, max_interpolation_gap_ns: maxInterpolationGapNS)
    }
}
public struct PipelineConfiguration: Sendable, Codable, Equatable {
    public var ingressCapacity: Int
    public var outputCapacity: Int
    public var core: CoreConfiguration
    public init(ingressCapacity: Int = 64, outputCapacity: Int = 64, core: CoreConfiguration = .init()) {
        self.ingressCapacity = ingressCapacity; self.outputCapacity = outputCapacity; self.core = core
    }
}
public struct Ticket: Sendable, Equatable, Codable {
    public let value: UInt64
    public init(value: UInt64) { self.value = value }
}
public enum OfferRejection: String, Sendable, Codable, Error { case full, staleGeneration, closed, controlBusy, invalid }
public enum OfferReceipt: Sendable, Equatable { case accepted(Ticket), rejected(OfferRejection) }
public enum PipelineError: Error, Sendable, Equatable {
    case invalidConfiguration, alreadyRunning, noSession, staleGeneration, closed, cancelled
    case invalidTicket, concurrentWaiter, controlBusy, native(NativeStatus)
}
public struct Session: Sendable {
    public let generation: UInt64
    public let outputs: AsyncStream<AlignedFrame>
}
