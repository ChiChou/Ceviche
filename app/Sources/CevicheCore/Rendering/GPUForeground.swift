import Foundation

/// Holds GPU work while the app is off the screen. iOS refuses a command buffer committed from the background, which
/// failed whatever merge was running; every pass waits here before it commits, so a merge stops at its next pass when
/// the user leaves the app and carries on when they come back. The app says when it is in front (`set`); on the Mac
/// nothing ever closes the gate.
public enum GPUForeground {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var active = true

    /// Called by the app as it leaves the screen and as it returns.
    public static func set(active value: Bool) {
        condition.lock(); active = value; condition.broadcast(); condition.unlock()
    }
    /// Returns at once while the app is in front, otherwise when it is again. Never waits on the main thread, which
    /// is where the app's state changes arrive.
    public static func wait() {
        guard !Thread.isMainThread else { return }
        condition.lock()
        while !active { condition.wait() }
        condition.unlock()
    }
}
