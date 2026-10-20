#!/usr/bin/env python3
"""Exact physical fits and independently derived numerical error enclosures.

Fractions preserve pair slopes, median intercepts, physical residual gates and
query rounding. Enclosures bound native errors without replaying its float fit.
"""
from __future__ import annotations

import argparse
import ctypes as C
from fractions import Fraction as F
from itertools import product
import json
import math
from pathlib import Path
import random
import sys

SEED = 2026102003
I64_MAX = (1 << 63) - 1
MAX_EXACT_DELTA = 1 << 53
UNIT_ROUNDOFF = F(1, 1 << 53)


def median(values):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("empty median")
    n = len(ordered)
    return ordered[n // 2] if n % 2 else (ordered[n // 2 - 1] + ordered[n // 2]) / 2


def round_away(value):
    value = F(value)
    sign = -1 if value < 0 else 1
    value = abs(value)
    return sign * ((2 * value.numerator + value.denominator) // (2 * value.denominator))


def ts_fit(points):
    slopes = [F(y1 - y0, x1 - x0)
              for i, (x0, y0) in enumerate(points)
              for x1, y1 in points[i + 1:] if x1 != x0]
    if not slopes:
        return None
    slope = median(slopes)
    intercept = median([F(y) - slope * x for x, y in points])
    return slope, intercept


def domain_failure(points, cfg):
    if len(points) < cfg["min_anchors"]:
        return "insufficient anchors"
    if any(not (0 <= x <= I64_MAX and 0 <= y <= I64_MAX) for x, y in points):
        return "invalid anchor coordinate"
    xspan = max(x for x, _ in points) - min(x for x, _ in points)
    yspan = max(y for _, y in points) - min(y for _, y in points)
    if xspan > MAX_EXACT_DELTA or yspan > MAX_EXACT_DELTA:
        return "pair difference exceeds exact binary64 integer domain"
    if xspan < cfg["min_anchor_span_ns"]:
        return "insufficient span"
    return None


def rounded_up(value):
    """A rational upper enclosure of one rounded-and-nextafter bound operation."""
    return F.from_float(math.nextafter(float(value), math.inf))


def ulp_upper(magnitude):
    """Enclose the ulp of any binary64 result of magnitude at most magnitude."""
    value = float(magnitude)
    if F.from_float(value) < magnitude:
        value = math.nextafter(value, math.inf)
    return F.from_float(math.ulp(value))


def line_enclosure(points):
    """Derive error bounds from the exact line, without evaluating a float fit.

    Rounded positive pair quotients have relative error <= u. Their ordered
    medians inherit that bound; an even median adds one rounded addition after
    exact halving. Thus |s_hat-s| <= (2u+u^2)|s|. Median is 1-Lipschitz in the
    maximum norm. Full ulps safely enclose each FMA, median addition and residual
    subtraction. All quantities below are rational upper/lower enclosures.
    """
    slope, intercept = ts_fit(points)
    x0, y0 = points[len(points)//2]
    slope_error = (2*UNIT_ROUNDOFF + UNIT_ROUNDOFF**2) * abs(slope)
    budget_slope_hi = rounded_up(4*UNIT_ROUNDOFF*(abs(slope)+slope_error))
    budget_slope_lo = 4*UNIT_ROUNDOFF*max(F(0), abs(slope)-slope_error)
    offset = intercept + slope*x0-y0
    centered = [F(y-y0)-slope*(x-x0) for x, y in points]
    errors_a, budgets_a = [], []
    for (x, _), exact_a in zip(points, centered):
        dx = abs(x-x0)
        before_rounding = abs(exact_a)+dx*slope_error
        ulp_a = ulp_upper(before_rounding+ulp_upper(before_rounding))
        errors_a.append(dx*slope_error+ulp_a)
        budgets_a.append(rounded_up(rounded_up(dx*budget_slope_hi)+ulp_a))
    offset_magnitude = abs(offset)+max(errors_a)
    ulp_b = ulp_upper(offset_magnitude+ulp_upper(offset_magnitude))
    offset_error = max(errors_a)+ulp_b
    budget_b = rounded_up(max(budgets_a)+ulp_b)
    residuals, errors, budgets_hi, budgets_lo = [], [], [], []
    largest_dx = max(abs(x-x0) for x, _ in points)
    for index, ((x, y), exact_a) in enumerate(zip(points, centered)):
        residual = exact_a-offset
        before_rounding = abs(residual)+errors_a[index]+offset_error
        ulp_r = ulp_upper(before_rounding+ulp_upper(before_rounding))
        residuals.append(residual)
        errors.append(errors_a[index]+offset_error+ulp_r)
        budgets_hi.append(rounded_up(rounded_up(budgets_a[index]+budget_b)+ulp_r))
        budgets_lo.append((abs(x-x0)+largest_dx)*budget_slope_lo)
    return dict(slope=slope, intercept=intercept, origin=(x0, y0), offset=offset,
                slope_error=slope_error, offset_error=offset_error,
                residuals=residuals, residual_errors=errors,
                policy_budget_upper=budgets_hi, policy_budget_lower=budgets_lo)


def membership_classification(line, gate):
    included, optional, excluded, physical_ambiguity = [], [], [], []
    for i, (residual, error, lower, upper) in enumerate(zip(
            line["residuals"], line["residual_errors"],
            line["policy_budget_lower"], line["policy_budget_upper"])):
        magnitude = abs(residual)
        if gate < magnitude <= gate+2*upper:
            physical_ambiguity.append(i)
        # The first condition follows from soundness of the policy's B_i.
        # The second can independently prove intentional outside-gate admission.
        if magnitude <= gate or magnitude+error <= gate+lower:
            included.append(i)
        elif magnitude-error > gate+upper:
            excluded.append(i)
        else:
            optional.append(i)
    return dict(included=included, optional=optional, excluded=excluded,
                physical_ambiguity=physical_ambiguity)


def policy_models(points, cfg):
    """Enumerate only memberships left uncertain by independently derived bounds."""
    failure = domain_failure(points, cfg)
    if failure:
        return dict(readiness=[False], reason=failure, candidates=[])
    initial = line_enclosure(points)
    if initial["slope"] <= 0:
        return dict(readiness=[False], reason="nonpositive preliminary slope", candidates=[])
    gate = F.from_float(float(cfg["max_anchor_residual_ns"]))
    selection = membership_classification(initial, gate)
    if len(selection["optional"]) > 12:
        raise ValueError("reference fixture exceeds bounded ambiguity enumeration")
    candidates, readiness = [], set()
    for choices in product((False, True), repeat=len(selection["optional"])):
        indices = sorted(selection["included"] + [i for i, take in zip(selection["optional"], choices) if take])
        inliers = [points[i] for i in indices]
        failure = domain_failure(inliers, cfg)
        if failure or F(len(inliers), len(points)) < F(str(cfg["min_inlier_fraction"])):
            readiness.add(False)
            continue
        final = line_enclosure(inliers)
        slope = final["slope"]
        if slope <= 0 or abs(slope-1)*1000000 > F(str(cfg["max_drift_ppm"])):
            readiness.add(False)
            continue
        final_membership = membership_classification(final, gate)
        allowed = [False] if final_membership["excluded"] else ([False, True] if final_membership["optional"] else [True])
        readiness.update(allowed)
        candidates.append(dict(points=inliers, indices=indices, line=final,
                               readiness=allowed, final_classification=final_membership))
    return dict(readiness=sorted(readiness), candidates=candidates,
                initial_line=initial, initial_classification=selection)


def fit(points, cfg):
    """One joint Theil-Sen fit, fixed residual gate, exactly one inlier refit."""
    failure = domain_failure(points, cfg)
    if failure:
        return {"ready": False, "reason": failure}
    initial = ts_fit(points)
    if initial is None:
        return {"ready": False, "reason": "degenerate slopes"}
    slope0, intercept0 = initial
    if slope0 <= 0:
        return {"ready": False, "reason": "nonpositive preliminary slope"}
    gate = F.from_float(float(cfg["max_anchor_residual_ns"]))
    inliers = [p for p in points if abs(F(p[1]) - slope0 * p[0] - intercept0) <= gate]
    if len(inliers) < cfg["min_anchors"] or F(len(inliers), len(points)) < F(str(cfg["min_inlier_fraction"])):
        return {"ready": False, "reason": "insufficient inliers", "inlier_count": len(inliers)}
    failure = domain_failure(inliers, cfg)
    if failure:
        return {"ready": False, "reason": failure, "inlier_count": len(inliers)}
    final = ts_fit(inliers)
    if final is None:
        return {"ready": False, "reason": "degenerate inlier slopes"}
    slope, intercept = final
    residuals = [F(y) - slope * x - intercept for x, y in inliers]
    if slope <= 0 or abs(slope - 1) * 1000000 > F(str(cfg["max_drift_ppm"])):
        return {"ready": False, "reason": "drift outside inclusive bound", "inlier_count": len(inliers)}
    if max(abs(r) for r in residuals) > gate:
        return {"ready": False, "reason": "final residual outside bound", "inlier_count": len(inliers)}
    return {"ready": True, "slope": slope, "intercept": intercept,
            "inliers": inliers, "inlier_count": len(inliers),
            "support_min_ns": min(x for x, _ in inliers),
            "support_max_ns": max(x for x, _ in inliers),
            "residual_max_ns": max(abs(r) for r in residuals),
            "residual_rms_ns": math.sqrt(float(sum(r*r for r in residuals) / len(residuals)))}


def map_exact(model, device, device_origin, reference_origin, cfg):
    if not model["ready"]:
        return {"status": 2}
    delta = device - device_origin
    if device < 0 or abs(delta) > cfg["max_query_distance_ns"] or abs(delta) > MAX_EXACT_DELTA:
        return {"status": 12}
    offset = model["slope"] * device_origin + model["intercept"] - reference_origin
    rounded = round_away(offset + model["slope"] * delta)
    mapped = reference_origin + rounded
    if not (-(1 << 63) <= rounded <= I64_MAX and 0 <= mapped <= I64_MAX):
        return {"status": 12}
    return {"status": 0, "reference_ns": mapped}


def cfg_values(**updates):
    result = dict(anchor_capacity=17, min_anchors=5, min_anchor_span_ns=1000000000,
                  max_query_distance_ns=60000000000, max_drift_ppm=5000.0,
                  max_anchor_residual_ns=100000.0, min_inlier_fraction=0.6,
                  reorder_capacity=64, history_capacity=32, pending_frame_capacity=16,
                  dedup_capacity=128, lateness_ns=1000000,
                  max_interpolation_gap_ns=2000000000)
    result.update(updates)
    return result


def make_case(name, device0, reference0, step, count, slope=F(1), noises=None, queries=None, **updates):
    noises = noises or [0] * count
    points = [(device0 + i * step, reference0 + int(slope * i * step) + noises[i]) for i in range(count)]
    assert all(0 <= x <= I64_MAX and 0 <= y <= I64_MAX for x, y in points)
    assert all(a[0] < b[0] and a[1] < b[1] for a, b in zip(points, points[1:]))
    return dict(name=name, config=cfg_values(**updates), points=points,
                queries=queries or [device0, device0 + step // 3, device0 + (count - 1) * step])


def cases():
    fixed = [
        make_case("exact_identity", 1000000000, 4000000000, 250000000, 9),
        make_case("exact_1ppm", 1000000000, 5000000000, 1000000000, 9,
                  slope=F(1000001, 1000000), queries=[1000000001, 1123456789, 8999999999]),
        make_case("centered_half_away", 1000000000, 5000000000, 1000000000, 9,
                  slope=F(3, 2), max_drift_ppm=600000.0,
                  queries=[4999999999, 5000000000, 5000000001]),
        make_case("near_int64_identity", I64_MAX - 20000000000, I64_MAX - 19000000000,
                  1000000000, 9, queries=[I64_MAX - 19999999999, I64_MAX - 15000000000,
                                        I64_MAX - 1, I64_MAX]),
        make_case("near_int64_drift", I64_MAX - 20000000000, I64_MAX - 19000000000,
                  1000000000, 9, slope=F(1000001, 1000000),
                  queries=[I64_MAX - 19999999999, I64_MAX - 15000000000, I64_MAX]),
        make_case("joint_intercept_with_outliers", 1000000000, 5000012345, 1000000000, 9,
                  noises=[0, 1000, -2000, 75000, 3000, -1000, -85000, 2000, 0],
                  max_anchor_residual_ns=10000.0),
        make_case("inclusive_ppm_positive", 1000000000, 5000000000, 1000000000, 9,
                  slope=F(201, 200)),
        make_case("inclusive_ppm_negative", 1000000000, 5000000000, 1000000000, 9,
                  slope=F(199, 200)),
        make_case("beyond_ppm", 1000000000, 5000000000, 1000000000, 9,
                  slope=F(1005001, 1000000)),
        make_case("query_horizon", 100000000000, 200000000000, 1000000000, 9,
                  queries=[44000000000, 43999999999, 164000000000, 164000000001]),
        make_case("inclusive_residual_gate", 1000000000, 5000000000, 1000000000, 9,
                  noises=[0, 0, 0, 0, 0, 0, 0, 0, 10000], max_anchor_residual_ns=10000.0),
        make_case("one_ns_outside_residual_gate", 1000000000, 5000000000, 1000000000, 9,
                  noises=[0, 0, 0, 0, 0, 0, 0, 0, 10001], max_anchor_residual_ns=10000.0),
        make_case("inclusive_inlier_fraction", 1000000000, 5000000000, 1000000000, 10,
                  noises=[0, 0, 0, 100000, 100000, -100000, -100000, 0, 0, 0],
                  max_anchor_residual_ns=10000.0),
        make_case("beyond_inlier_fraction", 1000000000, 5000000000, 1000000000, 10,
                  noises=[0, 0, 0, 100000, 100000, -100000, -100000, 0, 0, 0],
                  max_anchor_residual_ns=10000.0, min_inlier_fraction=0.600001),
        make_case("exact_zero_timestamp", 0, 0, 1000000000, 9, queries=[0, 1, 8000000000]),
    ]
    rng = random.Random(SEED)
    for index in range(64):
        count = rng.choice([7, 9, 11, 13, 15, 17])
        step = rng.choice([100000000, 500000000, 1000000000, 2000000000])
        d0 = rng.choice([100000000000, 10**15, I64_MAX - 200000000000])
        r0 = rng.choice([200000000000, 10**15 + 123456, I64_MAX - 200000000000])
        slope = F(1000000 + rng.randrange(-3000, 3001), 1000000)
        noises = [rng.randrange(-1000, 1001) for _ in range(count)]
        for outlier in rng.sample(range(count), rng.choice([0, 1, 2])):
            noises[outlier] += rng.choice([-1, 1]) * rng.randrange(50000, 150001)
        fixed.append(make_case(f"random_{index:02d}", d0, r0, step, count, slope=slope,
                               noises=noises, queries=[d0 + rng.randrange(0, (count - 1)*step) for _ in range(5)],
                               min_anchor_span_ns=step*2, max_anchor_residual_ns=10000.0))
    # Residual-boundary, drift-admission, and numerical-domain regression cases.
    for direction, label in [(1, "positive"), (-1, "negative")]:
        slope = F(1000000+direction, 1000000)
        for noise, gate, suffix in [(100000, 100000, "inclusive"),
                                    (0, 0, "zero_gate"),
                                    (100001, 100000, "one_ns_outside")]:
            fixed.append(make_case(f"boundary_{label}_{suffix}", 0, 0, 1000000000, 5,
                                   slope=slope, noises=[0, 0, 0, 0, noise],
                                   queries=[0, 2000000000, 2500000000, 4000000000],
                                   max_anchor_residual_ns=float(gate)))
    noise = [0, 700000, 0, 0, 0, -380000, 0, 0, -480000]
    points = [(i*1000000000, i*995010000+noise[i-1]) for i in range(1, 10)]
    fixed.append(dict(name="preliminary_outside_final_inside_ppm", config=cfg_values(),
                      points=points, queries=[1000000000, 5000000000, 8000000000]))
    fixed.append(make_case("final_drift_outside_ppm", 0, 0, 1000000000, 5,
                           slope=F(1005001, 1000000)))
    fixed.append(dict(name="nonpositive_preliminary", config=cfg_values(),
                      points=[(i*1000000000, 0) for i in range(5)], queries=[2000000000]))
    for label, points in [("device", [(0, 0), (MAX_EXACT_DELTA+1, MAX_EXACT_DELTA)]),
                          ("reference", [(0, 0), (MAX_EXACT_DELTA, MAX_EXACT_DELTA+1)])]:
        fixed.append(dict(name=f"outside_pair_domain_{label}",
                          config=cfg_values(min_anchors=2, min_anchor_span_ns=1),
                          points=points, queries=[0, 1]))
    fixed.append(dict(name="invalid_negative_anchor", config=cfg_values(),
                      points=[(-1, 0)]+[(i*1000000000, i*1000000000) for i in range(4)],
                      anchor_statuses=[3, 0, 0, 0, 0], queries=[0]))
    end = 9007180000000000
    xs = [0, 1000000, 2000000, end-1000000, end]
    for direction, label in [(1, "positive"), (-1, "negative")]:
        for noise in [0, 1, 100]:
            points = [(x, x+direction*(x//1000000)+(noise if i == 4 else 0))
                      for i, x in enumerate(xs)]
            fixed.append(dict(name=f"precision_limit_{label}_noise_{noise}",
                              config=cfg_values(max_query_distance_ns=MAX_EXACT_DELTA-1,
                                                max_anchor_residual_ns=0.0),
                              points=points, queries=[0, 2000000, end-1, end],
                              mapping_policy="enclosure", required_native_ready=noise < 100,
                              required_physical_ambiguity=noise == 1))
    fixed.append(dict(name="precision_limit_optional_membership",
                      config=cfg_values(max_query_distance_ns=MAX_EXACT_DELTA-1,
                                        max_anchor_residual_ns=0.0),
                      points=[(x, x+x//1000000+(4 if i == 4 else 0)) for i, x in enumerate(xs)],
                      queries=[0, 2000000, end-1, end], mapping_policy="enclosure",
                      required_physical_ambiguity=True))
    fixed.append(dict(name="exact_supported_pair_limit",
                      config=cfg_values(min_anchors=2, min_anchor_span_ns=1,
                                        max_query_distance_ns=MAX_EXACT_DELTA-1,
                                        max_anchor_residual_ns=0.0),
                      points=[(0, 0), (MAX_EXACT_DELTA, MAX_EXACT_DELTA)],
                      queries=[MAX_EXACT_DELTA-1, MAX_EXACT_DELTA]))
    return fixed


def encoded(value):
    if isinstance(value, F):
        return {"exact": f"{value.numerator}/{value.denominator}", "float": float(value)}
    if isinstance(value, dict):
        return {k: encoded(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [encoded(v) for v in value]
    return value


U32, U64, I64, D = C.c_uint32, C.c_uint64, C.c_int64, C.c_double


class Config(C.Structure):
    _fields_ = [("anchor_capacity", U32), ("min_anchors", U32),
                ("min_anchor_span_ns", I64), ("max_query_distance_ns", I64),
                ("max_drift_ppm", D), ("max_anchor_residual_ns", D), ("min_inlier_fraction", D),
                ("reorder_capacity", U32), ("history_capacity", U32),
                ("pending_frame_capacity", U32), ("dedup_capacity", U32),
                ("lateness_ns", I64), ("max_interpolation_gap_ns", I64)]


class Anchor(C.Structure):
    _fields_ = [("sequence", U64), ("device_ns", I64), ("reference_ns", I64)]


class Sample(C.Structure):
    _fields_ = [("sequence", U64), ("device_ns", I64), ("x", D), ("y", D), ("z", D)]


class Frame(C.Structure):
    _fields_ = [("sequence", U64), ("reference_ns", I64)]


class Info(C.Structure):
    _fields_ = [("state", U32), ("anchors", U32), ("inliers", U32),
                ("epoch", U64), ("revision", U64), ("device_origin_ns", I64),
                ("reference_origin_ns", I64), ("support_min_ns", I64), ("support_max_ns", I64),
                ("slope", D), ("local_offset_ns", D), ("drift_ppm", D),
                ("residual_rms_ns", D), ("residual_max_ns", D)]


class Output(C.Structure):
    _fields_ = [("frame_sequence", U64), ("reference_ns", I64), ("quality", U32),
                ("available", U32), ("has_left", U32), ("has_right", U32),
                ("x", D), ("y", D), ("z", D), ("left_sequence", U64), ("right_sequence", U64),
                ("left_device_ns", I64), ("right_device_ns", I64),
                ("left_normalized_ns", I64), ("right_normalized_ns", I64),
                ("clock_epoch", U64), ("left_clock_revision", U64), ("right_clock_revision", U64)]


def struct_dict(value):
    return {name: getattr(value, name) for name, _ in value._fields_}


def load_library(path):
    lib = C.CDLL(str(Path(path).resolve()))
    declarations = {
        "rip_default_config": (Config, []),
        "rip_core_create": (C.c_void_p, [Config, C.POINTER(C.c_int)]),
        "rip_core_destroy": (None, [C.c_void_p]),
        "rip_core_add_anchor": (C.c_int, [C.c_void_p, Anchor]),
        "rip_core_push_imu": (C.c_int, [C.c_void_p, Sample]),
        "rip_core_push_frame": (C.c_int, [C.c_void_p, Frame]),
        "rip_core_finish": (C.c_int, [C.c_void_p]),
        "rip_core_clock_info": (C.c_int, [C.c_void_p, C.POINTER(Info)]),
        "rip_core_map_time": (C.c_int, [C.c_void_p, I64, C.POINTER(I64)]),
        "rip_core_pop_output": (C.c_int, [C.c_void_p, C.POINTER(Output)]),
    }
    for name, (ret, args) in declarations.items():
        function = getattr(lib, name)
        function.restype, function.argtypes = ret, args
    return lib


def new_core(lib, cfg):
    status = C.c_int(-1)
    native_cfg = Config(**cfg)
    core = lib.rip_core_create(native_cfg, C.byref(status))
    if not core or status.value:
        raise RuntimeError(f"create failed: {status.value}")
    return core


def compare_case(lib, case):
    cfg, points = case["config"], case["points"]
    expected_statuses = case.get("anchor_statuses", [0]*len(points))
    retained = [p for p, status in zip(points, expected_statuses) if status == 0][-cfg["anchor_capacity"]:]
    model = fit(retained, cfg)
    policy = policy_models(retained, cfg)
    core = new_core(lib, cfg)
    defects = []
    result = {"name": case["name"], "queries": [], "defects": defects,
              "exact_physical_fit": model, "numerical_policy": policy}
    def require(condition, message, **detail):
        if not condition:
            defects.append({"assertion": message, **detail})
    try:
        statuses = [lib.rip_core_add_anchor(core, Anchor(i+1, x, y)) for i, (x, y) in enumerate(points)]
        require(statuses == expected_statuses, "anchor admission matches", expected=expected_statuses, actual=statuses)
        info = Info()
        require(lib.rip_core_clock_info(core, C.byref(info)) == 0, "clock info readable")
        result["native_info"] = struct_dict(info)
        if case.get("mapping_policy") != "enclosure":
            require((info.state == 1) == model["ready"], "readiness matches exact oracle",
                    expected=model["ready"], actual=info.state)
        require((info.state == 1) in policy["readiness"], "readiness matches independent numerical enclosures",
                expected=policy["readiness"], actual=info.state)
        if "required_native_ready" in case:
            require((info.state == 1) == case["required_native_ready"], "precision regression has required disposition",
                    expected=case["required_native_ready"], actual=info.state)
        if case.get("required_physical_ambiguity"):
            require(bool(policy["initial_classification"]["physical_ambiguity"]),
                    "outside physical gate is explicitly classified as numerical ambiguity")
            require(not model["ready"], "ambiguous admission does not redefine exact physical gate")
        selected = None
        candidate_diagnostics = []
        if info.state == 1:
            for candidate in policy["candidates"]:
                if True not in candidate["readiness"]:
                    continue
                line, inliers = candidate["line"], candidate["points"]
                slope_error = abs(F.from_float(info.slope)-line["slope"])
                offset_error = abs(F.from_float(info.local_offset_ns)-line["offset"])
                checks = dict(inliers=info.inliers == len(inliers),
                              origin=(info.device_origin_ns, info.reference_origin_ns) == line["origin"],
                              support=(info.support_min_ns, info.support_max_ns) == (inliers[0][0], inliers[-1][0]),
                              slope=slope_error <= line["slope_error"],
                              offset=offset_error <= line["offset_error"])
                candidate_diagnostics.append(dict(indices=candidate["indices"], checks=checks,
                                                   slope_error=slope_error, offset_error=offset_error))
                if all(checks.values()):
                    selected = candidate
                    break
            require(selected is not None, "reported fit lies in an independently enclosed admissible model",
                    candidates=candidate_diagnostics)
        result["candidate_diagnostics"] = candidate_diagnostics
        # Use strict comparisons where physical membership is unambiguous.
        # Large-span cases have explicit enclosures below.
        if model["ready"] and info.state == 1 and case.get("mapping_policy") != "enclosure":
            expected_offset = model["slope"] * info.device_origin_ns + model["intercept"] - info.reference_origin_ns
            require(abs(info.slope - float(model["slope"])) <= 1e-12, "slope matches rational fit", expected=float(model["slope"]), actual=info.slope)
            require(abs(info.local_offset_ns - float(expected_offset)) <= 0.001, "joint median intercept matches", expected=float(expected_offset), actual=info.local_offset_ns)
            require(info.inliers == model["inlier_count"], "fixed-gate inlier count matches", expected=model["inlier_count"], actual=info.inliers)
            require(info.support_min_ns == model["support_min_ns"] and info.support_max_ns == model["support_max_ns"], "inlier support matches", expected=[model["support_min_ns"], model["support_max_ns"]], actual=[info.support_min_ns, info.support_max_ns])
            require(abs(info.residual_max_ns - float(model["residual_max_ns"])) <= 0.001, "final residual max matches", expected=float(model["residual_max_ns"]), actual=info.residual_max_ns)
            require(abs(info.residual_rms_ns - model["residual_rms_ns"]) <= 0.001, "final residual rms matches", expected=model["residual_rms_ns"], actual=info.residual_rms_ns)
        if selected is not None:
            line = selected["line"]
            maximum = max(abs(r) for r in line["residuals"])
            rms = math.sqrt(float(sum(r*r for r in line["residuals"])/len(line["residuals"])))
            # RMS is 1-Lipschitz in component error. The additional 2^-45 term
            # encloses <=64 positive square/sum operations and sqrt rounding.
            residual_error = max(line["residual_errors"])
            rms_rounding = F(1, 1 << 45)*max(F(1), maximum+residual_error)
            require(abs(F.from_float(info.residual_max_ns)-maximum) <= residual_error,
                    "maximum residual lies in exact error enclosure", budget_ns=residual_error)
            require(abs(info.residual_rms_ns-rms) <= float(residual_error+rms_rounding),
                    "RMS residual lies in exact error enclosure", budget_ns=residual_error+rms_rounding)
        for query in case["queries"]:
            if case.get("mapping_policy") != "enclosure":
                query_model = model
            else:
                query_model = dict(ready=False) if selected is None else dict(
                    ready=True, slope=selected["line"]["slope"], intercept=selected["line"]["intercept"])
            expected = map_exact(query_model, query, info.device_origin_ns, info.reference_origin_ns, cfg)
            mapped = I64(-1)
            status = lib.rip_core_map_time(core, query, C.byref(mapped))
            observed = {"status": status}
            if status == 0:
                observed["reference_ns"] = mapped.value
            query_result = {"device_ns": query, "expected": expected, "observed": observed}
            result["queries"].append(query_result)
            require(status == expected["status"], "map status matches", query=query, expected=expected, actual=observed)
            if status == expected["status"] == 0:
                line = selected["line"]
                delta = query-info.device_origin_ns
                exact_local = line["offset"]+line["slope"]*delta
                before_rounding = abs(delta)*line["slope_error"]+line["offset_error"]
                fma_error = ulp_upper(abs(exact_local)+before_rounding)
                map_error = before_rounding+fma_error+F(1, 2)
                query_result["map_enclosure_ns"] = map_error
                require(abs(F(mapped.value-info.reference_origin_ns)-exact_local) <= map_error,
                        "mapped integer lies in independent affine/FMA/rounding enclosure", query=query,
                        budget_ns=map_error, exact_unrounded_reference=exact_local+info.reference_origin_ns,
                        actual=observed)
                if case.get("mapping_policy") != "enclosure":
                    tolerance = 0 if case["name"].startswith(("exact_", "near_int64_identity", "centered_half")) else 1
                    require(abs(mapped.value - expected["reference_ns"]) <= tolerance, "integer map matches", query=query, tolerance_ns=tolerance, expected=expected, actual=observed)
    finally:
        lib.rip_core_destroy(core)
    return result


def interpolation_cases():
    rng = random.Random(SEED + 1)
    result = [dict(name="midpoint_three_axes", left=[-1.0, 2.0, 100.0], right=[3.0, 6.0, -100.0], delta=500000000, gap=1000000000),
              dict(name="finite_extreme_midpoint", left=[1e308, -1e308, 1e308], right=[-1e308, 1e308, 1e308], delta=500000000, gap=1000000000),
              dict(name="one_third", left=[-3.0, 3.0, 30.0], right=[6.0, -6.0, -60.0], delta=100000000, gap=300000000)]
    for i in range(32):
        gap = rng.randrange(2, 1500000000)
        result.append(dict(name=f"interpolation_random_{i:02d}",
                           left=[rng.uniform(-10000, 10000) for _ in range(3)],
                           right=[rng.uniform(-10000, 10000) for _ in range(3)],
                           delta=rng.randrange(1, gap), gap=gap))
    return result


def interpolation_expected(case):
    weight = F(case["delta"], case["gap"])
    return [float(F.from_float(a) + weight * (F.from_float(b) - F.from_float(a)))
            for a, b in zip(case["left"], case["right"])]


def compare_interpolation(lib, case):
    cfg = cfg_values()
    core = new_core(lib, cfg)
    defects, outputs = [], []
    try:
        for i in range(9):
            status = lib.rip_core_add_anchor(core, Anchor(i+1, 1000000000+i*1000000000, 5000000000+i*1000000000))
            if status != 0:
                defects.append({"assertion": "calibration anchor admitted", "actual": status})
        left_device, left_normalized = 3000000000, 7000000000
        for sequence, device, values in [(1, left_device, case["left"]), (2, left_device+case["gap"], case["right"])]:
            status = lib.rip_core_push_imu(core, Sample(sequence, device, *values))
            if status != 0:
                defects.append({"assertion": "IMU admitted", "sequence": sequence, "actual": status})
        status = lib.rip_core_push_frame(core, Frame(1, left_normalized+case["delta"]))
        if status != 0:
            defects.append({"assertion": "frame admitted", "actual": status})
        status = lib.rip_core_finish(core)
        if status != 0:
            defects.append({"assertion": "finish succeeds", "actual": status})
        while True:
            output = Output()
            status = lib.rip_core_pop_output(core, C.byref(output))
            if status == 1:
                break
            if status != 0:
                defects.append({"assertion": "output drain", "actual": status})
                break
            outputs.append(struct_dict(output))
        expected = interpolation_expected(case)
        if len(outputs) != 1:
            defects.append({"assertion": "one output", "actual": len(outputs)})
        else:
            output = outputs[0]
            if not (output["quality"] == 1 and output["available"] == 1 and output["has_left"] == 1 and output["has_right"] == 1):
                defects.append({"assertion": "bracketed interpolation available", "actual": output})
            observed = [output[k] for k in ("x", "y", "z")]
            for axis, actual, wanted in zip("xyz", observed, expected):
                if not math.isfinite(actual) or not math.isclose(actual, wanted, rel_tol=2e-14, abs_tol=1e-10):
                    defects.append({"assertion": "convex axis matches exact Fraction interpolation", "axis": axis, "expected": wanted, "actual": actual})
            if [output["left_normalized_ns"], output["right_normalized_ns"]] != [left_normalized, left_normalized+case["gap"]]:
                defects.append({"assertion": "integer endpoint provenance", "actual": output})
        return {"name": case["name"], "input": case, "expected_axes": expected, "native_outputs": outputs, "defects": defects}
    finally:
        lib.rip_core_destroy(core)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library")
    parser.add_argument("--output-directory", required=True, type=Path,
                        help="Directory for generated reference-values.json and comparison.json")
    args = parser.parse_args()
    output_directory = args.output_directory.resolve()
    output_directory.mkdir(parents=True, exist_ok=True)
    fixtures = cases()
    # Small independently hand-checkable identities guard the oracle itself.
    assert median([F(1), F(7), F(3), F(5)]) == 4
    assert [round_away(F(n, 2)) for n in [-5, -3, -1, 0, 1, 3, 5]] == [-3, -2, -1, 0, 1, 2, 3]
    assert ts_fit([(0, 7), (2, 10), (4, 13)]) == (F(3, 2), F(7))
    robust = fit(fixtures[5]["points"], fixtures[5]["config"])
    assert robust["slope"] == F(6000001, 6000000)
    assert robust["intercept"] == F(12000036535, 3)
    assert robust["inlier_count"] == 7
    assert interpolation_expected(interpolation_cases()[0]) == [1.0, 4.0, 0.0]
    assert interpolation_expected(interpolation_cases()[1]) == [0.0, 0.0, 1e308]
    named = {case["name"]: case for case in fixtures}
    for sign in ("positive", "negative"):
        for suffix in ("inclusive", "zero_gate"):
            case = named[f"boundary_{sign}_{suffix}"]
            assert fit(case["points"], case["config"])["inlier_count"] == 5
            assert policy_models(case["points"], case["config"])["readiness"] == [True]
        for noise in (0, 1, 100):
            case = named[f"precision_limit_{sign}_noise_{noise}"]
            assert policy_models(case["points"], case["config"])["readiness"] == [noise < 100]
            if noise == 1:
                assert not fit(case["points"], case["config"])["ready"]
    phase = named["preliminary_outside_final_inside_ppm"]
    assert ts_fit(phase["points"])[0] == F(149249, 150000)
    assert fit(phase["points"], phase["config"])["slope"] == F(99501, 100000)
    assert fit(phase["points"], phase["config"])["inlier_count"] == 6
    optional = named["precision_limit_optional_membership"]
    assert policy_models(optional["points"], optional["config"])["readiness"] == [False, True]
    reference = {"seed": SEED, "clock_cases": [], "interpolation_cases": [], "assumptions": [
        "Anchors are same-instant pairs; valid fixtures have unique monotone device coordinates and identities. Explicit invalid/nonpositive/domain fixtures test rejection.",
        "All pair slopes participate before gating. Even medians average the middle two rationals.",
        "The exact physical model uses an inclusive fixed residual gate. Preliminary slope must be positive and pair differences within 2^53; only the final refit is constrained by ppm.",
        "Numerical admission is interval overlap: |r_hat| <= G+B_i. Exact physical residual can be as large as G+2B_i. Independently derived rational error/budget enclosures classify definite and ambiguous memberships.",
        "The reference does not reproduce native floating fit operations. It bounds quotient/even-median error by (2u+u^2)|s_exact|, uses median Lipschitz continuity and ULP magnitude bounds, and enumerates at most 12 optional boundary memberships.",
        "Reported support and final residual statistics refer to selected inliers.",
        "Canonical physical reference JSON uses the middle input anchor as integer origin. Native middle-inlier origins and support are independently checked against admissible exact models.",
        "Half ties round away from zero in the centered local delta, as the architecture specifies. This can differ by one ns from rounding an absolute predicted timestamp.",
        "Cases without mapping_policy=enclosure use 0.001 ns residual/intercept and 1e-12 slope limits, plus 1 ns or exact integer mapping checks. Precision-limit cases report affine/FMA/integer-rounding enclosures, without a universal 1 ns promise.",
        "Convex interpolation is computed with exact fractions of the input IEEE doubles and integer timestamp ratio; all expected axes remain finite.",
        "This checks clock mathematics and selected interpolation examples, not concurrent orchestration, hardware synchronization or throughput.",
    ]}
    for case in fixtures:
        model = fit(case["points"], case["config"])
        origin = case["points"][len(case["points"])//2]
        retained = [p for p, status in zip(case["points"], case.get("anchor_statuses", [0]*len(case["points"]))) if status == 0][-case["config"]["anchor_capacity"]:]
        reference["clock_cases"].append({**case, "expected_fit": model, "canonical_origin": origin,
            "numerical_policy": policy_models(retained, case["config"]),
            "expected_queries": [{"device_ns": q, **map_exact(model, q, *origin, case["config"])} for q in case["queries"]]})
    for case in interpolation_cases():
        reference["interpolation_cases"].append({**case, "expected_axes": interpolation_expected(case)})
    (output_directory / "reference-values.json").write_text(json.dumps(encoded(reference), indent=2, allow_nan=False)+"\n")
    if args.library:
        lib = load_library(args.library)
        results = [compare_case(lib, case) for case in fixtures]
        interpolations = [compare_interpolation(lib, case) for case in interpolation_cases()]
        defect_count = sum(len(c["defects"]) for c in results+interpolations)
        report = {"seed": SEED, "clock_case_count": len(results), "map_query_count": sum(len(c["queries"]) for c in results),
                  "interpolation_case_count": len(interpolations), "defect_count": defect_count,
                  "clock_cases": results, "interpolation_cases": interpolations}
        (output_directory / "comparison.json").write_text(json.dumps(encoded(report), indent=2, allow_nan=True)+"\n")
        print(json.dumps({k: report[k] for k in ("seed", "clock_case_count", "map_query_count", "interpolation_case_count", "defect_count")}))
        for case in results+interpolations:
            if case["defects"]:
                print(json.dumps(encoded({"name": case["name"], "defects": case["defects"]})))
        return 1 if defect_count else 0
    print(f"Wrote {len(fixtures)} clock and {len(interpolation_cases())} interpolation mathematical reference cases, seed {SEED}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
