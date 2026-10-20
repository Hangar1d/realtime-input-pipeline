import Foundation

enum FixtureError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let message): return message } }
}

struct SyntheticOptions: Codable, Equatable, Sendable {
    var frames = 60
    var cameraHz = 30.0
    var imuHz = 200.0
    var driftPPM = 120.0
    var offsetNS: Int64 = 2_000_000_000
    var jitterNS: Int64 = 2_000_000
    var missingEvery = 17
    var reorderDepth = 4
    var anchorOutlierNS: Int64 = 1_000_000
    var seed: UInt64 = 7

    func validate() throws {
        guard (1...512).contains(frames), cameraHz.isFinite, imuHz.isFinite,
              (1...240).contains(cameraHz), (1...2_000).contains(imuHz),
              driftPPM.isFinite, abs(driftPPM) <= 5_000,
              (-10_000_000_000...10_000_000_000).contains(offsetNS),
              (0...100_000_000).contains(jitterNS), (0...10_000).contains(missingEvery),
              (1...64).contains(reorderDepth), (0...100_000_000).contains(anchorOutlierNS),
              Double(frames - 1) / cameraHz <= 30 else {
            throw FixtureError.invalid("synthetic options exceed the documented bounds")
        }
        let samples = ceil((Double(frames - 1) / cameraHz + 2 / imuHz) * imuHz) + 1
        guard samples + Double(frames) + 9 <= 20_000 else {
            throw FixtureError.invalid("synthetic fixture would exceed 20000 input records")
        }
    }
}

struct FixtureInput: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case anchor, imu, frame, source }
    var kind: Kind
    var sequence: UInt64?
    var deviceNS: Int64?
    var referenceNS: Int64?
    var x: Double?
    var y: Double?
    var z: Double?
    var source: String?
    var state: String?
    var evidence: String?
    // Synthetic delivery metadata only. Never used as a calibration anchor.
    var arrivalReferenceNS: Int64?

    func validate() throws {
        if let time = deviceNS, time < 0 { throw FixtureError.invalid("negative device timestamp") }
        if let time = referenceNS, time < 0 { throw FixtureError.invalid("negative reference timestamp") }
        if let time = arrivalReferenceNS, time < 0 { throw FixtureError.invalid("negative arrival timestamp") }
        switch kind {
        case .anchor:
            guard sequence != nil, deviceNS != nil, referenceNS != nil,
                  evidence == "trustedSameInstant", x == nil, y == nil, z == nil,
                  source == nil, state == nil else { throw FixtureError.invalid("invalid trusted anchor record") }
        case .imu:
            guard sequence != nil, deviceNS != nil, referenceNS == nil,
                  let x, let y, let z, x.isFinite, y.isFinite, z.isFinite,
                  source == nil, state == nil, evidence == nil else { throw FixtureError.invalid("invalid IMU record") }
        case .frame:
            guard sequence != nil, referenceNS != nil, deviceNS == nil,
                  x == nil, y == nil, z == nil, source == nil, state == nil, evidence == nil else {
                throw FixtureError.invalid("invalid camera frame record")
            }
        case .source:
            guard source == "imu" || source == "camera",
                  state == "active" || state == "idle" || state == "stopped",
                  sequence == nil, deviceNS == nil, referenceNS == nil,
                  x == nil, y == nil, z == nil, evidence == nil else { throw FixtureError.invalid("invalid source control") }
        }
    }
}

struct ReplayFixture: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var label: String
    var synthetic: SyntheticOptions?
    var inputs: [FixtureInput]

    var frameCount: Int { inputs.filter { $0.kind == .frame }.count }

    func validate() throws {
        guard schemaVersion == 1 else { throw FixtureError.invalid("unsupported fixture schema") }
        guard !label.isEmpty, label.utf8.count <= 128,
              !inputs.isEmpty, inputs.count <= 20_000, frameCount <= 512 else {
            throw FixtureError.invalid("fixture label/count exceeds limits")
        }
        try synthetic?.validate()
        for input in inputs { try input.validate() }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1_024 * 1_024 else { throw FixtureError.invalid("fixture exceeds 8 MiB") }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.invalid("fixture must be a JSON object")
        }
        try checkKeys(root, allowed: ["schemaVersion", "label", "synthetic", "inputs"])
        if let options = root["synthetic"] as? [String: Any] {
            try checkKeys(options, allowed: ["frames", "cameraHz", "imuHz", "driftPPM", "offsetNS", "jitterNS", "missingEvery", "reorderDepth", "anchorOutlierNS", "seed"])
        }
        if let inputs = root["inputs"] as? [[String: Any]] {
            for input in inputs {
                try checkKeys(input, allowed: ["kind", "sequence", "deviceNS", "referenceNS", "x", "y", "z", "source", "state", "evidence", "arrivalReferenceNS"])
            }
        }
        let fixture = try JSONDecoder().decode(Self.self, from: data)
        try fixture.validate()
        return fixture
    }

    private static func checkKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw FixtureError.invalid("unknown fixture field") }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

private struct FixtureRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func bounded(_ bound: UInt64) -> UInt64 {
        precondition(bound > 0)
        let threshold = (0 &- bound) % bound
        while true {
            let value = next()
            if value >= threshold { return value % bound }
        }
    }
}

func syntheticFixture(_ options: SyntheticOptions) throws -> ReplayFixture {
    try options.validate()
    let deviceOrigin: Int64 = 1_000_000_000_000
    let referenceOrigin = deviceOrigin + options.offsetNS
    let slope = 1 + options.driftPPM * 1e-6
    let startDelta: Int64 = 8_100_000_000
    let endDelta = startDelta + Int64((Double(options.frames - 1) / options.cameraHz * 1e9).rounded())
    var inputs: [FixtureInput] = []
    for index in 0..<9 {
        let deviceDelta = Int64(index) * 1_000_000_000
        let outlier = index == 4 ? options.anchorOutlierNS : 0
        inputs.append(.init(kind: .anchor, sequence: UInt64(index), deviceNS: deviceOrigin + deviceDelta,
                            referenceNS: referenceOrigin + Int64((slope * Double(deviceDelta)).rounded()) + outlier,
                            evidence: "trustedSameInstant"))
    }
    var random = FixtureRandom(state: options.seed)
    func arrival(_ time: Int64, random: inout FixtureRandom) -> Int64 {
        let width = UInt64(options.jitterNS * 2 + 1)
        return time + Int64(random.bounded(width)) - options.jitterNS
    }
    var deliveries: [FixtureInput] = []
    let step = 1e9 / options.imuHz
    let sampleCount = Int(ceil(Double(endDelta - startDelta) / step)) + 3
    for index in 0..<sampleCount {
        if options.missingEvery > 0 && (index + 1) % options.missingEvery == 0 { continue }
        let delta = startDelta + Int64((Double(index - 1) * step).rounded())
        let reference = referenceOrigin + delta
        let device = deviceOrigin + Int64((Double(delta) / slope).rounded())
        let seconds = Double(delta - startDelta) / 1e9
        deliveries.append(.init(kind: .imu, sequence: UInt64(index), deviceNS: device,
                                x: seconds, y: 2 * seconds + 1, z: -seconds,
                                arrivalReferenceNS: arrival(reference, random: &random)))
    }
    for index in 0..<options.frames {
        let reference = referenceOrigin + startDelta + Int64((Double(index) / options.cameraHz * 1e9).rounded())
        deliveries.append(.init(kind: .frame, sequence: UInt64(index), referenceNS: reference,
                                arrivalReferenceNS: arrival(reference, random: &random)))
    }
    deliveries.sort {
        if $0.arrivalReferenceNS != $1.arrivalReferenceNS { return $0.arrivalReferenceNS! < $1.arrivalReferenceNS! }
        if $0.kind != $1.kind { return $0.kind == .imu }
        return $0.sequence! < $1.sequence!
    }
    // Reversal is bounded by a count, independent of wall-clock task scheduling.
    for start in stride(from: 0, to: deliveries.count, by: options.reorderDepth) {
        let end = min(start + options.reorderDepth, deliveries.count)
        inputs.append(contentsOf: deliveries[start..<end].reversed())
    }
    let fixture = ReplayFixture(label: "synthetic-camera-imu", synthetic: options, inputs: inputs)
    try fixture.validate()
    return fixture
}
