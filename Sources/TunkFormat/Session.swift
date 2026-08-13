import Foundation
import TunkCore

// Readers and writers for the on-disk session format. This file is the contract
// in FORMAT.md expressed as code; every other subsystem goes through it rather
// than parsing files itself.

public enum Category: String, Codable, CaseIterable, Sendable {
    case tapPalmrest = "tap_palmrest"
    case tapDeck = "tap_deck"
    case tapBottom = "tap_bottom"
    case typing
    case trackpad
    case confoundMug = "confound_mug"
    case confoundLid = "confound_lid"
    case confoundPhone = "confound_phone"
    case confoundMusic = "confound_music"
    case confoundFootfall = "confound_footfall"
    case confoundHandling = "confound_handling"
    case idle

    /// Tap categories carry deliberate gestures; everything else must never fire.
    public var isTapCategory: Bool {
        switch self {
        case .tapPalmrest, .tapDeck, .tapBottom: return true
        default: return false
        }
    }

    public var isConfound: Bool { rawValue.hasPrefix("confound_") }

    /// Human label for prompts and reports.
    public var title: String {
        switch self {
        case .tapPalmrest: return "double-taps on the palm rest"
        case .tapDeck: return "double-taps on the keyboard deck"
        case .tapBottom: return "double-taps on the bottom case"
        case .typing: return "continuous typing"
        case .trackpad: return "trackpad clicks and hard taps"
        case .confoundMug: return "setting a mug down"
        case .confoundLid: return "hard key presses and lid nudges"
        case .confoundPhone: return "phone buzzing on the desk"
        case .confoundMusic: return "bass-heavy music through the desk"
        case .confoundFootfall: return "footfall on a timber floor"
        case .confoundHandling: return "repositioning, lifting, cables"
        case .idle: return "machine untouched"
        }
    }
}

public enum Surface: String, Codable, CaseIterable, Sendable {
    case desk, soft, lap

    public var title: String {
        switch self {
        case .desk: return "hard desk"
        case .soft: return "soft surface (bed or cushion)"
        case .lap: return "on the lap"
        }
    }
}

public enum Split: String, Codable, Sendable { case train, test }

public struct MachineInfo: Codable, Sendable {
    public var model: String
    public var chip: String
    public var os: String

    public init(model: String, chip: String, os: String) {
        self.model = model
        self.chip = chip
        self.os = os
    }

    /// Read the real values off this machine so every session records what it
    /// was captured on.
    public static func current() -> MachineInfo {
        func sysctl(_ name: String) -> String {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: buf)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return MachineInfo(
            model: sysctl("hw.model"),
            chip: sysctl("machdep.cpu.brand_string"),
            os: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        )
    }
}

public struct SessionMeta: Codable, Sendable {
    public var schema: Int
    public var sessionId: String
    public var category: Category
    public var surface: Surface
    public var epochMachNs: Int64
    public var epochWallIso: String
    public var reportIntervalUs: Int64
    public var nominalRateHz: Double
    public var nominalIntervalNs: Int64
    public var durationNs: Int64
    public var sampleCount: Int
    public var machine: MachineInfo
    public var split: Split
    public var expectedTriggers: Int
    public var operatorNotes: String
    public var toolVersion: String

    enum CodingKeys: String, CodingKey {
        case schema
        case sessionId = "session_id"
        case category, surface
        case epochMachNs = "epoch_mach_ns"
        case epochWallIso = "epoch_wall_iso"
        case reportIntervalUs = "report_interval_us"
        case nominalRateHz = "nominal_rate_hz"
        case nominalIntervalNs = "nominal_interval_ns"
        case durationNs = "duration_ns"
        case sampleCount = "sample_count"
        case machine, split
        case expectedTriggers = "expected_triggers"
        case operatorNotes = "operator_notes"
        case toolVersion = "tool_version"
    }

    public init(schema: Int = 1, sessionId: String, category: Category, surface: Surface,
                epochMachNs: Int64, epochWallIso: String, reportIntervalUs: Int64,
                nominalRateHz: Double, nominalIntervalNs: Int64, durationNs: Int64,
                sampleCount: Int, machine: MachineInfo, split: Split, expectedTriggers: Int,
                operatorNotes: String, toolVersion: String) {
        self.schema = schema
        self.sessionId = sessionId
        self.category = category
        self.surface = surface
        self.epochMachNs = epochMachNs
        self.epochWallIso = epochWallIso
        self.reportIntervalUs = reportIntervalUs
        self.nominalRateHz = nominalRateHz
        self.nominalIntervalNs = nominalIntervalNs
        self.durationNs = durationNs
        self.sampleCount = sampleCount
        self.machine = machine
        self.split = split
        self.expectedTriggers = expectedTriggers
        self.operatorNotes = operatorNotes
        self.toolVersion = toolVersion
    }
}

// MARK: - Labels and marks

public enum TapIntent: String, Codable, Sendable { case double, single, none }

public enum LabelConfidence: String, Codable, Sendable {
    case promptWindow = "prompt_window"
    case autoRefined = "auto_refined"
    case humanVerified = "human_verified"
}

public struct TapLabel: Codable, Sendable {
    public var tNs: Int64
    public var kind: String
    public var group: Int
    public var indexInGroup: Int
    public var intent: TapIntent
    public var confidence: LabelConfidence

    enum CodingKeys: String, CodingKey {
        case tNs = "t_ns"
        case kind, group
        case indexInGroup = "index_in_group"
        case intent, confidence
    }

    public init(tNs: Int64, group: Int, indexInGroup: Int, intent: TapIntent,
                confidence: LabelConfidence) {
        self.tNs = tNs
        self.kind = "tap_onset"
        self.group = group
        self.indexInGroup = indexInGroup
        self.intent = intent
        self.confidence = confidence
    }
}

public struct Mark: Codable, Sendable {
    public var tNs: Int64
    public var kind: String
    public var text: String?
    public var group: Int?

    enum CodingKeys: String, CodingKey {
        case tNs = "t_ns"
        case kind, text, group
    }

    public init(tNs: Int64, kind: String, text: String? = nil, group: Int? = nil) {
        self.tNs = tNs
        self.kind = kind
        self.text = text
        self.group = group
    }
}

public struct InputRecord: Codable, Sendable {
    public var tNs: Int64
    public var kind: InputEventKind
    public var code: Int32?
    public var count: Int?

    enum CodingKeys: String, CodingKey {
        case tNs = "t_ns"
        case kind, code, count
    }

    public init(tNs: Int64, kind: InputEventKind, code: Int32? = nil, count: Int? = nil) {
        self.tNs = tNs
        self.kind = kind
        self.code = code
        self.count = count
    }

    public var event: InputEvent { InputEvent(tNs: tNs, kind: kind, code: code ?? -1) }
}

// MARK: - Errors

public enum FormatError: Error, CustomStringConvertible {
    case truncatedAccel(path: String, size: Int)
    case missingFile(String)
    case splitMismatch(sessionId: String, declared: Split, directory: Split)
    case nonMonotonic(path: String, atIndex: Int)

    public var description: String {
        switch self {
        case .truncatedAccel(let p, let s):
            return "accel.bin at \(p) is \(s) bytes, not a multiple of \(AccelSample.byteWidth)"
        case .missingFile(let p):
            return "missing required file: \(p)"
        case .splitMismatch(let id, let declared, let dir):
            return "session \(id) declares split=\(declared.rawValue) but sits in a \(dir.rawValue) directory"
        case .nonMonotonic(let p, let i):
            return "\(p): timestamps go backwards at record \(i)"
        }
    }
}

// MARK: - Binary accelerometer stream

/// Streaming writer for `accel.bin`. Buffers to keep the sensor callback cheap.
public final class AccelWriter {
    private let handle: FileHandle
    private var buffer: Data
    private let flushBytes: Int

    public private(set) var count = 0
    public private(set) var firstNs: Int64 = 0
    public private(set) var lastNs: Int64 = 0

    public init(url: URL, flushBytes: Int = 1 << 16) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        buffer = Data(capacity: flushBytes + AccelSample.byteWidth)
        self.flushBytes = flushBytes
    }

    public func append(_ s: AccelSample) {
        withUnsafeBytes(of: s.tNs.littleEndian) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: s.arrivalNs.littleEndian) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: s.x.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: s.y.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        withUnsafeBytes(of: s.z.bitPattern.littleEndian) { buffer.append(contentsOf: $0) }
        if count == 0 { firstNs = s.tNs }
        lastNs = s.tNs
        count += 1
        if buffer.count >= flushBytes { flush() }
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    public func close() {
        flush()
        try? handle.close()
    }
}

public enum AccelReader {
    /// Load a whole stream. Sessions are minutes long at 796 Hz, so a few tens of
    /// megabytes at worst; the harness wants random access anyway.
    public static func read(url: URL) throws -> [AccelSample] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count % AccelSample.byteWidth == 0 else {
            throw FormatError.truncatedAccel(path: url.path, size: data.count)
        }
        let n = data.count / AccelSample.byteWidth
        var out = [AccelSample]()
        out.reserveCapacity(n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let base = i * AccelSample.byteWidth
                let t = Int64(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: Int64.self))
                let a = Int64(littleEndian: raw.loadUnaligned(fromByteOffset: base + 8, as: Int64.self))
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 16, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 20, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 24, as: UInt32.self)))
                out.append(AccelSample(tNs: t, arrivalNs: a, x: x, y: y, z: z))
            }
        }
        return out
    }
}

// MARK: - JSONL

public enum JSONL {
    nonisolated(unsafe) public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    nonisolated(unsafe) public static let decoder = JSONDecoder()

    public static func write<T: Encodable>(_ items: [T], to url: URL) throws {
        var out = Data()
        for item in items {
            out.append(try encoder.encode(item))
            out.append(0x0A)
        }
        try out.write(to: url)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var out = [T]()
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            out.append(try decoder.decode(T.self, from: Data(line)))
        }
        return out
    }
}

/// Appends JSONL as it goes, so a crashed capture still leaves usable data.
public final class JSONLWriter<T: Encodable> {
    private let handle: FileHandle

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    public func append(_ item: T) throws {
        var data = try JSONL.encoder.encode(item)
        data.append(0x0A)
        handle.write(data)
    }

    public func close() { try? handle.close() }
}

// MARK: - Session

/// One recording on disk, loaded lazily: metadata is cheap, samples are not.
public struct Session: Sendable {
    public let directory: URL
    public let meta: SessionMeta

    public init(directory: URL) throws {
        self.directory = directory
        let metaURL = directory.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else {
            throw FormatError.missingFile(metaURL.path)
        }
        let d = JSONDecoder()
        self.meta = try d.decode(SessionMeta.self, from: Data(contentsOf: metaURL))
    }

    public var accelURL: URL { directory.appendingPathComponent("accel.bin") }
    public var inputURL: URL { directory.appendingPathComponent("input.jsonl") }
    public var labelsURL: URL { directory.appendingPathComponent("labels.jsonl") }
    public var marksURL: URL { directory.appendingPathComponent("marks.jsonl") }

    public func samples() throws -> [AccelSample] { try AccelReader.read(url: accelURL) }
    public func inputs() throws -> [InputRecord] { try JSONL.read(InputRecord.self, from: inputURL) }
    public func labels() throws -> [TapLabel] { try JSONL.read(TapLabel.self, from: labelsURL) }
    public func marks() throws -> [Mark] { try JSONL.read(Mark.self, from: marksURL) }

    /// Labelled gestures, grouped and sorted, ascending by first onset.
    public func labelGroups() throws -> [[TapLabel]] {
        let all = try labels()
        let byGroup = Dictionary(grouping: all, by: \.group)
        return byGroup.keys.sorted().map { key in
            byGroup[key]!.sorted { $0.indexInGroup < $1.indexInGroup }
        }
    }

    public var durationSeconds: Double { Double(meta.durationNs) / 1e9 }

    /// Every session found under `root`, sorted by id. Enforces the split rule so
    /// a mislabelled directory cannot silently leak test data into tuning.
    public static func discover(root: URL, expecting split: Split? = nil) throws -> [Session] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var out = [Session]()
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.appendingPathComponent("meta.json").path, isDirectory: &isDir) else { continue }
            let s = try Session(directory: entry)
            if let split, s.meta.split != split {
                throw FormatError.splitMismatch(sessionId: s.meta.sessionId, declared: s.meta.split, directory: split)
            }
            out.append(s)
        }
        return out
    }
}
