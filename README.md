# realtime-input-pipeline

Camera metadata and motion samples can use different clocks and arrive out of
order. Aligning them requires a clock model, a release policy, and explicit
handling of missing data. This Swift 6/C++17 component aligns finite three-axis
samples to frame timestamps with bounded storage, quality states, and provenance.
It does not estimate pose or orientation, process images, or provide hard
real-time scheduling.

[Architecture](#architecture) · [Build and run](#build-and-run) ·
[Reproducible example](#reproducible-example) · [Clock alignment](#clock-alignment) ·
[Ordering](#ordering-and-alignment) · [Lifecycle](#concurrency-and-lifecycle) ·
[Verification](#verification) · [Limitations](#limitations)

## Architecture

```text
copied frame/IMU values + trusted clock anchors
  → synchronous bounded Swift ingress → one consumer / worker actor
  → C facade → C++ clock mapping → watermark-ordered events
  → sealed IMU history + pending frames → aligned values / quality / provenance
  → bounded output stream + diagnostics
```

[TemporalPipeline](Sources/TemporalPipeline/Pipeline.swift) owns session lifetime,
admission, cancellation, and host timing. A private non-Sendable owner keeps the
native handle inside one worker actor. Each native call finishes before suspension.
The [C facade](Sources/PipelineCore/include/PipelineCore.h) copies fixed-size
requests/results, retains no caller pointers, makes no callbacks, and contains
C++ exceptions. Direct C callers must serialize each handle and drain all outputs
after every operation; otherwise the next operation returns `outputPending`.

The facade keeps mutable C++ ownership and containers out of the Swift API and
avoids requiring clients to enable direct C++ interoperability. It adds explicit
value/status conversion. The C++17 core owns no threads or platform resources;
independent handles share no mutable state. The optional camera adapter is a
separate library and is not required by the replay executable.

## Build and run

The Swift package requires macOS 15+, Swift 6, and the macOS SDK. The native core
builds independently with a C++17 compiler and CMake 3.18+. No third-party runtime
or test packages are required. Optional reference checks use Python 3.9+ and its
standard library.

```sh
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift run --skip-build input-pipeline demo
swift run --skip-build input-pipeline generate --frames 12 --output my-fixture.json
swift run --skip-build input-pipeline replay my-fixture.json --output diagnostics.json
```

Output paths must be new; writing multiple outputs is not a transaction. Input
files are limited to 8 MiB, 20,000 records, and 512 frames. `--help` lists commands.

### Fixtures and options

Schema 1 is a JSON object containing `schemaVersion: 1`, a nonempty `label` of at
most 128 UTF-8 bytes, optional `synthetic` generation metadata, and ordered `inputs`.
Replay consumes the array as recorded, without timer sleeps or implicit generation.
The loader validates schema, fields, types, coordinate/vector ranges, and counts.
Unknown keys and non-null values belonging to another record kind are rejected.

| Record `kind` | Required fields |
| --- | --- |
| `anchor` | `sequence`, `deviceNS`, `referenceNS`, `evidence: "trustedSameInstant"` |
| `imu` | `sequence`, `deviceNS`, finite `x`, `y`, `z` |
| `frame` | `sequence`, `referenceNS` |
| `source` | `source: "imu"/"camera"`, `state: "active"/"idle"/"stopped"` |

Sequences are UInt64 identities; timestamps are nonnegative Int64 nanoseconds.
Optional `arrivalReferenceNS` is delivery metadata, never calibration evidence.
A fixture represents one session; a detected clock discontinuity ends replay with
an error. Replacement clocks require a new session and fresh anchors.

| Synthetic option | Default | Range |
| --- | ---: | --- |
| `--frames` | 60 | 1…512; duration ≤30 s |
| `--camera-hz` / `--imu-hz` | 30 / 200 | finite 1…240 / 1…2000 |
| `--drift-ppm` | 120 | finite −5000…5000 |
| `--offset-ns` | 2000000000 | −10000000000…10000000000 |
| `--jitter-ns` | 2000000 | 0…100000000 |
| `--missing-every` | 17 | 0…10000; 0 disables omissions |
| `--reorder-depth` | 4 | 1…64 |
| `--anchor-outlier-ns` | 1000000 | 0…100000000 |
| `--seed` | 7 | UInt64 |

The generator uses independent device/reference coordinates and a fixed UInt64
linear-congruential sequence with rejection-mapped jitter. It sorts jittered
arrivals, then reverses count-bounded blocks; omitted samples retain sequence
gaps. Nine trusted anchors span eight seconds. Data starts 8.1 seconds after the
reference origin, with the signal `(t, 2t+1, -t)`. This is a reproducible workload,
not a statistical model of sensor noise.

Runtime `--lateness-ns` defaults to 20000000, range 0…1000000000;
`--max-gap-ns` defaults to 30000000, range 1…1000000000. The CLI explicitly chooses
a 30 ms gap; the native default is 50 ms. Runtime choices are recorded in output.

## Reproducible example

The default demo has 60 frames at 30 Hz, motion samples at 200 Hz, +120 ppm drift,
±2 ms arrival jitter, every 17th motion sample absent, four-record reversals, and
one +1 ms anchor outlier. Its deterministic summary is:

```text
frames=60/60 available=60 exact=19 interpolated=41
drift_ppm≈120 inliers=8/9
core_rejected_late=0 core_rejected_capacity=0 reorder_peak=15
ingress_accepted=443 ingress_dropped=0 output_dropped=0
```

Reproduce the checked-in 12-frame fixture and compare its canonical result:

```sh
swift run --skip-build input-pipeline replay Fixtures/reference.json --deterministic-output result-1.json
swift run --skip-build input-pipeline replay Fixtures/reference.json --deterministic-output result-2.json
cmake -E compare_files result-1.json result-2.json
cmake -E compare_files result-1.json Fixtures/reference.expected.json
```

That fixture has 94 inputs and yields 12 available frames: four exact and eight
interpolated. Offline replay uses one producer and a processing barrier, with a
bounded output budget covering its declared frame count. This avoids scheduling
races causing overload in the byte-comparison example; live admission remains
nonblocking and can reject inputs under pressure.

`--output` writes full diagnostics. Its `deterministic` section contains core
configuration, outputs/provenance, decision counters, clock information, and final
status. `--deterministic-output` writes only that section with sorted keys. Host
service/queue-wait durations and Swift queue peaks remain outside canonical bytes.
Identical ordered input/configuration on the same supported build must reproduce
those bytes; arbitrary concurrent arrival schedules or floating implementations
are not promised identical output.

## Clock alignment

An anchor pairs device and reference nanoseconds from the same instant. The host
must supply trustworthy evidence; receipt time is not a synchronization anchor.
Camera times already belong to the declared reference domain. IMU device ticks
are expressed in nominal nanoseconds. Vector units/axes are caller-defined and
must be consistent; components are interpolated without coordinate transforms.

A bounded arrival-ordered window uses centered Theil–Sen estimation: median pair
slopes, joint median intercept, residual-gated inliers, then exactly one inlier
refit. Even medians average their middle values. The preliminary slope must be
finite, positive, and numerically supported; **only the final refit must satisfy
the configured inclusive ppm limit**, with its one-ULP numerical guard. Minimum
count/span, inlier fraction, and final residual criteria also apply.

Defaults are 17 retained anchors, minimum five anchors over one second, 100 µs
physical residual gate, at least 60% inliers, ±5000 ppm, and a query horizon of
60 seconds from the fitted device origin. These are configuration choices, not
measured sensor guarantees.

```text
reference = reference_origin + round(local_offset + slope * (device-device_origin))
```

Integer differences precede floating conversion. Fit pair/centered differences
must have magnitude ≤2^53 ns; the configured query horizon is smaller. Local half
ties round away from zero; reconstruction and Int64 overflow are checked. Before
calibration, IMU admission returns `uncalibrated`; frames can be `clockUnavailable`.
Fitting/mapping require IEEE binary64 round-to-nearest without fast-math;
unsupported rounding modes fail closed. No extended-precision type is assumed.

### Residual error enclosure

Let `u=2^-53`, `up` round nonnegative bound operations outward with `nextafter`,
and `ulp(v)` be the spacing above `abs(v)`, including subnormal spacing at zero.
For a computed slope `s_hat` and centered exact integer pairs `(dx_i,dy_i)`:

```text
Bs      = up(4u * abs(s_hat))
a_hat_i = fma(-s_hat, dx_i, dy_i)
Ai      = up(up(abs(dx_i) * Bs) + ulp(a_hat_i))
b_hat   = median(a_hat_i)
Bb      = up(max(Ai) + ulp(b_hat))
r_hat_i = fl(a_hat_i - b_hat)
Bi      = up(up(Ai + Bb) + ulp(r_hat_i))
```

Division rounding and the monotone median, with one addition for an even median,
give `(1-u)^2 s* <= s_hat <= (1+u)^2 s*` for exact slope `s*>0`, hence the conservative
`4u*abs(s_hat)` bound. Median is 1-Lipschitz under a common absolute error bound;
full ULP allowances cover FMA, median addition, and residual subtraction. Supported
centered products stay within 2^106 and point-estimate intermediates remain normal
or zero. The budget is recomputed for each fit and its selected points. Nonfinite
fits or budgets are rejected.

For physical gate `G`, admission compares against the **exact real sum**:

```text
|r_hat_i| <= G + Bi
```

FastTwoSum retains threshold-rounding error instead of adding another unexplained
ULP. This interval-overlap policy retains inclusive boundaries, including `G=0`,
but an accepted exact residual can reach `G+2Bi`. Ambiguity can affect inlier
selection. In the four-second ±1 ppm fixtures, an extra nanosecond outside the
100 µs gate is excluded. Near 2^53, the budget can exceed a nanosecond and an
outside point can be admitted ambiguously. There is no exact physical-gate or
universal one-nanosecond mapping guarantee. Residual diagnostics are point
estimates, not physical uncertainty bounds.

Exact anchor retransmissions are duplicates; conflicting identity reuse is
invalid. A fresh anchor reusing a device coordinate with a changed reference, or
regressing either coordinate, begins a new epoch and discards buffered work with
counters. Swift closes that session with `discontinuity`. Known clock replacement
requires producers to stop/fence callbacks and restart even before detection:
untagged overlapping raw timestamps cannot identify the originating epoch.

## Ordering and alignment

The native engine preserves mapped event timestamps after admission; later
calibration updates cannot reorder previously accepted work. The stable key is
`(normalized_ns, source_rank, sequence)`, with IMU rank 0 before camera rank 1.

For active sources with observed maximum `M`, the watermark candidate is
`min(max(0,M-lateness))`; committed progress never moves backward. An unseen active
source blocks progress. Events release **strictly below** the frontier; equality
remains admissible, and older arrivals are late. Idle sources leave the minimum;
all-idle freezes progress. Idle is not end-of-stream. Stopping one source does not
flush its active peer. Stopped sources reject further data; all-stopped drains
terminally. A stopped source cannot reactivate within the session. Valid events
dropped at capacity still advance observed progress and drain sealed work first.

Deduplication uses a bounded numeric sequence window per source. Retained IDs
are duplicates; older IDs are stale, without a global deduplication promise.
Equal normalized IMU timestamps retain the first event under the stable key and
count the later collision.

Frames use exact samples or adjacent **sealed** IMU brackets. Linear interpolation
has a maximum endpoint gap and never extrapolates. Outputs include quality,
availability, endpoint identities, raw/mapped timestamps, fit revisions, and clock
epoch. A pending frame resolves when a bracket exists, a stopped IMU source's
queued samples have drained, or the watermark exceeds its checked `frame_time +
max_gap` deadline. Missing endpoints/calibration, excessive gaps, pending overflow,
and retention outcomes are explicit. Finalized dispositions can overtake older
pending queries. `history_evicted` counts sample entries, not lost frames.

| Storage/work | Bound or cost |
| --- | --- |
| Anchor window A | A≤64; fit O(A² log A), O(A²) temporary workspace |
| Reorder heap Q | At most Q; insertion/removal O(log Q), one call can drain Q |
| IMU history H | H retained, H+1 transient; O(log H) search, O(H) front eviction |
| Pending frames P | At most P; resolution O(P log H) per release |
| Sequence window D | O(D) lookup/retention per admission |
| Native outputs | At most Q+P+1 per operation; drain before the next operation |

Q/H/P/D are capped at 65,536; defaults are 256/512/64/1024. Persistent native
storage is O(A+Q+H+P+D), plus bounded outputs and fit workspace. Count limits bound
memory, not processing deadlines; large settings can be expensive.

## Concurrency and lifecycle

Synchronous `InputPort.offer` checks generation and admits to a mutex-protected
FIFO before actor execution. Capacity B permits B queued data entries, one
reserved control slot, and one in-flight input. The single consumer creates no
per-frame task. Full ingress and output buffers drop the new value with explicit
receipts/counters. Ingress acceptance acknowledges FIFO admission; native
rejections and alignment outcomes are accounted separately. Use one consumer for
each Session's bounded output stream.

Control admission and its single progress-waiter reservation are atomic. A
waiter conflict increments attempt/busy counters but enqueues nothing, consumes
no ticket, and has no control effect. Cancellation observed before admission
creates no command or ingress attempt. After admission, cancelling the caller's
wait does not roll back its FIFO command. Session cancellation can discard
buffered work, but cannot interrupt or undo an in-flight synchronous native call.
Controls do not overtake admitted data.

Finish closes admission, drains and joins. Cancel closes, wakes waiters, accounts
for discards and joins. Restart joins the old worker before installing a new
generation; stale callbacks are rejected synchronously. Native discontinuity or
internal fault closes the session and preserves its failure status. Fresh
sessions require fresh calibration. Outputs belong to `Session.generation`;
`clockEpoch` is separate native provenance. After join, ingress accepted counts
reconcile with processed and cancelled work; output production reconciles with
enqueued, dropped and terminated yields. Enqueued does not mean consumed.

### Optional camera adapter

The macOS AVFoundation adapter accepts an already authorized, host-owned capture
session's nonnil `synchronizationClock`, the pipeline port, and generation. The
host owns capture configuration, signing, a serial callback queue, and retained
adapter lifetime. It supplies `NSCameraUsageDescription` and the applicable
`com.apple.security.device.camera` entitlement for sandboxed/hardened capture.
The public initializer requires existing `.authorized` status; the adapter never
requests access or starts capture. See Apple's [authorization guidance](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
and [camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera).

PTS converts through [the session clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)
with `CMSyncConvertTime` into Core Media host-clock nanoseconds. It does not assume
Unix time or another Swift clock epoch. Checked integer rational scaling rounds
positive half ties away from zero and rejects invalid/nonnumeric times, nonzero
epochs, negative values and overflow. It copies
sequence/timestamp metadata synchronously; no sample/image buffer is retained or
passed to asynchronous work. Sequences do not wrap, and capture drops are counted
separately from ingress rejections. Camera-to-host conversion **does not calibrate
an independent IMU clock**; trusted device/host anchors are still required.

Before finish, restart or capture reconfiguration:

1. Invalidate the adapter to prevent new preparation/admission attempts.
2. Detach its delegate and fence the serial callback queue from another executor;
   do not synchronously fence a queue from itself.
3. After callbacks return, close the old pipeline session. For a replacement
   configuration, acquire its valid clock and create a new adapter/generation.

Invalidation does not join an already prepared offer, so detachment and fencing
are required. Real capture, permission UI, device loss and clock replacement need
host/device acceptance; synthetic metadata tests do not establish them.

## Verification

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --scratch-path .build-tsan --sanitize=thread -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
cmake -S . -B core-build -DCMAKE_BUILD_TYPE=Debug
cmake --build core-build --parallel
ctest --test-dir core-build --output-on-failure
cmake -S . -B core-sanitize -DCMAKE_BUILD_TYPE=Debug -DRIP_ENABLE_SANITIZERS=ON
cmake --build core-sanitize --parallel
ctest --test-dir core-sanitize --output-on-failure
python3 Verification/run_reference_checks.py --output-directory ../reference-results
```

The reference runner builds a separate optimized test library on macOS/Linux and
uses standard-library `Fraction` arithmetic for physical fits and independent
numerical enclosures. It checks 99 clock cases, 433 mappings and 35 interpolations,
including non-unity inclusive/zero gates, definite exclusions, long-span ambiguity,
final-fit drift recovery, integer limits and exact/derived mapping bounds. Ambiguous
memberships are bounded and explicitly enumerated; expected fits are not obtained
by replaying native float operations. `--compiler` selects a compiler executable.
Generated JSON/library/evidence stay in the requested output directory. The runner
does not support Windows; use native CMake/CTest there.

Native tests cover numerical/domain failures, order/ties/source states, capacities,
quality/provenance and C ownership. Swift tests cover atomic control rejection,
cancellation before/after admission, finish/restart, stale generations, pressure,
accounting, deterministic replay, and synthetic camera conversion. Correctness
tests use fixed inputs/seeds and synchronization, without timing sleeps.

The [CI workflow](.github/workflows/ci.yml) runs native C++ on Linux/macOS/Windows,
Linux sanitizers and reference checks, and macOS strict Swift tests, ThreadSanitizer,
a Release build and repeated canonical replay. Read its result for the selected
commit as build/test evidence; it does not validate physical synchronization or
hardware integration.

## Limitations

- Clock alignment depends on trustworthy anchors and an adequate affine model.
  A bounded estimator cannot guarantee rejection of arbitrary contamination.
- Binary64 ambiguity, horizon limits and local rounding apply. Floating output
  is not promised bit-identical across architectures or JSON normalizations.
- Fixed-width counters have no unlimited-lifetime guarantee. Native exceptions
  fail closed; allocation-failure injection has not been performed.
- Host timing uses a monotonic clock and Welford mean/sample variance/min/max for
  admission-to-dequeue wait and native service/copy-out. It is not full
  sensor-to-output latency; no percentile or throughput claim is made.
- Physical camera/IMU synchronization, permission flow and reconfiguration have
  not been validated. Oldest supported Swift/macOS runtime and Intel execution
  remain unverified. No formal benchmark or hard real-time claim is provided.
