import Foundation

private final class BundleToken {}

/// Runs the `jev` binary built next to this test bundle.
enum CLI {
    static let binary: URL? = {
        if let path = ProcessInfo.processInfo.environment["JEV_BINARY"] { return URL(fileURLWithPath: path) }
        let candidate = Bundle(for: BundleToken.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("jev")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }()

    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `jev` with `args`, feeding `stdin` (closed afterwards so the
    /// binary never waits on a terminal).
    static func run(_ args: [String], stdin: String = "") throws -> Result {
        guard let binary else { throw CLIError.missingBinary }
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp
        try p.run()
        inp.fileHandleForWriting.write(Data(stdin.utf8))
        try inp.fileHandleForWriting.close()
        // Drain stderr concurrently so a full pipe can never block the child.
        let errData = LockedData()
        let reader = Thread { errData.set(err.fileHandleForReading.readDataToEndOfFile()) }
        reader.start()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        while !errData.isSet { usleep(1_000) }
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData.value, as: UTF8.self))
    }

    enum CLIError: Error, CustomStringConvertible {
        case missingBinary
        var description: String { "jev binary not found next to the test bundle; set JEV_BINARY" }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ d: Data) { lock.withLock { data = d } }
    var isSet: Bool { lock.withLock { data != nil } }
    var value: Data { lock.withLock { data ?? Data() } }
}

/// A temporary file that lives for the test run.
func tempFile(_ contents: String, ext: String = "json") throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("jev-test-\(UUID().uuidString).\(ext)")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}
