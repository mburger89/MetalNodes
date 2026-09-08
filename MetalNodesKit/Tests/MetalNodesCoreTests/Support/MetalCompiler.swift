import Foundation
import Testing

/// The one `xcrun metal` seam for every test that proves generated text is real MSL (spec §25.4).
/// Ten test files carried their own copy of this probe and compile step before M9.
enum MetalCompiler {
    struct Result {
        let status: Int32
        let log: String
    }

    /// True when `xcrun -sdk macosx metal --version` succeeds. Probed once per process — the
    /// toolchain does not appear mid-run.
    static let isAvailable: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-sdk", "macosx", "metal", "--version"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    /// Writes `source` to a fresh temporary directory as `fileName` and runs
    /// `xcrun -sdk macosx metal <extraArgs> -c <file> -o out.air`. `extraArgs` is spliced ahead of
    /// `-c` so a caller can pin `-mmacosx-version-min=…`.
    static func compile(_ source: String, fileName: String = "test.metal", extraArgs: [String] = []) throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-metal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(fileName)
        try source.write(to: url, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["-sdk", "macosx", "metal"] + extraArgs
            + ["-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return Result(status: p.terminationStatus, log: log)
    }

    /// Records an issue carrying the compiler's stderr when `source` does not compile. Skips
    /// silently (returns true) when the toolchain is not installed, matching every pre-M9 site.
    @discardableResult
    static func expectCompiles(_ source: String, extraArgs: [String] = [], _ comment: String = "",
                               sourceLocation: SourceLocation = #_sourceLocation) throws -> Bool {
        guard isAvailable else { return true }
        let r = try compile(source, extraArgs: extraArgs)
        #expect(r.status == 0, Comment(rawValue: "\(comment)\n\(r.log)"), sourceLocation: sourceLocation)
        return r.status == 0
    }
}
