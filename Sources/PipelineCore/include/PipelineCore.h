#ifndef REALTIME_INPUT_PIPELINE_CORE_H
#define REALTIME_INPUT_PIPELINE_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RIPCore RIPCore;
typedef enum RIPStatus {
    RIP_OK = 0, RIP_EMPTY = 1, RIP_UNCALIBRATED = 2, RIP_INVALID_ARGUMENT = 3,
    RIP_DUPLICATE = 4, RIP_LATE = 5, RIP_CAPACITY = 6, RIP_STALE_SEQUENCE = 7,
    RIP_SOURCE_INACTIVE = 8, RIP_FINISHED = 9, RIP_OUTPUT_PENDING = 10,
    RIP_DISCONTINUITY = 11, RIP_CLOCK_RANGE = 12, RIP_INTERNAL_ERROR = 13
} RIPStatus;
enum { RIP_SOURCE_IMU = 0, RIP_SOURCE_CAMERA = 1 };
enum { RIP_SOURCE_ACTIVE = 0, RIP_SOURCE_IDLE = 1, RIP_SOURCE_STOPPED = 2 };
enum {
    RIP_QUALITY_EXACT = 0, RIP_QUALITY_INTERPOLATED = 1,
    RIP_QUALITY_MISSING_LEFT = 2, RIP_QUALITY_MISSING_RIGHT = 3,
    RIP_QUALITY_GAP_TOO_LARGE = 4, RIP_QUALITY_CLOCK_UNAVAILABLE = 5,
    RIP_QUALITY_PENDING_OVERFLOW = 6, RIP_QUALITY_HISTORY_EVICTED = 7
};
enum {
    RIP_CLOCK_INSUFFICIENT = 0, RIP_CLOCK_READY = 1, RIP_CLOCK_DEGENERATE = 2,
    RIP_CLOCK_INVALID = 3, RIP_CLOCK_OUTLIERS = 4
};

typedef struct RIPConfig {
    uint32_t anchor_capacity, min_anchors;
    int64_t min_anchor_span_ns, max_query_distance_ns;
    double max_drift_ppm, max_anchor_residual_ns, min_inlier_fraction;
    uint32_t reorder_capacity, history_capacity, pending_frame_capacity, dedup_capacity;
    int64_t lateness_ns, max_interpolation_gap_ns;
} RIPConfig;

/* A trusted same-instant correspondence, never an inferred receive-time pair. */
typedef struct RIPAnchor {
    uint64_t sequence;
    int64_t device_ns, reference_ns;
} RIPAnchor;
typedef struct RIPIMUSample {
    uint64_t sequence;
    int64_t device_ns;
    double x, y, z;
} RIPIMUSample;
typedef struct RIPFrame {
    uint64_t sequence;
    int64_t reference_ns;
} RIPFrame;

typedef struct RIPOutput {
    uint64_t frame_sequence;
    int64_t reference_ns;
    uint32_t quality, available, has_left, has_right;
    double x, y, z;
    uint64_t left_sequence, right_sequence;
    int64_t left_device_ns, right_device_ns, left_normalized_ns, right_normalized_ns;
    uint64_t clock_epoch, left_clock_revision, right_clock_revision;
} RIPOutput;

typedef struct RIPClockInfo {
    uint32_t state, anchors, inliers;
    uint64_t epoch, revision;
    int64_t device_origin_ns, reference_origin_ns, support_min_ns, support_max_ns;
    double slope, local_offset_ns, drift_ppm, residual_rms_ns, residual_max_ns;
} RIPClockInfo;

typedef struct RIPMetrics {
    uint64_t imu_received, frames_received, imu_accepted, frames_accepted;
    uint64_t outputs, exact_outputs, interpolated_outputs;
    uint64_t missing_left, missing_right, gap_too_large, clock_unavailable;
    uint64_t pending_overflow, history_evicted, duplicate_timestamp; /* history_evicted counts retained sample evictions. */
    uint64_t rejected_uncalibrated, rejected_invalid, rejected_late, rejected_duplicate;
    uint64_t rejected_stale_sequence, rejected_capacity, rejected_source_inactive;
    uint64_t rejected_finished, rejected_output_pending;
    uint64_t anchor_received, anchor_duplicates, anchor_invalid, clock_discontinuities;
    uint64_t events_discarded_reset, frames_discarded_reset;
    uint64_t events_discarded_cancel, frames_discarded_cancel;
    uint64_t queue_occupancy, queue_high_water, history_occupancy;
    uint64_t pending_occupancy, pending_high_water, output_occupancy;
    int64_t watermark_ns;
    uint32_t terminal, faulted;
} RIPMetrics;

/* Config and requests are copied. No pointer is retained and no call suspends.
   One owner must serialize each handle. Exceptions are contained by the facade.
   Drain all outputs after every operation before submitting the next operation. */
RIPConfig rip_default_config(void);
RIPCore* rip_core_create(RIPConfig config, RIPStatus* status);
void rip_core_destroy(RIPCore* core);
RIPStatus rip_core_add_anchor(RIPCore* core, RIPAnchor anchor);
RIPStatus rip_core_push_imu(RIPCore* core, RIPIMUSample sample);
RIPStatus rip_core_push_frame(RIPCore* core, RIPFrame frame);
RIPStatus rip_core_set_source(RIPCore* core, uint32_t source, uint32_t state);
RIPStatus rip_core_finish(RIPCore* core);
RIPStatus rip_core_cancel(RIPCore* core);
RIPStatus rip_core_pop_output(RIPCore* core, RIPOutput* output);
RIPStatus rip_core_metrics(const RIPCore* core, RIPMetrics* metrics);
RIPStatus rip_core_clock_info(const RIPCore* core, RIPClockInfo* info);
RIPStatus rip_core_map_time(const RIPCore* core, int64_t device_ns, int64_t* reference_ns);

#ifdef __cplusplus
}
#endif
#endif
