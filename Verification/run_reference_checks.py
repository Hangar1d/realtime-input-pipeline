#!/usr/bin/env python3
"""Build a separate core shared library and run the standard-library math oracle."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command):
    result = subprocess.run([str(value) for value in command], text=True, capture_output=True)
    return {"command": [str(value) for value in command], "exit_code": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", required=True, type=Path,
                        help="Directory for the test library, generated fixtures and evidence")
    parser.add_argument("--compiler", help="C++ compiler executable or path; defaults to clang++ on macOS, c++ on Linux")
    args = parser.parse_args()
    system = platform.system()
    if system not in ("Darwin", "Linux"):
        parser.error(f"unsupported platform {system!r}; this runner supports macOS/Linux. Use the native CMake/CTest workflow on Windows.")
    compiler = shutil.which(args.compiler or ("clang++" if system == "Darwin" else "c++"))
    if compiler is None:
        parser.error("C++ compiler not found; install a C++17 compiler or provide --compiler EXECUTABLE")
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=True)
    folder = Path(__file__).resolve().parent
    project = folder.parent
    source = project / "Sources/PipelineCore/PipelineCore.cpp"
    header = project / "Sources/PipelineCore/include/PipelineCore.h"
    checker = folder / "reference_clock.py"
    library = output / ("libPipelineCore-reference.dylib" if system == "Darwin" else "libPipelineCore-reference.so")
    evidence = {
        "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "platform": platform.platform(), "machine": platform.machine(), "python": sys.version,
        "compiler": run([compiler, "--version"]),
        "source_sha256_before_build": digest(source), "header_sha256": digest(header),
        "checker_sha256": digest(checker),
    }
    shared_flags = ["-dynamiclib"] if system == "Darwin" else ["-shared", "-fPIC"]
    evidence["build"] = run([compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Wpedantic",
                             *shared_flags, "-I", header.parent, source, "-o", library])
    evidence["source_sha256_after_build"] = digest(source)
    evidence["source_unchanged_during_build"] = evidence["source_sha256_before_build"] == evidence["source_sha256_after_build"]
    passed = evidence["build"]["exit_code"] == 0 and evidence["source_unchanged_during_build"]
    if passed:
        evidence["library_sha256"] = digest(library)
        evidence["comparison"] = run([sys.executable, checker, "--output-directory", output, "--library", library])
        passed = evidence["comparison"]["exit_code"] == 0
        report_path = output / "comparison.json"
        if report_path.exists():
            report = json.loads(report_path.read_text())
            evidence["summary"] = {key: report[key] for key in (
                "seed", "clock_case_count", "map_query_count", "interpolation_case_count", "defect_count")}
    evidence["passed"] = passed
    evidence["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    evidence_path = output / "build-and-run-evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2)+"\n")
    if passed:
        print(json.dumps(evidence["summary"]))
        print(f"PASS: generated evidence in {output}")
        return 0
    print(f"FAIL: inspect {evidence_path}", file=sys.stderr)
    if not evidence["source_unchanged_during_build"]:
        print("Core source changed during compilation; rerun against a stable source revision.", file=sys.stderr)
    for stage in ("build", "comparison"):
        if evidence.get(stage, {}).get("exit_code", 0) != 0:
            print(evidence[stage]["stdout"] + evidence[stage]["stderr"], file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
