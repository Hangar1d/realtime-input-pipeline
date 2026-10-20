import PipelineCore

public struct IngressMetrics: Sendable, Codable, Equatable {
    public internal(set) var attempts: UInt64 = 0
    public internal(set) var accepted: UInt64 = 0
    public internal(set) var full: UInt64 = 0
    public internal(set) var stale: UInt64 = 0
    public internal(set) var closed: UInt64 = 0
    public internal(set) var busy: UInt64 = 0
    public internal(set) var invalid: UInt64 = 0
    public internal(set) var processed: UInt64 = 0
    public internal(set) var cancelledBuffered: UInt64 = 0
    public internal(set) var cancelledInFlight: UInt64 = 0
    public internal(set) var queuedData: Int = 0
    public internal(set) var queuedControls: Int = 0
    public internal(set) var inFlight: Int = 0
    public internal(set) var queueHighWater: Int = 0
    public var admissionReconciles: Bool { attempts == accepted + full + stale + closed + busy + invalid }
    public var completionReconciles: Bool { accepted == processed + cancelledBuffered + cancelledInFlight + UInt64(queuedData + queuedControls + inFlight) }
}
public struct OutputMetrics: Sendable, Codable, Equatable {
    public internal(set) var produced: UInt64 = 0
    public internal(set) var enqueued: UInt64 = 0
    public internal(set) var dropped: UInt64 = 0
    public internal(set) var terminated: UInt64 = 0
    public var reconciles: Bool { produced == enqueued + dropped + terminated }
}
public struct ServiceTimeStatistics: Sendable, Codable, Equatable {
    public internal(set) var count: UInt64 = 0
    public internal(set) var meanNS: Double = 0
    public internal(set) var sampleVarianceNS2: Double = 0
    public internal(set) var minNS: Double = 0
    public internal(set) var maxNS: Double = 0
}
struct ServiceAccumulator {
    private var count: UInt64 = 0
    private var mean: Double = 0
    private var m2: Double = 0
    private var minimum: Double = 0
    private var maximum: Double = 0
    mutating func add(_ nanoseconds: Double) {
        guard nanoseconds.isFinite, nanoseconds >= 0 else { return }
        count += 1
        let delta = nanoseconds - mean
        mean += delta / Double(count)
        m2 += delta * (nanoseconds - mean)
        minimum = count == 1 ? nanoseconds : min(minimum, nanoseconds)
        maximum = max(maximum, nanoseconds)
    }
    var snapshot: ServiceTimeStatistics {
        ServiceTimeStatistics(count: count, meanNS: mean,
                              sampleVarianceNS2: count > 1 ? max(0, m2 / Double(count - 1)) : 0,
                              minNS: minimum, maxNS: maximum)
    }
}
public struct ClockInfo: Sendable, Codable, Equatable {
    public let state: UInt32
    public let anchors: UInt32
    public let inliers: UInt32
    public let epoch: UInt64
    public let revision: UInt64
    public let deviceOriginNS: Int64
    public let referenceOriginNS: Int64
    public let supportMinNS: Int64
    public let supportMaxNS: Int64
    public let slope: Double
    public let localOffsetNS: Double
    public let driftPPM: Double
    public let residualRMSNS: Double
    public let residualMaxNS: Double
    init(_ value: RIPClockInfo) {
        state = value.state; anchors = value.anchors; inliers = value.inliers
        epoch = value.epoch; revision = value.revision; deviceOriginNS = value.device_origin_ns
        referenceOriginNS = value.reference_origin_ns; supportMinNS = value.support_min_ns; supportMaxNS = value.support_max_ns
        slope = value.slope; localOffsetNS = value.local_offset_ns; driftPPM = value.drift_ppm
        residualRMSNS = value.residual_rms_ns; residualMaxNS = value.residual_max_ns
    }
}
public struct CoreMetrics: Sendable, Codable, Equatable {
    public let imuReceived, framesReceived, imuAccepted, framesAccepted: UInt64
    public let outputs, exactOutputs, interpolatedOutputs: UInt64
    public let missingLeft, missingRight, gapTooLarge, clockUnavailable: UInt64
    public let pendingOverflow, historyEvicted, duplicateTimestamp: UInt64
    public let rejectedUncalibrated, rejectedInvalid, rejectedLate, rejectedDuplicate: UInt64
    public let rejectedStaleSequence, rejectedCapacity, rejectedSourceInactive: UInt64
    public let rejectedFinished, rejectedOutputPending: UInt64
    public let anchorReceived, anchorDuplicates, anchorInvalid, clockDiscontinuities: UInt64
    public let eventsDiscardedReset, framesDiscardedReset, eventsDiscardedCancel, framesDiscardedCancel: UInt64
    public let queueOccupancy, queueHighWater, historyOccupancy, pendingOccupancy, pendingHighWater, outputOccupancy: UInt64
    public let watermarkNS: Int64
    public let terminal, faulted: Bool
    init(_ value: RIPMetrics) {
        imuReceived = value.imu_received; framesReceived = value.frames_received; imuAccepted = value.imu_accepted; framesAccepted = value.frames_accepted
        outputs = value.outputs; exactOutputs = value.exact_outputs; interpolatedOutputs = value.interpolated_outputs
        missingLeft = value.missing_left; missingRight = value.missing_right; gapTooLarge = value.gap_too_large; clockUnavailable = value.clock_unavailable
        pendingOverflow = value.pending_overflow; historyEvicted = value.history_evicted; duplicateTimestamp = value.duplicate_timestamp
        rejectedUncalibrated = value.rejected_uncalibrated; rejectedInvalid = value.rejected_invalid; rejectedLate = value.rejected_late; rejectedDuplicate = value.rejected_duplicate
        rejectedStaleSequence = value.rejected_stale_sequence; rejectedCapacity = value.rejected_capacity; rejectedSourceInactive = value.rejected_source_inactive
        rejectedFinished = value.rejected_finished; rejectedOutputPending = value.rejected_output_pending
        anchorReceived = value.anchor_received; anchorDuplicates = value.anchor_duplicates; anchorInvalid = value.anchor_invalid; clockDiscontinuities = value.clock_discontinuities
        eventsDiscardedReset = value.events_discarded_reset; framesDiscardedReset = value.frames_discarded_reset
        eventsDiscardedCancel = value.events_discarded_cancel; framesDiscardedCancel = value.frames_discarded_cancel
        queueOccupancy = value.queue_occupancy; queueHighWater = value.queue_high_water; historyOccupancy = value.history_occupancy
        pendingOccupancy = value.pending_occupancy; pendingHighWater = value.pending_high_water; outputOccupancy = value.output_occupancy
        watermarkNS = value.watermark_ns; terminal = value.terminal != 0; faulted = value.faulted != 0
    }
}
public struct PipelineReport: Sendable, Codable, Equatable {
    public let generation: UInt64
    public let cancelled: Bool
    public let ingress: IngressMetrics
    public let output: OutputMetrics
    public let core: CoreMetrics
    public let clock: ClockInfo
    public let serviceTime: ServiceTimeStatistics
    public let queueWait: ServiceTimeStatistics
    /// Native clock discontinuity or an internal fault ends the Swift generation
    /// and remains visible after cleanup. Restart requires fresh trusted anchors.
    public let finalStatus: NativeStatus
}
