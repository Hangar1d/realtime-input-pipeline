#include "PipelineCore.h"

#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
int checks = 0;
#define CHECK(expression) do { ++checks; if (!(expression)) throw std::runtime_error( \
    std::string(__func__) + ":" + std::to_string(__LINE__) + ": " #expression); } while (false)

bool near(double a, double b, double tolerance = 1e-8) { return std::abs(a - b) <= tolerance; }

RIPConfig configuration() {
    RIPConfig c = rip_default_config();
    c.anchor_capacity = 8; c.min_anchors = 2; c.min_anchor_span_ns = 1;
    c.max_query_distance_ns = 100000000; c.max_anchor_residual_ns = 10;
    c.min_inlier_fraction = 0.6; c.max_drift_ppm = 10000;
    c.reorder_capacity = 32; c.history_capacity = 8; c.pending_frame_capacity = 8;
    c.dedup_capacity = 32; c.lateness_ns = 0; c.max_interpolation_gap_ns = 200;
    return c;
}

struct Core {
    RIPCore* value = nullptr;
    std::vector<RIPOutput> output;
    explicit Core(RIPConfig config = configuration()) {
        RIPStatus status = RIP_INTERNAL_ERROR;
        value = rip_core_create(config, &status);
        CHECK(value != nullptr); CHECK(status == RIP_OK);
    }
    ~Core() { rip_core_destroy(value); }
    Core(const Core&) = delete;
    Core& operator=(const Core&) = delete;
    void drain() {
        RIPOutput result{};
        RIPStatus status;
        while ((status = rip_core_pop_output(value, &result)) == RIP_OK) output.push_back(result);
        CHECK(status == RIP_EMPTY);
    }
    RIPMetrics metrics() const {
        RIPMetrics result{}; CHECK(rip_core_metrics(value, &result) == RIP_OK); return result;
    }
    RIPClockInfo clock() const {
        RIPClockInfo result{}; CHECK(rip_core_clock_info(value, &result) == RIP_OK); return result;
    }
    void seed() {
        CHECK(rip_core_add_anchor(value, {1, 0, 0}) == RIP_OK);
        CHECK(rip_core_add_anchor(value, {2, 100, 100}) == RIP_OK);
        CHECK(clock().state == RIP_CLOCK_READY);
    }
    void imu(uint64_t sequence, int64_t time, double x = 0, double y = 0, double z = 0) {
        CHECK(rip_core_push_imu(value, {sequence, time, x, y, z}) == RIP_OK); drain();
    }
    void frame(uint64_t sequence, int64_t time) {
        CHECK(rip_core_push_frame(value, {sequence, time}) == RIP_OK); drain();
    }
    void source(uint32_t source, uint32_t state) {
        CHECK(rip_core_set_source(value, source, state) == RIP_OK); drain();
    }
    void finish() { CHECK(rip_core_finish(value) == RIP_OK); drain(); conservation(); }
    void conservation() const {
        const RIPMetrics m = metrics();
        CHECK(m.queue_occupancy == 0); CHECK(m.pending_occupancy == 0);
        CHECK(m.frames_accepted == m.outputs + m.frames_discarded_reset + m.frames_discarded_cancel);
        CHECK(m.outputs == output.size());
    }
};

void defaultsAndValidation() {
    const RIPConfig defaults = rip_default_config();
    CHECK(defaults.anchor_capacity == 17); CHECK(defaults.min_anchors == 5);
    std::vector<RIPConfig> invalid;
    auto change = [&](auto edit) { RIPConfig c = configuration(); edit(c); invalid.push_back(c); };
    change([](RIPConfig& c) { c.anchor_capacity = 65; });
    change([](RIPConfig& c) { c.min_anchors = 1; });
    change([](RIPConfig& c) { c.min_anchors = 9; });
    change([](RIPConfig& c) { c.min_anchor_span_ns = 0; });
    change([](RIPConfig& c) { c.min_anchor_span_ns = INT64_MAX; });
    change([](RIPConfig& c) { c.max_query_distance_ns = INT64_MAX; });
    change([](RIPConfig& c) { c.max_drift_ppm = std::numeric_limits<double>::quiet_NaN(); });
    change([](RIPConfig& c) { c.max_drift_ppm = 1000000; });
    change([](RIPConfig& c) { c.max_anchor_residual_ns = -1; });
    change([](RIPConfig& c) { c.min_inlier_fraction = 0; });
    change([](RIPConfig& c) { c.min_inlier_fraction = 1.01; });
    change([](RIPConfig& c) { c.reorder_capacity = 0; });
    change([](RIPConfig& c) { c.history_capacity = 1; });
    change([](RIPConfig& c) { c.pending_frame_capacity = 0; });
    change([](RIPConfig& c) { c.dedup_capacity = 0; });
    change([](RIPConfig& c) { c.lateness_ns = -1; });
    change([](RIPConfig& c) { c.max_interpolation_gap_ns = 0; });
    for (const auto& c : invalid) {
        RIPStatus status = RIP_OK;
        CHECK(rip_core_create(c, &status) == nullptr); CHECK(status == RIP_INVALID_ARGUMENT);
        CHECK(rip_core_create(c, nullptr) == nullptr);
    }
    RIPConfig copy = configuration(); Core core(copy);
    copy.anchor_capacity = 0; copy.min_anchors = 100;
    core.seed();
}

void nullAndCopyBoundary() {
    RIPMetrics m{}; RIPClockInfo info{}; RIPOutput out{}; int64_t mapped = 99;
    CHECK(rip_core_add_anchor(nullptr, {}) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_push_imu(nullptr, {}) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_push_frame(nullptr, {}) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_set_source(nullptr, 0, 0) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_finish(nullptr) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_cancel(nullptr) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_pop_output(nullptr, &out) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_metrics(nullptr, &m) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_clock_info(nullptr, &info) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_map_time(nullptr, 0, &mapped) == RIP_INVALID_ARGUMENT);
    rip_core_destroy(nullptr);
    Core core; core.seed();
    CHECK(rip_core_pop_output(core.value, nullptr) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_metrics(core.value, nullptr) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_clock_info(core.value, nullptr) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_map_time(core.value, 0, nullptr) == RIP_INVALID_ARGUMENT);
    RIPIMUSample sample{1, 10, 4, 5, 6};
    CHECK(rip_core_push_imu(core.value, sample) == RIP_OK);
    sample.x = 999; sample.device_ns = 999;
    RIPFrame frame{1, 10}; CHECK(rip_core_push_frame(core.value, frame) == RIP_OK);
    frame.reference_ns = 999;
    core.finish(); CHECK(core.output.size() == 1);
    CHECK(core.output[0].x == 4); CHECK(core.output[0].reference_ns == 10);
    CHECK(core.output[0].left_device_ns == 10);
}

void fitMedianAndOutliers() {
    RIPConfig c = configuration(); c.anchor_capacity = 4; c.min_anchors = 3;
    c.max_anchor_residual_ns = 100; c.max_query_distance_ns = 10000000;
    Core all(c);
    for (uint64_t i = 0; i < 4; ++i)
        CHECK(rip_core_add_anchor(all.value, {i, static_cast<int64_t>(i * 1000000),
            static_cast<int64_t>(i * 1000000 + (i == 3 ? 6 : 0))}) == RIP_OK);
    const auto first = all.clock();
    CHECK(first.state == RIP_CLOCK_READY); CHECK(near(first.slope, 1.000001, 1e-12));
    CHECK(near(first.local_offset_ns, 1.5)); CHECK(first.inliers == 4);
    int64_t mapped = -1;
    CHECK(rip_core_map_time(all.value, 1500000, &mapped) == RIP_OK); CHECK(mapped == 1500001);
    c.max_anchor_residual_ns = 2;
    Core robust(c);
    for (uint64_t i = 0; i < 4; ++i)
        CHECK(rip_core_add_anchor(robust.value, {i, static_cast<int64_t>(i * 1000000),
            static_cast<int64_t>(i * 1000000 + (i == 3 ? 6 : 0))}) == RIP_OK);
    const auto fitted = robust.clock();
    CHECK(fitted.state == RIP_CLOCK_READY); CHECK(fitted.inliers == 3);
    CHECK(fitted.slope == 1); CHECK(fitted.local_offset_ns == 0);
    CHECK(fitted.support_min_ns == 0); CHECK(fitted.support_max_ns == 2000000);
    CHECK(fitted.residual_max_ns == 0); CHECK(fitted.residual_rms_ns == 0);
    CHECK(rip_core_add_anchor(robust.value, {4, 4000000, 4000000}) == RIP_OK);
    CHECK(robust.clock().anchors == 4); // Arrival-ordered window evicts the first anchor.
}

void anchorFailuresAndEpochs() {
    Core core;
    CHECK(rip_core_add_anchor(core.value, {1, -1, 0}) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_add_anchor(core.value, {1, 10, 10}) == RIP_OK);
    CHECK(core.clock().state == RIP_CLOCK_INSUFFICIENT);
    CHECK(rip_core_add_anchor(core.value, {1, 10, 10}) == RIP_DUPLICATE);
    CHECK(rip_core_add_anchor(core.value, {1, 20, 20}) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_add_anchor(core.value, {2, 10, 10}) == RIP_DUPLICATE);
    CHECK(rip_core_add_anchor(core.value, {2, 20, 10}) == RIP_OK); // Equal host coordinate is fit evidence.
    CHECK(core.clock().state == RIP_CLOCK_INVALID);
    int64_t mapped = 123;
    CHECK(rip_core_map_time(core.value, 20, &mapped) == RIP_UNCALIBRATED); CHECK(mapped == 123);
    CHECK(rip_core_add_anchor(core.value, {3, 30, 30}) == RIP_OK);
    const uint64_t epoch = core.clock().epoch;
    CHECK(rip_core_add_anchor(core.value, {4, 25, 25}) == RIP_DISCONTINUITY);
    CHECK(core.clock().epoch == epoch + 1); CHECK(core.clock().anchors == 1);
    CHECK(core.clock().state == RIP_CLOCK_INSUFFICIENT);
    CHECK(core.metrics().anchor_duplicates == 2); CHECK(core.metrics().clock_discontinuities == 1);
    CHECK(core.metrics().anchor_invalid == 2);

    Core buffered; buffered.seed(); buffered.frame(1, 10); buffered.imu(1, 20);
    // A fresh sequence restarting at a retained old device coordinate is a reset, not a duplicate.
    CHECK(rip_core_add_anchor(buffered.value, {3, 0, 200}) == RIP_DISCONTINUITY);
    auto m = buffered.metrics(); CHECK(m.frames_discarded_reset == 1); CHECK(m.events_discarded_reset == 2);
    CHECK(m.queue_occupancy == 0); CHECK(m.watermark_ns == 0);
    CHECK(buffered.clock().epoch == 2); CHECK(buffered.clock().anchors == 1);
    CHECK(rip_core_map_time(buffered.value, 20, &mapped) == RIP_UNCALIBRATED);
    CHECK(rip_core_cancel(buffered.value) == RIP_OK); buffered.drain(); buffered.conservation();

    Core sameDevice; sameDevice.seed();
    CHECK(rip_core_add_anchor(sameDevice.value, {3, 100, 200}) == RIP_DISCONTINUITY);
    CHECK(sameDevice.clock().epoch == 2); CHECK(sameDevice.clock().state == RIP_CLOCK_INSUFFICIENT);
}

void ppmRoundingAndRange() {
    for (const auto& item : std::vector<std::pair<int64_t, bool>>{
        {1000999, true}, {1001000, true}, {1001001, false}, {999000, true}, {998999, false}}) {
        RIPConfig c = configuration(); c.max_drift_ppm = 1000;
        Core core(c);
        CHECK(rip_core_add_anchor(core.value, {1, 0, 0}) == RIP_OK);
        CHECK(rip_core_add_anchor(core.value, {2, 1000000, item.first}) == RIP_OK);
        CHECK((core.clock().state == RIP_CLOCK_READY) == item.second);
    }
    RIPConfig c = configuration(); c.max_drift_ppm = 600000;
    Core ties(c);
    CHECK(rip_core_add_anchor(ties.value, {1, 100, 200}) == RIP_OK);
    CHECK(rip_core_add_anchor(ties.value, {2, 102, 203}) == RIP_OK);
    int64_t result = 0;
    CHECK(rip_core_map_time(ties.value, 101, &result) == RIP_OK); CHECK(result == 201);
    CHECK(rip_core_map_time(ties.value, 103, &result) == RIP_OK); CHECK(result == 205);

    c = configuration(); c.max_query_distance_ns = 1000;
    Core extreme(c);
    const int64_t x0 = INT64_MAX - 1000, y0 = INT64_MAX - 500;
    for (uint64_t i = 0; i < 3; ++i)
        CHECK(rip_core_add_anchor(extreme.value, {i, x0 + static_cast<int64_t>(100 * i),
            y0 + static_cast<int64_t>(100 * i)}) == RIP_OK);
    CHECK(rip_core_map_time(extreme.value, x0 + 150, &result) == RIP_OK);
    CHECK(result == INT64_C(9223372036854775457));
    CHECK(rip_core_map_time(extreme.value, INT64_MAX, &result) == RIP_CLOCK_RANGE);
    CHECK(rip_core_map_time(extreme.value, 0, &result) == RIP_CLOCK_RANGE);
    CHECK(rip_core_map_time(extreme.value, -1, &result) == RIP_INVALID_ARGUMENT);
    Core wide;
    CHECK(rip_core_add_anchor(wide.value, {1, 0, 0}) == RIP_OK);
    CHECK(rip_core_add_anchor(wide.value, {2, INT64_MAX, INT64_MAX}) == RIP_OK);
    CHECK(wide.clock().state == RIP_CLOCK_INVALID);
}

void residualGateWithDrift() {
    // Exact rational slope is 1 +/- 1/1,000,000. Integer anchors need no
    // floating reference: at 2.5 seconds the exact prediction is +/-2500 ns.
    for (const int64_t drift : {-1000, 1000}) {
        for (const bool zeroGate : {false, true}) {
            RIPConfig c = rip_default_config();
            if (zeroGate) c.max_anchor_residual_ns = 0;
            Core core(c);
            for (int64_t i = 0; i < 5; ++i) {
                const int64_t noise = !zeroGate && i == 4 ? 100000 : 0;
                CHECK(rip_core_add_anchor(core.value, {static_cast<uint64_t>(i + 1),
                    i * 1000000000, i * (1000000000 + drift) + noise}) == RIP_OK);
            }
            const auto info = core.clock();
            CHECK(info.state == RIP_CLOCK_READY); CHECK(info.inliers == 5);
            CHECK(near(info.slope, 1 + static_cast<double>(drift) / 1000000000.0, 1e-15));
            int64_t mapped = -1;
            CHECK(rip_core_map_time(core.value, 2500000000, &mapped) == RIP_OK);
            CHECK(mapped == 2500000000 + drift * 5 / 2);
        }
        RIPConfig c = rip_default_config(); Core outside(c);
        for (int64_t i = 0; i < 5; ++i)
            CHECK(rip_core_add_anchor(outside.value, {static_cast<uint64_t>(i + 1),
                i * 1000000000, i * (1000000000 + drift) + (i == 4 ? 100001 : 0)}) == RIP_OK);
        CHECK(outside.clock().state == RIP_CLOCK_OUTLIERS); CHECK(outside.clock().inliers == 4);
        int64_t mapped = 99;
        CHECK(rip_core_map_time(outside.value, 2500000000, &mapped) == RIP_UNCALIBRATED);
        CHECK(mapped == 99);
    }
}

void residualGateNearPrecisionLimit() {
    constexpr int64_t end = INT64_C(9007180000000000);
    const std::vector<int64_t> devices{0, 1000000, 2000000, end - 1000000, end};
    for (const int64_t direction : {-1, 1}) {
        for (const int64_t noise : {0, 1, 100}) {
            RIPConfig c = rip_default_config(); c.max_anchor_residual_ns = 0;
            c.max_query_distance_ns = INT64_C(9007199254740991);
            Core core(c);
            for (size_t i = 0; i < devices.size(); ++i) {
                const int64_t x = devices[i];
                CHECK(rip_core_add_anchor(core.value, {i + 1, x,
                    x + direction * (x / 1000000) + (i == 4 ? noise : 0)}) == RIP_OK);
            }
            const auto info = core.clock();
            if (noise < 100) {
                // One ns outside a zero physical gate is deliberately ambiguous
                // at this span. Interval overlap admits it; 100 ns is excluded.
                CHECK(info.state == RIP_CLOCK_READY); CHECK(info.inliers == 5);
                int64_t mapped = -1;
                CHECK(rip_core_map_time(core.value, end, &mapped) == RIP_OK);
                const int64_t exact = end + direction * (end / 1000000);
                // For this +/-1 ppm line: dx*Bs < 4.01 ns, Bb < 4.01 ns,
                // FMA ULP <= 1 ns, and both integer roundings add <= 1 ns.
                CHECK(std::abs(mapped - exact) <= 12);
            } else {
                CHECK(info.state == RIP_CLOCK_OUTLIERS); CHECK(info.inliers == 4);
                int64_t mapped = 99;
                CHECK(rip_core_map_time(core.value, end, &mapped) == RIP_UNCALIBRATED);
                CHECK(mapped == 99);
            }
        }
    }
    for (const bool deviceTooWide : {false, true}) {
        RIPConfig c = configuration(); Core core(c);
        CHECK(rip_core_add_anchor(core.value, {1, 0, 0}) == RIP_OK);
        const int64_t limit = INT64_C(9007199254740992);
        CHECK(rip_core_add_anchor(core.value, {2, limit + (deviceTooWide ? 1 : 0), limit + 1}) == RIP_OK);
        CHECK(core.clock().state == RIP_CLOCK_INVALID);
        int64_t mapped = 99;
        CHECK(rip_core_map_time(core.value, 0, &mapped) == RIP_UNCALIBRATED); CHECK(mapped == 99);
    }
    RIPConfig c = configuration(); Core boundary(c);
    CHECK(rip_core_add_anchor(boundary.value, {1, 0, 0}) == RIP_OK);
    CHECK(rip_core_add_anchor(boundary.value,
        {2, INT64_C(9007199254740992), INT64_C(9007199254740992)}) == RIP_OK);
    CHECK(boundary.clock().state == RIP_CLOCK_READY);
    int64_t mapped = -1;
    CHECK(rip_core_map_time(boundary.value, INT64_C(9007199254740992), &mapped) == RIP_OK);
    CHECK(mapped == INT64_C(9007199254740992));
}

void finalFitDriftPolicy() {
    RIPConfig c = rip_default_config(); Core core(c);
    const int64_t noise[]{0, 700000, 0, 0, 0, -380000, 0, 0, -480000};
    for (int64_t i = 0; i < 9; ++i)
        CHECK(rip_core_add_anchor(core.value, {static_cast<uint64_t>(i + 1),
            (i + 1) * 1000000000, (i + 1) * 995010000 + noise[i]}) == RIP_OK);
    const auto info = core.clock();
    CHECK(info.state == RIP_CLOCK_READY); CHECK(info.inliers == 6);
    CHECK(near(info.slope, 0.99501, 1e-15)); CHECK(near(info.drift_ppm, -4990, 1e-8));
    CHECK(info.support_min_ns == 1000000000); CHECK(info.support_max_ns == 8000000000);
    int64_t mapped = -1;
    CHECK(rip_core_map_time(core.value, 5000000000, &mapped) == RIP_OK); CHECK(mapped == 4975050000);
    Core finalOutside(c), nonpositive(c), degenerate(c);
    for (int64_t i = 0; i < 5; ++i) {
        const auto sequence = static_cast<uint64_t>(i + 1);
        CHECK(rip_core_add_anchor(finalOutside.value, {sequence, i * 1000000000, i * 1005001000}) == RIP_OK);
        CHECK(rip_core_add_anchor(nonpositive.value, {sequence, i * 1000000000, 0}) == RIP_OK);
        CHECK(rip_core_add_anchor(degenerate.value, {sequence, i * 100, i * 100}) == RIP_OK);
    }
    CHECK(finalOutside.clock().state == RIP_CLOCK_INVALID);
    CHECK(nonpositive.clock().state == RIP_CLOCK_INVALID);
    CHECK(degenerate.clock().state == RIP_CLOCK_DEGENERATE);
    CHECK(rip_core_add_anchor(core.value, {10, -1, 0}) == RIP_INVALID_ARGUMENT);
    CHECK(core.clock().state == RIP_CLOCK_READY);
}

void unsupportedRoundingMode() {
    struct RestoreRounding {
        int mode = std::fegetround();
        ~RestoreRounding() { if (mode != -1) std::fesetround(mode); }
    } restore;
    CHECK(restore.mode == FE_TONEAREST);
    Core core; core.seed();
    CHECK(std::fesetround(FE_UPWARD) == 0);
    int64_t mapped = 99;
    CHECK(rip_core_map_time(core.value, 50, &mapped) == RIP_CLOCK_RANGE); CHECK(mapped == 99);
    CHECK(rip_core_add_anchor(core.value, {3, 200, 200}) == RIP_OK);
    CHECK(core.clock().state == RIP_CLOCK_INVALID);
    CHECK(std::fesetround(FE_TONEAREST) == 0);
    CHECK(rip_core_add_anchor(core.value, {4, 300, 300}) == RIP_OK);
    CHECK(core.clock().state == RIP_CLOCK_READY);
    CHECK(rip_core_map_time(core.value, 50, &mapped) == RIP_OK); CHECK(mapped == 50);
}

void vectorInterpolationAndRevision() {
    Core core; core.seed();
    core.imu(1, 1000, 1, -2, 4); core.imu(2, 1004, 5, 6, 0);
    for (uint64_t i = 0; i <= 4; ++i) core.frame(i + 1, 1000 + static_cast<int64_t>(i));
    core.finish(); CHECK(core.output.size() == 5);
    for (size_t i = 0; i < core.output.size(); ++i) {
        const auto& o = core.output[i]; CHECK(o.available == 1);
        CHECK(near(o.x, 1 + static_cast<double>(i)));
        CHECK(near(o.y, -2 + 2 * static_cast<double>(i)));
        CHECK(near(o.z, 4 - static_cast<double>(i)));
        CHECK(o.quality == (i == 0 || i == 4 ? RIP_QUALITY_EXACT : RIP_QUALITY_INTERPOLATED));
    }
    Core revisions; revisions.seed();
    revisions.imu(1, 10, 0);
    CHECK(rip_core_add_anchor(revisions.value, {3, 200, 201}) == RIP_OK);
    revisions.imu(2, 110, 101); revisions.frame(1, 60); revisions.finish();
    CHECK(revisions.output.size() == 1); CHECK(revisions.output[0].left_clock_revision == 1);
    CHECK(revisions.output[0].right_clock_revision == 2); CHECK(near(revisions.output[0].x, 50));
    CHECK(revisions.output[0].left_normalized_ns == 10); CHECK(revisions.output[0].right_normalized_ns == 111);

    Core finite; finite.seed(); finite.imu(1, 100, -1e308, 1e308, 1e308);
    finite.imu(2, 104, 1e308, -1e308, 1e308); finite.frame(1, 102); finite.finish();
    CHECK(finite.output[0].x == 0); CHECK(finite.output[0].y == 0);
    CHECK(finite.output[0].z == 1e308); CHECK(std::isfinite(finite.output[0].z));
}

void strictWatermarkAndIdle() {
    RIPConfig c = configuration(); c.lateness_ns = 10;
    Core core(c); core.seed(); core.source(RIP_SOURCE_CAMERA, RIP_SOURCE_IDLE);
    core.imu(1, 100); core.imu(2, 95); core.imu(3, 111);
    auto m = core.metrics(); CHECK(m.watermark_ns == 101); CHECK(m.history_occupancy == 2);
    core.imu(4, 101); CHECK(core.metrics().queue_occupancy == 2);
    CHECK(rip_core_push_imu(core.value, {5, 100, 0, 0, 0}) == RIP_LATE);
    core.source(RIP_SOURCE_IMU, RIP_SOURCE_IDLE);
    CHECK(core.metrics().watermark_ns == 101); CHECK(core.metrics().terminal == 0);
    CHECK(rip_core_push_imu(core.value, {6, 120, 0, 0, 0}) == RIP_SOURCE_INACTIVE);
    core.source(RIP_SOURCE_IMU, RIP_SOURCE_ACTIVE);
    CHECK(core.metrics().watermark_ns == 101);
    core.source(RIP_SOURCE_IMU, RIP_SOURCE_STOPPED);
    CHECK(core.metrics().terminal == 0); CHECK(core.metrics().queue_occupancy == 2);
    CHECK(rip_core_set_source(core.value, RIP_SOURCE_IMU, RIP_SOURCE_ACTIVE) == RIP_SOURCE_INACTIVE);
    core.source(RIP_SOURCE_CAMERA, RIP_SOURCE_STOPPED);
    CHECK(core.metrics().terminal == 1); CHECK(core.metrics().queue_occupancy == 0);

    Core unseen; unseen.seed(); unseen.imu(1, 100);
    CHECK(unseen.metrics().watermark_ns == 0); CHECK(unseen.metrics().history_occupancy == 0);
    unseen.source(RIP_SOURCE_CAMERA, RIP_SOURCE_STOPPED);
    CHECK(unseen.metrics().watermark_ns == 100); CHECK(unseen.metrics().queue_occupancy == 1);
    unseen.imu(2, 101); CHECK(unseen.metrics().history_occupancy == 1); unseen.finish();
}

void capacityProgressAndDedup() {
    RIPConfig c = configuration(); c.reorder_capacity = 2;
    Core core(c); core.seed(); core.imu(1, 10); core.imu(2, 20);
    CHECK(rip_core_push_imu(core.value, {3, 30, 3, 0, 0}) == RIP_CAPACITY);
    CHECK(core.metrics().queue_occupancy == 2); core.frame(1, 30);
    CHECK(core.metrics().watermark_ns == 30); CHECK(core.metrics().history_occupancy == 2);
    core.imu(3, 30, 3); core.finish(); CHECK(core.output[0].quality == RIP_QUALITY_EXACT);
    CHECK(core.output[0].x == 3); CHECK(core.metrics().rejected_capacity == 1);
    CHECK(core.metrics().queue_high_water == 2);

    c = configuration(); c.dedup_capacity = 3; c.lateness_ns = 100;
    Core dedup(c); dedup.seed(); dedup.source(RIP_SOURCE_CAMERA, RIP_SOURCE_IDLE);
    dedup.imu(10, 10); dedup.imu(12, 12); dedup.imu(11, 11);
    CHECK(rip_core_push_imu(dedup.value, {10, 10, 0, 0, 0}) == RIP_DUPLICATE);
    CHECK(rip_core_push_imu(dedup.value, {9, 9, 0, 0, 0}) == RIP_STALE_SEQUENCE);
    dedup.imu(13, 13);
    CHECK(rip_core_push_imu(dedup.value, {10, 10, 0, 0, 0}) == RIP_STALE_SEQUENCE);
    dedup.finish();

    Core duplicate; duplicate.seed(); duplicate.imu(2, 100, 2); duplicate.imu(1, 100, 1);
    duplicate.frame(1, 100); duplicate.finish();
    CHECK(duplicate.output[0].x == 1); CHECK(duplicate.output[0].left_sequence == 1);
    CHECK(duplicate.metrics().duplicate_timestamp == 1);
}

void pendingGapAndHistory() {
    RIPConfig c = configuration(); c.pending_frame_capacity = 1; c.max_interpolation_gap_ns = 500;
    Core pending(c); pending.seed(); pending.imu(1, 10, 10);
    pending.frame(1, 20); pending.frame(2, 30); pending.frame(3, 100); pending.imu(2, 100, 100);
    CHECK(pending.metrics().pending_occupancy == 1); CHECK(pending.metrics().pending_overflow == 1);
    CHECK(pending.output.size() == 1); CHECK(pending.output[0].quality == RIP_QUALITY_PENDING_OVERFLOW);
    pending.finish(); CHECK(pending.metrics().pending_high_water == 1);
    CHECK(pending.metrics().interpolated_outputs == 1); CHECK(pending.metrics().exact_outputs == 1);

    c = configuration(); c.max_interpolation_gap_ns = 20;
    Core gap(c); gap.seed(); gap.imu(1, 10); gap.imu(2, 40); gap.frame(1, 20); gap.finish();
    CHECK(gap.output[0].quality == RIP_QUALITY_GAP_TOO_LARGE);
    CHECK(gap.output[0].has_left == 1); CHECK(gap.output[0].has_right == 1);
    CHECK(gap.output[0].available == 0);

    Core missing; missing.seed(); missing.frame(1, 5); missing.imu(1, 10); missing.frame(2, 20); missing.finish();
    CHECK(missing.output.size() == 2); CHECK(missing.output[0].quality == RIP_QUALITY_MISSING_LEFT);
    CHECK(missing.output[1].quality == RIP_QUALITY_MISSING_RIGHT);

    c = configuration(); c.max_interpolation_gap_ns = 50;
    Core deadline(c); deadline.seed(); deadline.imu(1, 10); deadline.frame(1, 20);
    deadline.frame(2, 100); deadline.imu(2, 100);
    CHECK(deadline.output.size() == 1); CHECK(deadline.output[0].quality == RIP_QUALITY_MISSING_RIGHT);
    CHECK(deadline.metrics().pending_occupancy == 0); deadline.finish();

    c = configuration(); c.history_capacity = 2;
    Core retained(c); retained.seed(); retained.source(RIP_SOURCE_CAMERA, RIP_SOURCE_IDLE);
    for (uint64_t i = 1; i <= 6; ++i) retained.imu(i, static_cast<int64_t>(10 * i));
    CHECK(retained.metrics().history_occupancy == 2); CHECK(retained.metrics().history_evicted == 3);
    retained.finish(); CHECK(retained.metrics().history_evicted == 4);
    CHECK(retained.metrics().history_occupancy == 2);

    Core bracket(c); bracket.seed(); bracket.imu(1, 10, 10); bracket.imu(2, 20, 20);
    bracket.frame(1, 25); bracket.frame(2, 40); bracket.imu(3, 30, 30); bracket.imu(4, 40, 40);
    bracket.finish(); CHECK(bracket.metrics().history_evicted == 2);
    CHECK(bracket.metrics().interpolated_outputs == 1); CHECK(bracket.metrics().exact_outputs == 1);
    CHECK(bracket.output[0].available == 1); CHECK(bracket.output[0].x == 25);
}

void stoppedIMUWithQueuedSuccessor() {
    Core core; core.seed(); core.imu(1, 10, 10); core.imu(2, 100, 100);
    core.frame(1, 20); core.frame(2, 50);
    CHECK(core.metrics().pending_occupancy == 1); CHECK(core.output.empty());
    core.source(RIP_SOURCE_IMU, RIP_SOURCE_STOPPED);
    CHECK(core.metrics().pending_occupancy == 1); CHECK(core.output.empty());
    CHECK(core.metrics().terminal == 0);
    core.frame(3, 200);
    CHECK(core.output.size() == 2); CHECK(core.output[0].quality == RIP_QUALITY_INTERPOLATED);
    CHECK(core.output[1].quality == RIP_QUALITY_INTERPOLATED);
    CHECK(core.output[0].x == 20); CHECK(core.output[1].x == 50);
    core.finish(); CHECK(core.output.back().quality == RIP_QUALITY_MISSING_RIGHT);
}

void outputBackpressureCancelAndMalformed() {
    Core pending; pending.seed(); pending.imu(1, 10); pending.frame(1, 10);
    CHECK(rip_core_finish(pending.value) == RIP_OK);
    CHECK(rip_core_push_frame(pending.value, {2, 20}) == RIP_OUTPUT_PENDING);
    CHECK(rip_core_add_anchor(pending.value, {3, 200, 200}) == RIP_OUTPUT_PENDING);
    CHECK(rip_core_finish(pending.value) == RIP_OUTPUT_PENDING);
    pending.drain(); pending.conservation(); CHECK(pending.metrics().rejected_output_pending == 3);
    CHECK(rip_core_push_frame(pending.value, {2, 20}) == RIP_FINISHED);

    Core cancel; cancel.seed(); cancel.imu(1, 10); cancel.frame(1, 20); cancel.frame(2, 100); cancel.imu(2, 100);
    CHECK(cancel.metrics().pending_occupancy == 1);
    CHECK(rip_core_cancel(cancel.value) == RIP_OK); cancel.drain(); cancel.conservation();
    CHECK(cancel.metrics().frames_discarded_cancel == 2); CHECK(cancel.metrics().terminal == 1);

    Core preserve; preserve.seed(); preserve.imu(1, 10); preserve.frame(1, 10);
    CHECK(rip_core_push_imu(preserve.value, {2, 20, 0, 0, 0}) == RIP_OK);
    CHECK(rip_core_push_frame(preserve.value, {2, 30}) == RIP_OK);
    CHECK(preserve.metrics().output_occupancy == 1);
    CHECK(rip_core_cancel(preserve.value) == RIP_OK); preserve.drain(); preserve.conservation();
    CHECK(preserve.metrics().outputs == 1); CHECK(preserve.metrics().frames_discarded_cancel == 1);

    Core malformed;
    CHECK(rip_core_push_imu(malformed.value, {1, 0, 0, 0, 0}) == RIP_UNCALIBRATED);
    CHECK(rip_core_push_frame(malformed.value, {1, -1}) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_set_source(malformed.value, 2, RIP_SOURCE_ACTIVE) == RIP_INVALID_ARGUMENT);
    CHECK(rip_core_set_source(malformed.value, 0, 3) == RIP_INVALID_ARGUMENT);
    for (double value : {std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity(),
         -std::numeric_limits<double>::infinity()}) {
        CHECK(rip_core_push_imu(malformed.value, {2, 1, value, 0, 0}) == RIP_INVALID_ARGUMENT);
        CHECK(rip_core_push_imu(malformed.value, {2, 1, 0, value, 0}) == RIP_INVALID_ARGUMENT);
        CHECK(rip_core_push_imu(malformed.value, {2, 1, 0, 0, value}) == RIP_INVALID_ARGUMENT);
    }
    malformed.frame(1, 0); malformed.finish();
    CHECK(malformed.output[0].quality == RIP_QUALITY_CLOCK_UNAVAILABLE);
    CHECK(malformed.metrics().rejected_invalid == 12); CHECK(malformed.metrics().rejected_uncalibrated == 1);
}

void deterministicReplayAndBounds() {
    struct Input { bool imu; uint64_t sequence; int64_t time; };
    std::vector<Input> original;
    for (uint64_t i = 0; i <= 10; ++i) original.push_back({true, i, static_cast<int64_t>(10 * i)});
    for (uint64_t i = 0; i < 10; ++i) original.push_back({false, i, static_cast<int64_t>(10 * i + 5)});
    for (uint32_t seed = 1; seed <= 10; ++seed) {
        RIPConfig c = configuration(); c.lateness_ns = 1000; c.history_capacity = 4;
        Core core(c); core.seed();
        std::vector<Input> input = original;
        uint32_t random = seed;
        for (size_t i = input.size() - 1; i > 0; --i) {
            random = random * 1664525U + 1013904223U;
            std::swap(input[i], input[random % (i + 1)]);
        }
        for (const auto& item : input) {
            if (item.imu) core.imu(item.sequence, item.time, static_cast<double>(item.time),
                -static_cast<double>(item.time), 2 * static_cast<double>(item.time));
            else core.frame(item.sequence, item.time);
        }
        core.finish(); CHECK(core.output.size() == 10);
        for (size_t i = 0; i < core.output.size(); ++i) {
            const auto& out = core.output[i]; const double time = static_cast<double>(10 * i + 5);
            CHECK(out.reference_ns == static_cast<int64_t>(time)); CHECK(out.quality == RIP_QUALITY_INTERPOLATED);
            CHECK(out.x == time); CHECK(out.y == -time); CHECK(out.z == 2 * time);
        }
    }

    RIPConfig c = configuration(); c.reorder_capacity = 4; c.history_capacity = 2;
    c.pending_frame_capacity = 2; c.dedup_capacity = 8; c.lateness_ns = 7;
    Core bounded(c); bounded.seed();
    uint32_t random = 12345;
    uint64_t imuSequence = 0, frameSequence = 0;
    for (int64_t i = 0; i < 1000; ++i) {
        random = random * 1664525U + 1013904223U;
        const int64_t jitter = static_cast<int64_t>((random >> 8) % 11) - 5;
        const int64_t time = std::max(INT64_C(0), i * 2 + jitter);
        RIPStatus status;
        if (random & 1U) status = rip_core_push_imu(bounded.value,
            {++imuSequence, time, static_cast<double>(time), 0, 0});
        else status = rip_core_push_frame(bounded.value, {++frameSequence, time});
        CHECK(status == RIP_OK || status == RIP_LATE || status == RIP_CAPACITY);
        bounded.drain();
        const auto m = bounded.metrics();
        CHECK(m.queue_occupancy <= 4); CHECK(m.history_occupancy <= 2); CHECK(m.pending_occupancy <= 2);
        CHECK(m.output_occupancy == 0); CHECK(m.faulted == 0);
    }
    bounded.finish(); CHECK(bounded.metrics().imu_received + bounded.metrics().frames_received == 1000);

    // Zero is a valid coordinate; a deadline addition beyond Int64 remains checked.
    Core zero; zero.seed(); zero.imu(1, 0, 7); zero.frame(1, 0); zero.finish();
    CHECK(zero.output[0].quality == RIP_QUALITY_EXACT); CHECK(zero.output[0].x == 7);
    Core deadline; deadline.seed(); deadline.imu(1, 100); deadline.frame(1, INT64_MAX); deadline.finish();
    CHECK(deadline.output[0].quality == RIP_QUALITY_MISSING_RIGHT);
    c = configuration(); c.min_anchor_span_ns = 1000;
    Core span(c);
    CHECK(rip_core_add_anchor(span.value, {1, 0, 0}) == RIP_OK);
    CHECK(rip_core_add_anchor(span.value, {2, 100, 100}) == RIP_OK);
    CHECK(span.clock().state == RIP_CLOCK_DEGENERATE);
}

void extremeConvexInterpolation() {
    const int64_t gap = INT64_C(9007199254740991);
    const double maximum = std::numeric_limits<double>::max();
    const double nearMaximum = 0x1.fffffffff02bep+1023;
    const std::vector<std::pair<double, double>> endpoints = {
        {maximum, maximum}, {nearMaximum, nearMaximum},
        {maximum, std::nextafter(maximum, 0)}, {std::nextafter(maximum, 0), maximum},
        {maximum * 0.75, maximum}, {maximum, maximum * 0.75},
        {-maximum, -maximum}, {-nearMaximum, -nearMaximum},
        {-maximum, -maximum * 0.75}, {-maximum * 0.75, -maximum}
    };
    for (const int64_t query : {INT64_C(1), INT64_C(2251799813685248),
         INT64_C(2909086626432658), gap / 2, gap - 1}) {
        for (const auto& pair : endpoints) {
            RIPConfig c = configuration(); c.max_interpolation_gap_ns = gap; c.max_query_distance_ns = gap;
            Core core(c); core.seed();
            core.imu(1, 0, pair.first, -pair.first, maximum);
            core.imu(2, gap, pair.second, -pair.second, -maximum);
            core.frame(1, query); core.finish();
            CHECK(core.output.size() == 1); const auto& out = core.output[0];
            CHECK(out.quality == RIP_QUALITY_INTERPOLATED); CHECK(out.available == 1);
            CHECK(std::isfinite(out.x)); CHECK(std::isfinite(out.y)); CHECK(std::isfinite(out.z));
            CHECK(out.x >= std::min(pair.first, pair.second)); CHECK(out.x <= std::max(pair.first, pair.second));
            CHECK(out.y >= std::min(-pair.first, -pair.second)); CHECK(out.y <= std::max(-pair.first, -pair.second));
            CHECK(out.z >= -maximum && out.z <= maximum);
            if (pair.first == pair.second) { CHECK(out.x == pair.first); CHECK(out.y == -pair.first); }
        }
    }
}

void stablePendingCompaction() {
    RIPConfig c = configuration(); c.max_interpolation_gap_ns = 50;
    Core core(c); core.seed(); core.imu(1, 10, 10); core.imu(2, 100, 100);
    for (const auto& frame : std::vector<std::pair<uint64_t, int64_t>>{{1,15},{2,25},{3,35},{4,45},{5,60}})
        core.frame(frame.first, frame.second);
    CHECK(core.output.empty()); CHECK(core.metrics().pending_occupancy == 4);
    // Advancing to 80 expires a prefix, while the three newer queries remain pending.
    core.frame(6, 80);
    CHECK(core.output.size() == 2); CHECK(core.metrics().pending_occupancy == 3);
    CHECK(core.output[0].frame_sequence == 1); CHECK(core.output[1].frame_sequence == 2);
    CHECK(core.output[0].quality == RIP_QUALITY_MISSING_RIGHT);
    CHECK(core.output[1].quality == RIP_QUALITY_MISSING_RIGHT);
    // The sealed successor resolves the retained suffix together, in its original order.
    core.finish(); CHECK(core.output.size() == 6);
    for (size_t i = 2; i < core.output.size(); ++i) {
        CHECK(core.output[i].frame_sequence == i + 1);
        CHECK(core.output[i].quality == RIP_QUALITY_GAP_TOO_LARGE);
    }
    CHECK(core.metrics().missing_right == 2); CHECK(core.metrics().gap_too_large == 4);
    CHECK(core.metrics().pending_occupancy == 0); CHECK(core.metrics().frames_accepted == 6);
}
} // namespace

int main() {
    const std::pair<const char*, void(*)()> tests[] = {
        {"defaults/configuration", defaultsAndValidation}, {"C ownership/nulls/copies", nullAndCopyBoundary},
        {"Theil-Sen/refit", fitMedianAndOutliers}, {"anchors/epochs", anchorFailuresAndEpochs},
        {"ppm/rounding/range", ppmRoundingAndRange}, {"vector/revisions", vectorInterpolationAndRevision},
        {"residual gate/drift", residualGateWithDrift}, {"residual gate/precision domain", residualGateNearPrecisionLimit},
        {"final fit/drift policy", finalFitDriftPolicy}, {"unsupported rounding mode", unsupportedRoundingMode},
        {"watermarks/idle/stop", strictWatermarkAndIdle}, {"capacity/dedup", capacityProgressAndDedup},
        {"pending/gap/history", pendingGapAndHistory}, {"stopped IMU successor", stoppedIMUWithQueuedSuccessor},
        {"backpressure/cancel/malformed", outputBackpressureCancelAndMalformed},
        {"deterministic replay/bounds", deterministicReplayAndBounds},
        {"extreme convex interpolation", extremeConvexInterpolation},
        {"stable pending compaction", stablePendingCompaction}
    };
    try {
        for (const auto& test : tests) { test.second(); std::cout << "PASS " << test.first << '\n'; }
        std::cout << "PASS " << checks << " assertions in " << (sizeof(tests) / sizeof(tests[0])) << " test groups\n";
        return EXIT_SUCCESS;
    } catch (const std::exception& error) {
        std::cerr << "FAIL " << error.what() << '\n'; return EXIT_FAILURE;
    }
}
