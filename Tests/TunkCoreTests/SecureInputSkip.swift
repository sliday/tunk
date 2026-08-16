import XCTest
import TunkEmit

/// A test that cannot run should SKIP, not fail.
///
/// While another process holds secure event input — every password field, some
/// terminals, the lock screen — the window server discards synthesized
/// keystrokes, so every test that posts one and counts what arrives sees zero.
/// That produced 43 failures across four suites, all of them meaning "the
/// machine is busy" and none meaning "the code is wrong".
///
/// A suite that is always 43 red on a locked screen teaches whoever runs it to
/// ignore red, which is worse than having no tests: the next real regression in
/// those files arrives in a colour the reader has been trained to skip past.
enum SecureInput {
    static var isHeld: Bool { SystemSecureInput().isSecureInputActive }

    /// Call from `setUpWithError()`. Skipping is deliberately per-suite rather
    /// than per-assertion, so a suite either ran or it did not, and the summary
    /// says which.
    static func skipIfHeld() throws {
        if isHeld {
            throw XCTSkip("another process holds secure event input, so macOS "
                        + "discards synthesized keystrokes and nothing this suite "
                        + "posts can arrive. Unlock the screen and quit whatever "
                        + "has a password field focused, then re-run.")
        }
    }
}
