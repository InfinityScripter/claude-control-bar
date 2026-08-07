// Int(Double) is a TRAPPING conversion: NaN, an infinity or anything outside Int's range
// takes the whole process down with a fatal error. Every double this app converts comes from
// a JSON file on disk — limits.json, state.d/*.json — written sane by our own code, but a
// corrupted or hand-edited file must degrade to a wrong number on screen, not a crash loop
// that the self-relaunch walks straight back into on every menu open. All call sites go
// through here; a bare Int(someDouble) on file-fed data is the bug this file exists to end.

extension Double {
    /// `Int(self)` with the traps shaved off: NaN reads as 0, everything past the edges
    /// clamps to the edge. In-range values truncate toward zero exactly like `Int(_:)`.
    var clampedInt: Int {
        if isNaN { return 0 }
        // Double(Int.max) rounds UP to 2^63, one past Int.max — so `>=` is load-bearing:
        // equality means "too big for Int" here, and the nearest Double below is in range.
        if self >= Double(Int.max) { return Int.max }
        if self <= Double(Int.min) { return Int.min }
        return Int(self)
    }
}
