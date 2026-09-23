import Foundation

/// Timings from a physical device, written to a file the cable can fetch.
///
/// ── Why this exists ──
///
/// A real iPhone took ~15 seconds to show a cached screen and the
/// simulator did not. `log stream --device` no longer exists on this
/// macOS, `devicectl` has no console, and attaching Xcode changes the
/// thing being measured. Six rounds of reasoning from the code produced
/// six wrong answers; the first trace pulled off the phone produced the
/// right one in a single read — `/api/auth/me` was the only uncached read
/// in the app and the first thing awaited on launch.
///
/// ── Read this before trusting it ──
///
/// Every timestamp is relative to the FIRST mark in the process, not to
/// process start. That is a real blind spot: it cannot see anything that
/// happens before the first call, which is exactly where a launch stall
/// would live. It measured the wrong side of the problem once already.
///
/// The file accumulates across launches; a `+0ms` line means a new
/// process. Absence of a mark is NOT evidence the code did not run — it
/// may equally mean the recorder stopped, which also happened here.
///
/// ── Debug only ──
///
/// Compiled out of release entirely: no file, no writes, no call sites.
/// Kept rather than deleted because the class of bug it found — works in
/// the simulator, fails on hardware — is one this app has hit once and
/// will hit again, and rebuilding the tool costs more than carrying it.
///
/// Usage: `Trace.mark("…")`, then
/// `xcrun devicectl device copy from --device <id> --domain-type
/// appDataContainer --domain-identifier bg.agrent.app --user mobile
/// --source Documents/diag.log --destination <path>`
enum Trace {
#if DEBUG
    private static let url: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("diag.log")
    }()

    private static let start = Date()
    private static let lock = NSLock()

    static func mark(_ what: String) {
        lock.lock()
        defer { lock.unlock() }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let line = "+\(ms)ms  \(what)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
#else
    /// A no-op in release, so call sites cost nothing and ship nothing.
    @inline(__always)
    static func mark(_ what: @autoclosure () -> String) {}
#endif
}
