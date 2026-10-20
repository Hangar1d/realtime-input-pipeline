#include "PipelineCore.h"

#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <new>
#include <utility>
#include <vector>

#if defined(__FAST_MATH__) || (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__)
#error "PipelineCore requires IEEE binary64 without fast-math"
#endif

namespace {
static_assert(std::numeric_limits<double>::is_iec559 && std::numeric_limits<double>::digits == 53,
    "PipelineCore requires IEEE binary64");
constexpr int64_t kExactIntegerLimit = INT64_C(9007199254740992);
constexpr uint32_t kMaximumCount = 65536;

bool addChecked(int64_t a, int64_t b, int64_t& result) noexcept {
    if ((b > 0 && a > INT64_MAX - b) || (b < 0 && a < INT64_MIN - b)) return false;
    result = a + b;
    return true;
}

// Coordinates are nonnegative, so these signed differences cannot overflow.
bool difference(int64_t a, int64_t b, double& result) noexcept {
    const int64_t delta = a - b;
    if (delta < -kExactIntegerLimit || delta > kExactIntegerLimit) return false;
    result = static_cast<double>(delta);
    return true;
}

bool validConfig(const RIPConfig& c) noexcept {
    return c.anchor_capacity >= 2 && c.anchor_capacity <= 64 && c.min_anchors >= 2 &&
        c.min_anchors <= c.anchor_capacity && c.min_anchor_span_ns > 0 &&
        c.min_anchor_span_ns <= kExactIntegerLimit && c.max_query_distance_ns > 0 &&
        c.max_query_distance_ns < kExactIntegerLimit && std::isfinite(c.max_drift_ppm) &&
        c.max_drift_ppm >= 0 && c.max_drift_ppm < 1000000 &&
        std::isfinite(c.max_anchor_residual_ns) && c.max_anchor_residual_ns >= 0 &&
        std::isfinite(c.min_inlier_fraction) && c.min_inlier_fraction > 0 &&
        c.min_inlier_fraction <= 1 && c.reorder_capacity > 0 &&
        c.reorder_capacity <= kMaximumCount && c.history_capacity >= 2 &&
        c.history_capacity <= kMaximumCount && c.pending_frame_capacity > 0 &&
        c.pending_frame_capacity <= kMaximumCount && c.dedup_capacity > 0 &&
        c.dedup_capacity <= kMaximumCount && c.lateness_ns >= 0 &&
        c.max_interpolation_gap_ns > 0 && c.max_interpolation_gap_ns <= kExactIntegerLimit;
}

double median(std::vector<double>& values) {
    std::sort(values.begin(), values.end());
    const size_t n = values.size();
    return n % 2 ? values[n / 2] : values[n / 2 - 1] * 0.5 + values[n / 2] * 0.5;
}

// Nonnegative error bounds are rounded outward, independently of the direction
// in which an individual operation rounded. Fits require round-to-nearest.
double addUp(double a, double b) noexcept {
    return std::nextafter(a + b, std::numeric_limits<double>::infinity());
}

double multiplyUp(double a, double b) noexcept {
    return std::nextafter(a * b, std::numeric_limits<double>::infinity());
}

double ulp(double value) noexcept {
    const double magnitude = std::abs(value);
    return std::nextafter(magnitude, std::numeric_limits<double>::infinity()) - magnitude;
}

double centeredError(double dx, double slopeError, double value) noexcept {
    return addUp(multiplyUp(std::abs(dx), slopeError), ulp(value));
}

bool lessEqualExactSum(double value, double a, double b) noexcept {
    if (value <= a) return true;
    // FastTwoSum retains the signed rounding error, so the comparison is to the
    // exact real a+b, rather than a threshold enlarged by one more rounded sum.
    const double larger = std::max(a, b), smaller = std::min(a, b);
    const double sum = larger + smaller;
    if (!std::isfinite(sum)) return true;
    const double error = smaller - (sum - larger);
    return value < sum || (value == sum && error >= 0);
}

double boundedLerp(double left, double right, double weight) noexcept {
    if (left == right || weight <= 0) return left;
    if (weight >= 1) return right;
    // With equal signs the difference is finite. With opposite signs the two
    // weighted terms cannot overflow their sum. This avoids both an overflowing
    // opposite-sign difference and independently rounded same-sign weights.
    const double value = std::signbit(left) == std::signbit(right) ?
        std::fma(weight, right - left, left) : std::fma(weight, right, (1 - weight) * left);
    // A convex interpolation stays inside the finite endpoint range, including
    // rounding at extreme magnitudes. The caller has already required 0 < w < 1.
    return std::clamp(value, std::min(left, right), std::max(left, right));
}

struct Line {
    int64_t deviceOrigin = 0, referenceOrigin = 0, supportMin = 0, supportMax = 0;
    double slope = 1, offset = 0;
    double slopeError = 0, offsetError = 0;
};

struct Residual {
    double value = 0, error = 0;
};

struct Event {
    uint32_t kind = RIP_SOURCE_IMU;
    uint64_t sequence = 0;
    int64_t time = 0, device = 0;
    double x = 0, y = 0, z = 0;
    uint64_t epoch = 0, revision = 0;
    bool clockAvailable = false;
};

bool earlier(const Event& a, const Event& b) noexcept {
    if (a.time != b.time) return a.time < b.time;
    if (a.kind != b.kind) return a.kind < b.kind;
    return a.sequence < b.sequence;
}
struct Later {
    bool operator()(const Event& a, const Event& b) const noexcept { return earlier(b, a); }
};

struct Source {
    uint32_t state = RIP_SOURCE_ACTIVE;
    bool seen = false;
    int64_t maximum = 0;
    bool hasSequence = false;
    uint64_t maximumSequence = 0;
    std::vector<uint64_t> identities;
};
} // namespace

struct RIPCore {
    explicit RIPCore(RIPConfig configuration) : config(configuration) {
        anchors.reserve(config.anchor_capacity);
        inliers.reserve(config.anchor_capacity);
        slopes.reserve(static_cast<size_t>(config.anchor_capacity) * (config.anchor_capacity - 1) / 2);
        residuals.reserve(config.anchor_capacity);
        queue.reserve(config.reorder_capacity);
        history.reserve(config.history_capacity + 1U);
        pending.reserve(config.pending_frame_capacity);
        outputs.reserve(static_cast<size_t>(config.reorder_capacity) + config.pending_frame_capacity + 1);
        for (auto& source : sources) source.identities.reserve(config.dedup_capacity);
        clock.epoch = 1;
        clock.slope = 1;
    }

    RIPConfig config;
    RIPClockInfo clock{};
    RIPMetrics metrics{};
    Source sources[2];
    std::vector<RIPAnchor> anchors, inliers;
    std::vector<double> slopes, residuals;
    std::vector<Event> queue, history, pending;
    std::vector<RIPOutput> outputs;
    size_t outputIndex = 0;
    uint32_t queuedIMU = 0;
    bool hasEvictedHistory = false;
    int64_t evictedThrough = 0;

    bool hasOutput() const noexcept { return outputIndex < outputs.size(); }

    RIPStatus preflight(bool allowOutput = false) noexcept {
        if (metrics.faulted) return RIP_INTERNAL_ERROR;
        if (!allowOutput && hasOutput()) {
            ++metrics.rejected_output_pending;
            return RIP_OUTPUT_PENDING;
        }
        if (metrics.terminal) {
            ++metrics.rejected_finished;
            return RIP_FINISHED;
        }
        return RIP_OK;
    }

    RIPStatus identityStatus(uint32_t kind, uint64_t identity) const noexcept {
        const Source& source = sources[kind];
        if (std::find(source.identities.begin(), source.identities.end(), identity) != source.identities.end())
            return RIP_DUPLICATE;
        if (source.hasSequence && identity <= source.maximumSequence &&
            source.maximumSequence - identity >= config.dedup_capacity) return RIP_STALE_SEQUENCE;
        return RIP_OK;
    }

    void admitIdentity(uint32_t kind, uint64_t identity) {
        Source& source = sources[kind];
        if (!source.hasSequence || identity > source.maximumSequence) {
            source.maximumSequence = identity;
            source.hasSequence = true;
        }
        source.identities.erase(std::remove_if(source.identities.begin(), source.identities.end(),
            [&](uint64_t item) { return source.maximumSequence - item >= config.dedup_capacity; }),
            source.identities.end());
        source.identities.push_back(identity);
    }

    RIPStatus reject(RIPStatus status) noexcept {
        switch (status) {
        case RIP_INVALID_ARGUMENT: case RIP_CLOCK_RANGE: ++metrics.rejected_invalid; break;
        case RIP_UNCALIBRATED: ++metrics.rejected_uncalibrated; break;
        case RIP_LATE: ++metrics.rejected_late; break;
        case RIP_DUPLICATE: ++metrics.rejected_duplicate; break;
        case RIP_STALE_SEQUENCE: ++metrics.rejected_stale_sequence; break;
        case RIP_CAPACITY: ++metrics.rejected_capacity; break;
        case RIP_SOURCE_INACTIVE: ++metrics.rejected_source_inactive; break;
        default: break;
        }
        return status;
    }

    bool slopeAllowed(double value) const noexcept {
        const double delta = config.max_drift_ppm / 1000000.0;
        // Inclusive limits with a one-ULP guard for binary64 division at the boundary.
        return std::isfinite(value) && value > 0 &&
            value >= std::nextafter(1.0 - delta, -std::numeric_limits<double>::infinity()) &&
            value <= std::nextafter(1.0 + delta, std::numeric_limits<double>::infinity());
    }

    uint32_t fitLine(const std::vector<RIPAnchor>& points, Line& line) {
        if (points.size() < config.min_anchors) return RIP_CLOCK_INSUFFICIENT;
        if (std::fegetround() != FE_TONEAREST) return RIP_CLOCK_INVALID;
        line.deviceOrigin = points[points.size() / 2].device_ns;
        line.referenceOrigin = points[points.size() / 2].reference_ns;
        line.supportMin = points.front().device_ns;
        line.supportMax = points.back().device_ns;
        if (line.supportMax - line.supportMin < config.min_anchor_span_ns) return RIP_CLOCK_DEGENERATE;
        slopes.clear();
        for (size_t i = 0; i < points.size(); ++i) {
            double dx = 0, dy = 0;
            if (!difference(points[i].device_ns, line.deviceOrigin, dx) ||
                !difference(points[i].reference_ns, line.referenceOrigin, dy)) return RIP_CLOCK_INVALID;
            for (size_t j = i + 1; j < points.size(); ++j) {
                double pairX = 0, pairY = 0;
                if (!difference(points[j].device_ns, points[i].device_ns, pairX) ||
                    !difference(points[j].reference_ns, points[i].reference_ns, pairY)) return RIP_CLOCK_INVALID;
                if (pairX != 0) slopes.push_back(pairY / pairX);
            }
        }
        if (slopes.empty()) return RIP_CLOCK_DEGENERATE;
        line.slope = median(slopes);
        if (!std::isfinite(line.slope) || line.slope <= 0) return RIP_CLOCK_INVALID;
        // Exact integer deltas give correctly rounded normal pair quotients.
        // Their median (including an even median's addition) has error bounded
        // by 4*u*|slope|, u=2^-53. The preliminary fit need not meet the ppm gate.
        line.slopeError = multiplyUp(0x1p-51, std::abs(line.slope));
        line.offsetError = 0;
        residuals.clear();
        for (const auto& point : points) {
            double dx = 0, dy = 0;
            if (!difference(point.device_ns, line.deviceOrigin, dx) ||
                !difference(point.reference_ns, line.referenceOrigin, dy)) return RIP_CLOCK_INVALID;
            const double value = std::fma(-line.slope, dx, dy);
            residuals.push_back(value);
            line.offsetError = std::max(line.offsetError, centeredError(dx, line.slopeError, value));
        }
        line.offset = median(residuals);
        // A median is 1-Lipschitz in the maximum input error. Include the final
        // even-median addition; one full output ULP safely covers each rounding.
        line.offsetError = addUp(line.offsetError, ulp(line.offset));
        return std::isfinite(line.offset) && std::isfinite(line.offsetError) ?
            RIP_CLOCK_READY : RIP_CLOCK_INVALID;
    }

    Residual residual(const RIPAnchor& point, const Line& line) const noexcept {
        double dx = 0, dy = 0;
        if (!difference(point.device_ns, line.deviceOrigin, dx) ||
            !difference(point.reference_ns, line.referenceOrigin, dy)) {
            const double infinity = std::numeric_limits<double>::infinity();
            return {infinity, infinity};
        }
        const double centered = std::fma(-line.slope, dx, dy);
        const double value = centered - line.offset;
        const double error = addUp(addUp(centeredError(dx, line.slopeError, centered), line.offsetError), ulp(value));
        return {value, error};
    }

    bool withinResidual(Residual estimate) const noexcept {
        // Admit interval overlap with the physical gate. This preserves exact
        // inclusive membership, but an ambiguous accepted exact residual may be
        // as large as gate+2*error. Diagnostics remain the binary64 estimates.
        return std::isfinite(estimate.value) && std::isfinite(estimate.error) &&
            lessEqualExactSum(std::abs(estimate.value), config.max_anchor_residual_ns, estimate.error);
    }

    void updateClock() {
        clock.anchors = static_cast<uint32_t>(anchors.size());
        clock.inliers = 0;
        clock.residual_max_ns = 0;
        clock.residual_rms_ns = 0;
        Line preliminary;
        clock.state = fitLine(anchors, preliminary);
        if (clock.state != RIP_CLOCK_READY) return;
        inliers.clear();
        for (const auto& anchor : anchors)
            if (withinResidual(residual(anchor, preliminary))) inliers.push_back(anchor);
        clock.inliers = static_cast<uint32_t>(inliers.size());
        if (inliers.size() < config.min_anchors ||
            static_cast<double>(inliers.size()) / static_cast<double>(anchors.size()) < config.min_inlier_fraction) {
            clock.state = RIP_CLOCK_OUTLIERS;
            return;
        }
        Line finalLine;
        clock.state = fitLine(inliers, finalLine);
        if (clock.state != RIP_CLOCK_READY) return;
        if (!slopeAllowed(finalLine.slope)) { clock.state = RIP_CLOCK_INVALID; return; }
        double sumSquares = 0, maximum = 0;
        for (const auto& point : inliers) {
            const Residual estimate = residual(point, finalLine);
            if (!withinResidual(estimate)) { clock.state = RIP_CLOCK_OUTLIERS; return; }
            const double r = estimate.value;
            maximum = std::max(maximum, std::abs(r));
            sumSquares += r * r;
        }
        if (!std::isfinite(sumSquares) || clock.revision == UINT64_MAX) {
            clock.state = RIP_CLOCK_INVALID;
            return;
        }
        ++clock.revision;
        clock.device_origin_ns = finalLine.deviceOrigin;
        clock.reference_origin_ns = finalLine.referenceOrigin;
        clock.support_min_ns = finalLine.supportMin;
        clock.support_max_ns = finalLine.supportMax;
        clock.slope = finalLine.slope;
        clock.local_offset_ns = finalLine.offset;
        clock.drift_ppm = (clock.slope - 1.0) * 1000000.0;
        clock.residual_max_ns = maximum;
        clock.residual_rms_ns = std::sqrt(sumSquares / static_cast<double>(inliers.size()));
    }

    RIPStatus map(int64_t device, int64_t& reference) const noexcept {
        if (device < 0) return RIP_INVALID_ARGUMENT;
        if (clock.state != RIP_CLOCK_READY) return RIP_UNCALIBRATED;
        if (std::fegetround() != FE_TONEAREST) return RIP_CLOCK_RANGE;
        double delta = 0;
        if (!difference(device, clock.device_origin_ns, delta) ||
            std::abs(delta) > static_cast<double>(config.max_query_distance_ns)) return RIP_CLOCK_RANGE;
        const double local = std::round(std::fma(clock.slope, delta, clock.local_offset_ns));
        if (!std::isfinite(local) || local < -0x1p63 || local >= 0x1p63) return RIP_CLOCK_RANGE;
        int64_t result = 0;
        if (!addChecked(clock.reference_origin_ns, static_cast<int64_t>(local), result) || result < 0)
            return RIP_CLOCK_RANGE;
        reference = result;
        return RIP_OK;
    }

    void discardBuffered(bool cancelled) noexcept {
        uint64_t frames = pending.size();
        for (const auto& event : queue) if (event.kind == RIP_SOURCE_CAMERA) ++frames;
        const uint64_t events = queue.size() + history.size() + pending.size();
        if (cancelled) {
            metrics.events_discarded_cancel += events;
            metrics.frames_discarded_cancel += frames;
        } else {
            metrics.events_discarded_reset += events;
            metrics.frames_discarded_reset += frames;
        }
        queue.clear(); history.clear(); pending.clear(); queuedIMU = 0;
        hasEvictedHistory = false;
        evictedThrough = 0;
    }

    RIPStatus addAnchor(RIPAnchor anchor) {
        ++metrics.anchor_received;
        const RIPStatus ready = preflight();
        if (ready != RIP_OK) return ready;
        if (anchor.device_ns < 0 || anchor.reference_ns < 0) {
            ++metrics.anchor_invalid;
            return RIP_INVALID_ARGUMENT;
        }
        for (const auto& point : anchors) {
            if (point.sequence == anchor.sequence) {
                if (point.device_ns == anchor.device_ns && point.reference_ns == anchor.reference_ns) {
                    ++metrics.anchor_duplicates;
                    return RIP_DUPLICATE;
                }
                ++metrics.anchor_invalid;
                return RIP_INVALID_ARGUMENT;
            }
        }
        bool deviceConflict = false;
        for (const auto& point : anchors) {
            if (point.device_ns != anchor.device_ns) continue;
            if (point.reference_ns == anchor.reference_ns) {
                ++metrics.anchor_duplicates;
                return RIP_DUPLICATE;
            }
            deviceConflict = true;
        }
        bool discontinuity = false;
        if (!anchors.empty() && (deviceConflict || anchor.device_ns < anchors.back().device_ns ||
            anchor.reference_ns < anchors.back().reference_ns)) {
            if (clock.epoch == UINT64_MAX) { ++metrics.anchor_invalid; return RIP_CLOCK_RANGE; }
            discardBuffered(false);
            anchors.clear();
            for (auto& source : sources) {
                source.seen = false; source.maximum = 0;
                source.hasSequence = false; source.maximumSequence = 0; source.identities.clear();
            }
            metrics.watermark_ns = 0;
            ++clock.epoch;
            ++metrics.clock_discontinuities;
            clock.state = RIP_CLOCK_INSUFFICIENT;
            discontinuity = true;
        }
        if (anchors.size() == config.anchor_capacity) anchors.erase(anchors.begin());
        anchors.push_back(anchor);
        updateClock();
        return discontinuity ? RIP_DISCONTINUITY : RIP_OK;
    }

    void updateWatermark() noexcept {
        bool anyActive = false, allSeen = true;
        int64_t candidate = INT64_MAX;
        for (const auto& source : sources) {
            if (source.state != RIP_SOURCE_ACTIVE) continue;
            anyActive = true;
            if (!source.seen) { allSeen = false; break; }
            const int64_t local = source.maximum > config.lateness_ns ? source.maximum - config.lateness_ns : 0;
            candidate = std::min(candidate, local);
        }
        if (anyActive && allSeen) metrics.watermark_ns = std::max(metrics.watermark_ns, candidate);
    }

    bool allStopped() const noexcept {
        return sources[0].state == RIP_SOURCE_STOPPED && sources[1].state == RIP_SOURCE_STOPPED;
    }

    RIPOutput makeOutput(const Event& frame) const noexcept {
        RIPOutput output{};
        output.frame_sequence = frame.sequence;
        output.reference_ns = frame.time;
        output.clock_epoch = frame.epoch;
        return output;
    }

    static void setLeft(RIPOutput& output, const Event& event) noexcept {
        output.has_left = 1;
        output.left_sequence = event.sequence;
        output.left_device_ns = event.device;
        output.left_normalized_ns = event.time;
        output.left_clock_revision = event.revision;
    }
    static void setRight(RIPOutput& output, const Event& event) noexcept {
        output.has_right = 1;
        output.right_sequence = event.sequence;
        output.right_device_ns = event.device;
        output.right_normalized_ns = event.time;
        output.right_clock_revision = event.revision;
    }

    bool align(const Event& frame, RIPOutput& output, bool finalizing) const noexcept {
        output = makeOutput(frame);
        if (!frame.clockAvailable) { output.quality = RIP_QUALITY_CLOCK_UNAVAILABLE; return true; }
        const auto right = std::lower_bound(history.begin(), history.end(), frame.time,
            [](const Event& item, int64_t time) { return item.time < time; });
        if (right != history.end() && right->time == frame.time) {
            setLeft(output, *right); setRight(output, *right);
            output.available = 1; output.quality = RIP_QUALITY_EXACT;
            output.x = right->x; output.y = right->y; output.z = right->z;
            return true;
        }
        if (right != history.end()) setRight(output, *right);
        if (right == history.begin()) {
            output.quality = hasEvictedHistory && frame.time <= evictedThrough ?
                RIP_QUALITY_HISTORY_EVICTED : RIP_QUALITY_MISSING_LEFT;
            return true;
        }
        const Event& left = *(right - 1);
        setLeft(output, left);
        if (right == history.end()) {
            int64_t deadline = 0;
            const bool expired = addChecked(frame.time, config.max_interpolation_gap_ns, deadline) &&
                metrics.watermark_ns > deadline;
            if (!finalizing && !expired) return false;
            output.quality = RIP_QUALITY_MISSING_RIGHT;
            return true;
        }
        const int64_t gap = right->time - left.time;
        if (gap > config.max_interpolation_gap_ns) {
            output.quality = RIP_QUALITY_GAP_TOO_LARGE;
            return true;
        }
        const double weight = static_cast<double>(frame.time - left.time) / static_cast<double>(gap);
        output.x = boundedLerp(left.x, right->x, weight);
        output.y = boundedLerp(left.y, right->y, weight);
        output.z = boundedLerp(left.z, right->z, weight);
        output.available = 1; output.quality = RIP_QUALITY_INTERPOLATED;
        return true;
    }

    void emit(RIPOutput output) {
        // Bound follows from at most Q released frames, P pending frames, and one new frame.
        if (outputs.size() >= static_cast<size_t>(config.reorder_capacity) + config.pending_frame_capacity + 1)
            throw std::bad_alloc();
        outputs.push_back(output);
        ++metrics.outputs;
        switch (output.quality) {
        case RIP_QUALITY_EXACT: ++metrics.exact_outputs; break;
        case RIP_QUALITY_INTERPOLATED: ++metrics.interpolated_outputs; break;
        case RIP_QUALITY_MISSING_LEFT: ++metrics.missing_left; break;
        case RIP_QUALITY_MISSING_RIGHT: ++metrics.missing_right; break;
        case RIP_QUALITY_GAP_TOO_LARGE: ++metrics.gap_too_large; break;
        case RIP_QUALITY_CLOCK_UNAVAILABLE: ++metrics.clock_unavailable; break;
        case RIP_QUALITY_PENDING_OVERFLOW: ++metrics.pending_overflow; break;
        case RIP_QUALITY_HISTORY_EVICTED: break; // history_evicted counts retained IMU entries, not frames.
        default: break;
        }
    }

    void resolvePending(bool allowExpiry) {
        const bool noMoreIMU = sources[RIP_SOURCE_IMU].state == RIP_SOURCE_STOPPED && queuedIMU == 0;
        size_t retained = 0;
        for (size_t index = 0; index < pending.size(); ++index) {
            RIPOutput output{};
            // Expiration is deferred until the current ordered drain has processed eligible successors.
            const int64_t savedWatermark = metrics.watermark_ns;
            if (!allowExpiry) metrics.watermark_ns = 0;
            const bool resolved = align(pending[index], output, allowExpiry && noMoreIMU);
            metrics.watermark_ns = savedWatermark;
            if (resolved) {
                emit(output);
            } else {
                if (retained != index) pending[retained] = pending[index];
                ++retained;
            }
        }
        pending.resize(retained);
    }

    void release(const Event& event) {
        if (event.kind == RIP_SOURCE_IMU) {
            if (!history.empty() && history.back().time == event.time) {
                ++metrics.duplicate_timestamp;
                return;
            }
            history.push_back(event);
            // Resolve using the arriving sealed successor before any retention eviction.
            resolvePending(false);
            if (history.size() > config.history_capacity) {
                evictedThrough = history.front().time;
                hasEvictedHistory = true;
                history.erase(history.begin());
                ++metrics.history_evicted;
            }
        } else {
            RIPOutput output{};
            const int64_t savedWatermark = metrics.watermark_ns;
            metrics.watermark_ns = 0;
            const bool resolved = align(event, output, false);
            metrics.watermark_ns = savedWatermark;
            if (resolved) emit(output);
            else if (pending.size() == config.pending_frame_capacity) {
                output.quality = RIP_QUALITY_PENDING_OVERFLOW;
                emit(output);
            } else {
                pending.push_back(event);
                metrics.pending_high_water = std::max(metrics.pending_high_water, static_cast<uint64_t>(pending.size()));
            }
        }
    }

    void drain() {
        const bool terminal = allStopped();
        while (!queue.empty() && (terminal || queue.front().time < metrics.watermark_ns)) {
            std::pop_heap(queue.begin(), queue.end(), Later{});
            const Event event = queue.back();
            queue.pop_back();
            if (event.kind == RIP_SOURCE_IMU) --queuedIMU;
            release(event);
        }
        resolvePending(true);
        if (terminal) metrics.terminal = 1;
    }

    RIPStatus push(Event event) {
        const RIPStatus ready = preflight();
        if (ready != RIP_OK) return ready;
        if (sources[event.kind].state != RIP_SOURCE_ACTIVE) return reject(RIP_SOURCE_INACTIVE);
        const RIPStatus identity = identityStatus(event.kind, event.sequence);
        if (identity != RIP_OK) return reject(identity);
        if (event.time < metrics.watermark_ns) return reject(RIP_LATE);
        Source& source = sources[event.kind];
        source.maximum = source.seen ? std::max(source.maximum, event.time) : event.time;
        source.seen = true;
        updateWatermark();
        drain();
        if (queue.size() == config.reorder_capacity) return reject(RIP_CAPACITY);
        admitIdentity(event.kind, event.sequence);
        queue.push_back(event);
        std::push_heap(queue.begin(), queue.end(), Later{});
        if (event.kind == RIP_SOURCE_IMU) { ++queuedIMU; ++metrics.imu_accepted; }
        else ++metrics.frames_accepted;
        metrics.queue_high_water = std::max(metrics.queue_high_water, static_cast<uint64_t>(queue.size()));
        drain();
        return RIP_OK;
    }

    RIPStatus pushIMU(RIPIMUSample sample) {
        ++metrics.imu_received;
        const RIPStatus ready = preflight();
        if (ready != RIP_OK) return ready;
        if (sample.device_ns < 0 || !std::isfinite(sample.x) || !std::isfinite(sample.y) || !std::isfinite(sample.z))
            return reject(RIP_INVALID_ARGUMENT);
        int64_t normalized = 0;
        const RIPStatus mapped = map(sample.device_ns, normalized);
        if (mapped != RIP_OK) return reject(mapped);
        Event event;
        event.kind = RIP_SOURCE_IMU; event.sequence = sample.sequence;
        event.time = normalized; event.device = sample.device_ns;
        event.x = sample.x; event.y = sample.y; event.z = sample.z;
        event.epoch = clock.epoch; event.revision = clock.revision; event.clockAvailable = true;
        return push(event);
    }

    RIPStatus pushFrame(RIPFrame frame) {
        ++metrics.frames_received;
        const RIPStatus ready = preflight();
        if (ready != RIP_OK) return ready;
        if (frame.reference_ns < 0) return reject(RIP_INVALID_ARGUMENT);
        Event event;
        event.kind = RIP_SOURCE_CAMERA; event.sequence = frame.sequence; event.time = frame.reference_ns;
        event.epoch = clock.epoch; event.revision = clock.revision;
        event.clockAvailable = clock.state == RIP_CLOCK_READY;
        return push(event);
    }

    RIPStatus setSource(uint32_t source, uint32_t state) {
        const RIPStatus ready = preflight();
        if (ready != RIP_OK) return ready;
        if (source > RIP_SOURCE_CAMERA || state > RIP_SOURCE_STOPPED) return reject(RIP_INVALID_ARGUMENT);
        if (sources[source].state == RIP_SOURCE_STOPPED && state != RIP_SOURCE_STOPPED)
            return reject(RIP_SOURCE_INACTIVE);
        sources[source].state = state;
        updateWatermark();
        drain();
        return RIP_OK;
    }

    RIPStatus finish() {
        const RIPStatus ready = preflight();
        if (ready != RIP_OK) return ready;
        sources[0].state = sources[1].state = RIP_SOURCE_STOPPED;
        drain();
        return RIP_OK;
    }

    RIPStatus cancel() noexcept {
        const RIPStatus ready = preflight(true);
        if (ready != RIP_OK) return ready;
        discardBuffered(true);
        sources[0].state = sources[1].state = RIP_SOURCE_STOPPED;
        metrics.terminal = 1;
        return RIP_OK;
    }

    void fault() noexcept {
        discardBuffered(true);
        metrics.faulted = 1;
        metrics.terminal = 1;
    }

    RIPMetrics snapshot() const noexcept {
        RIPMetrics result = metrics;
        result.queue_occupancy = queue.size();
        result.history_occupancy = history.size();
        result.pending_occupancy = pending.size();
        result.output_occupancy = outputs.size() - outputIndex;
        return result;
    }
};

namespace {
template <class Operation> RIPStatus mutate(RIPCore* core, Operation operation) noexcept {
    if (!core) return RIP_INVALID_ARGUMENT;
    try { return operation(*core); }
    catch (...) { core->fault(); return RIP_INTERNAL_ERROR; }
}
} // namespace

extern "C" {
RIPConfig rip_default_config(void) {
    RIPConfig c{};
    c.anchor_capacity = 17; c.min_anchors = 5;
    c.min_anchor_span_ns = INT64_C(1000000000); c.max_query_distance_ns = INT64_C(60000000000);
    c.max_drift_ppm = 5000; c.max_anchor_residual_ns = 100000; c.min_inlier_fraction = 0.6;
    c.reorder_capacity = 256; c.history_capacity = 512; c.pending_frame_capacity = 64; c.dedup_capacity = 1024;
    c.lateness_ns = INT64_C(20000000); c.max_interpolation_gap_ns = INT64_C(50000000);
    return c;
}

RIPCore* rip_core_create(RIPConfig config, RIPStatus* status) {
    if (!validConfig(config)) { if (status) *status = RIP_INVALID_ARGUMENT; return nullptr; }
    try {
        RIPCore* core = new RIPCore(config);
        if (status) *status = RIP_OK;
        return core;
    } catch (...) { if (status) *status = RIP_INTERNAL_ERROR; return nullptr; }
}
void rip_core_destroy(RIPCore* core) { delete core; }
RIPStatus rip_core_add_anchor(RIPCore* core, RIPAnchor anchor) {
    return mutate(core, [&](RIPCore& value) { return value.addAnchor(anchor); });
}
RIPStatus rip_core_push_imu(RIPCore* core, RIPIMUSample sample) {
    return mutate(core, [&](RIPCore& value) { return value.pushIMU(sample); });
}
RIPStatus rip_core_push_frame(RIPCore* core, RIPFrame frame) {
    return mutate(core, [&](RIPCore& value) { return value.pushFrame(frame); });
}
RIPStatus rip_core_set_source(RIPCore* core, uint32_t source, uint32_t state) {
    return mutate(core, [&](RIPCore& value) { return value.setSource(source, state); });
}
RIPStatus rip_core_finish(RIPCore* core) { return mutate(core, [](RIPCore& value) { return value.finish(); }); }
RIPStatus rip_core_cancel(RIPCore* core) { return mutate(core, [](RIPCore& value) { return value.cancel(); }); }
RIPStatus rip_core_pop_output(RIPCore* core, RIPOutput* output) {
    if (!core || !output) return RIP_INVALID_ARGUMENT;
    if (!core->hasOutput()) return RIP_EMPTY;
    *output = core->outputs[core->outputIndex++];
    if (!core->hasOutput()) { core->outputs.clear(); core->outputIndex = 0; }
    return RIP_OK;
}
RIPStatus rip_core_metrics(const RIPCore* core, RIPMetrics* metrics) {
    if (!core || !metrics) return RIP_INVALID_ARGUMENT;
    *metrics = core->snapshot();
    return RIP_OK;
}
RIPStatus rip_core_clock_info(const RIPCore* core, RIPClockInfo* info) {
    if (!core || !info) return RIP_INVALID_ARGUMENT;
    *info = core->clock;
    return RIP_OK;
}
RIPStatus rip_core_map_time(const RIPCore* core, int64_t device_ns, int64_t* reference_ns) {
    if (!core || !reference_ns) return RIP_INVALID_ARGUMENT;
    int64_t mapped = 0;
    const RIPStatus status = core->map(device_ns, mapped);
    if (status == RIP_OK) *reference_ns = mapped;
    return status;
}
} // extern "C"
