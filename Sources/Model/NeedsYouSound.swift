import Foundation

// The "needs you" cue: one sound when a session starts waiting for the user's permission.
// Pure decisions here so the model check covers them; the controller only plays.
enum NeedsYouSound {
    // macOS's own alert sounds (/System/Library/Sounds), so there is nothing to bundle or
    // license and a click on the menu item previews the pick. Six of the fourteen: the short,
    // neutral ones. Basso, Sosumi and Funk read as errors, and the crab is not reporting one.
    static let choices = ["Tink", "Purr", "Ping", "Glass", "Hero", "Submarine"]
    static let defaultChoice = "Tink"   // half a second, light, unlike the completion chime
    static let volume: Float = 0.7      // the completion clip's level; the two should sit together

    /// Whether this tick should cue for `state` given what the session looked like last tick.
    ///
    /// Raw state, so the edge is the hook event itself; effective state too, so a stale
    /// permission file read at app launch (an hour-old prompt the user long answered) stays
    /// silent. `frontmost` is the app the user is looking at: when it is the very terminal or
    /// desktop app that hosts the session, the prompt is already on their screen and a sound
    /// is noise — the cue is for the session behind another window.
    static func shouldCue(prevState: String?, state: String, effective: String,
                          hostBundle: String, frontmost: String?) -> Bool {
        guard state == "permission", effective == "permission", prevState != "permission" else { return false }
        if !hostBundle.isEmpty, let front = frontmost, front == hostBundle { return false }
        return true
    }
}
