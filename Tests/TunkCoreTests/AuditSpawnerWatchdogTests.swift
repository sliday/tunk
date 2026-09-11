import Foundation
import XCTest
@testable import TunkEmit

/// The spawner's contract says a shortcut that trips the watchdog is left
/// running. A closed stderr read end breaks that silently: the child's next
/// write to fd 2 has no reader, so the kernel delivers SIGPIPE and the rest of
/// the shortcut never runs.
///
/// SAFETY: as in `ActionTests`, the executable is a throwaway shell script in
/// a temp directory. `shortcuts run` is never invoked.
final class AuditSpawnerWatchdogTests: XCTestCase {

    private struct Child {
        let dir: String
        var script: String { dir + "/child.sh" }
        var status: String { dir + "/status" }
        var marker: String { dir + "/done" }
    }

    /// Sleeps past the watchdog, writes one line to stderr, then leaves a
    /// marker. The inner exit status is recorded by the outer shell so a
    /// SIGPIPE death (128 + 13 = 141) is visible even though the child is
    /// deliberately never waited on by the spawner.
    private func makeChild() throws -> Child {
        let dir = NSTemporaryDirectory() + "tunk-audit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let child = Child(dir: dir)
        let body = "#!/bin/sh\n"
            + "( sleep 0.6; echo 'still going' >&2; touch \"\(child.marker)\"; exit 0 )\n"
            + "echo $? > \"\(child.status)\"\n"
        try body.write(toFile: child.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: child.script)
        return child
    }

    private func run(_ spawner: ShortcutsProcessSpawner, name: String) throws -> ShortcutOutcome {
        let box = AuditOutcomeBox()
        let exp = expectation(description: "outcome for \(name)")
        spawner.spawn(shortcut: name) { outcome in
            box.set(outcome)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return try XCTUnwrap(box.value)
    }

    private func waitForStatus(_ child: Child) -> String? {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: child.status), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return (try? String(contentsOfFile: child.status, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testChildThatOutlivesTheWatchdogSurvivesItsNextStderrWrite() throws {
        let child = try makeChild()
        defer { try? FileManager.default.removeItem(atPath: child.dir) }
        let spawner = ShortcutsProcessSpawner(executable: child.script, watchdogSeconds: 0.2)

        let outcome = try run(spawner, name: "Outlives")
        guard case .shortcutTimedOut? = outcome.error else {
            return XCTFail("wrong error: \(String(describing: outcome.error))")
        }

        let status = waitForStatus(child)
        XCTAssertEqual(status, "0",
                       "inner exit status \(status ?? "missing"); 141 is 128+SIGPIPE, meaning "
                       + "the watchdog closed the stderr reader and the child died on its "
                       + "next write instead of being left running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.marker),
                      "the line after the stderr write never ran")
    }

    /// The reason the watchdog path used to close the reader was a descriptor
    /// leak across hung spawns. Leaving the reader attached must not bring it
    /// back: once the children exit, every read end is released.
    func testHungSpawnsReleaseTheirDescriptorsOnceTheChildrenExit() throws {
        let script = NSTemporaryDirectory() + "tunk-audit-" + UUID().uuidString + ".sh"
        try "#!/bin/sh\nsleep 0.5\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let before = openDescriptorCount()
        let spawner = ShortcutsProcessSpawner(executable: script, watchdogSeconds: 0.1)
        let all = expectation(description: "every watchdog fired")
        all.expectedFulfillmentCount = 30
        for i in 0..<30 {
            spawner.spawn(shortcut: "Hung \(i)") { _ in all.fulfill() }
        }
        wait(for: [all], timeout: 5)
        let whileHung = openDescriptorCount()

        Thread.sleep(forTimeInterval: 1.5)
        let after = openDescriptorCount()
        XCTAssertLessThanOrEqual(after, before + 2,
                                 "descriptors before \(before), while hung \(whileHung), "
                                 + "after the children exited \(after)")
    }

    private func openDescriptorCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// Control: the same child, no watchdog. Proves the script itself is sound.
    func testSameChildFinishesWhenNoWatchdogFires() throws {
        let child = try makeChild()
        defer { try? FileManager.default.removeItem(atPath: child.dir) }
        let spawner = ShortcutsProcessSpawner(executable: child.script, watchdogSeconds: 0)

        let outcome = try run(spawner, name: "Finishes")
        XCTAssertTrue(outcome.succeeded, "unexpected error: \(String(describing: outcome.error))")
        XCTAssertEqual(waitForStatus(child), "0")
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.marker))
    }
}

private final class AuditOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ShortcutOutcome?
    var value: ShortcutOutcome? {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ v: ShortcutOutcome) {
        lock.lock(); _value = v; lock.unlock()
    }
}
