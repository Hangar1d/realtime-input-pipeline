import Foundation

struct Arguments {
    let command: String
    let positionals: [String]
    let options: [String: String]
    init(_ values: [String]) throws {
        guard let command = values.first else { throw FixtureError.invalid(Self.usage) }
        self.command = command
        var positionals: [String] = []
        var options: [String: String] = [:]
        var index = 1
        let known: Set<String> = ["--frames", "--camera-hz", "--imu-hz", "--drift-ppm", "--offset-ns",
                                  "--jitter-ns", "--missing-every", "--reorder-depth", "--anchor-outlier-ns",
                                  "--seed", "--output", "--deterministic-output", "--lateness-ns", "--max-gap-ns"]
        while index < values.count {
            let value = values[index]
            if value.hasPrefix("--") {
                guard known.contains(value), options[value] == nil, index + 1 < values.count,
                      !values[index + 1].hasPrefix("--") else {
                    throw FixtureError.invalid("unknown, duplicate, or incomplete option: \(value)")
                }
                options[value] = values[index + 1]
                index += 2
            } else { positionals.append(value); index += 1 }
        }
        self.positionals = positionals
        self.options = options
    }
    static let usage = """
    usage:
      input-pipeline generate --output FIXTURE [synthetic options]
      input-pipeline demo [synthetic options] [--output DIAGNOSTICS] [--deterministic-output RESULT]
      input-pipeline replay FIXTURE [--output DIAGNOSTICS] [--deterministic-output RESULT]
    synthetic options: --frames --camera-hz --imu-hz --drift-ppm --offset-ns --jitter-ns
      --missing-every --reorder-depth --anchor-outlier-ns --seed
    runtime options: --lateness-ns --max-gap-ns
    Output paths must be new. Input is limited to 8 MiB / 20000 records / 512 frames.
    """
    func value<T: LosslessStringConvertible>(_ key: String, default fallback: T) throws -> T {
        guard let raw = options[key] else { return fallback }
        guard let value = T(raw) else { throw FixtureError.invalid("invalid number for \(key)") }
        return value
    }
    func synthetic() throws -> SyntheticOptions {
        var result = SyntheticOptions()
        result.frames = try value("--frames", default: result.frames)
        result.cameraHz = try value("--camera-hz", default: result.cameraHz)
        result.imuHz = try value("--imu-hz", default: result.imuHz)
        result.driftPPM = try value("--drift-ppm", default: result.driftPPM)
        result.offsetNS = try value("--offset-ns", default: result.offsetNS)
        result.jitterNS = try value("--jitter-ns", default: result.jitterNS)
        result.missingEvery = try value("--missing-every", default: result.missingEvery)
        result.reorderDepth = try value("--reorder-depth", default: result.reorderDepth)
        result.anchorOutlierNS = try value("--anchor-outlier-ns", default: result.anchorOutlierNS)
        result.seed = try value("--seed", default: result.seed)
        try result.validate()
        return result
    }
}

private func readFixture(_ path: String) throws -> ReplayFixture {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let data = try file.read(upToCount: 8 * 1_024 * 1_024 + 1) ?? Data()
    return try ReplayFixture.decode(data)
}

private func writeNew(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
}

@main
struct InputPipelineMain {
    static func main() async {
        do {
            if CommandLine.arguments.count == 2 && CommandLine.arguments.dropFirst().first == "--help" {
                print(Arguments.usage)
                return
            }
            let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let fixture: ReplayFixture
            switch args.command {
            case "generate", "demo":
                guard args.positionals.isEmpty else { throw FixtureError.invalid(Arguments.usage) }
                fixture = try syntheticFixture(args.synthetic())
            case "replay":
                guard args.positionals.count == 1 else { throw FixtureError.invalid(Arguments.usage) }
                let syntheticKeys: Set<String> = ["--frames", "--camera-hz", "--imu-hz", "--drift-ppm", "--offset-ns", "--jitter-ns", "--missing-every", "--reorder-depth", "--anchor-outlier-ns", "--seed"]
                guard Set(args.options.keys).isDisjoint(with: syntheticKeys) else {
                    throw FixtureError.invalid("replay takes recorded input, not synthetic-generation options")
                }
                fixture = try readFixture(args.positionals[0])
            default: throw FixtureError.invalid(Arguments.usage)
            }
            if args.command == "generate" {
                guard let path = args.options["--output"], args.options["--deterministic-output"] == nil,
                      args.options["--lateness-ns"] == nil, args.options["--max-gap-ns"] == nil else {
                    throw FixtureError.invalid("generate requires only a fixture output and synthetic options")
                }
                try writeNew(fixture.encoded(), to: path)
                print("fixture=\(path) inputs=\(fixture.inputs.count) frames=\(fixture.frameCount)")
                return
            }
            let diagnostics = try await runFixture(fixture,
                latenessNS: args.value("--lateness-ns", default: Int64(20_000_000)),
                maxGapNS: args.value("--max-gap-ns", default: Int64(30_000_000)))
            if let path = args.options["--output"] { try writeNew(canonicalJSON(diagnostics), to: path) }
            if let path = args.options["--deterministic-output"] {
                try writeNew(canonicalJSON(diagnostics.deterministic), to: path)
            }
            let frames = diagnostics.deterministic.frames
            let available = frames.filter(\.available).count
            let core = diagnostics.deterministic.core
            let host = diagnostics.orchestration
            print("frames=\(frames.count)/\(fixture.frameCount) available=\(available) exact=\(core.exactOutputs) interpolated=\(core.interpolatedOutputs)")
            print("drift_ppm=\(diagnostics.deterministic.clock.driftPPM) inliers=\(diagnostics.deterministic.clock.inliers)/\(diagnostics.deterministic.clock.anchors) residual_rms_ns=\(diagnostics.deterministic.clock.residualRMSNS)")
            print("core_rejected_late=\(core.rejectedLate) core_rejected_capacity=\(core.rejectedCapacity) reorder_peak=\(core.queueHighWater)")
            print("ingress_accepted=\(host.ingress.accepted) ingress_dropped=\(host.ingress.full) output_dropped=\(host.output.dropped)")
            print("host_service_samples=\(host.serviceTime.count) mean_ns=\(host.serviceTime.meanNS) variance_ns2=\(host.serviceTime.sampleVarianceNS2) queue_wait_mean_ns=\(host.queueWait.meanNS)")
            print("Timing is host processing/queue wait, not sensor-to-output latency or a benchmark.")
        } catch {
            let message = "error: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Foundation.exit(1)
        }
    }
}
