import Cocoa

// Checks on the MCP model, the transcript reader and the desktop-session lookup:
//   swiftc -O Sources/MCPModel.swift Sources/Transcript.swift Sources/DesktopSessions.swift \
//     Sources/RunningProcesses.swift tests/model/main.swift -o /tmp/t -framework Cocoa && /tmp/t
// There is no test target in this project (it builds with a bare swiftc, no Xcode project), so
// this is a plain executable that exits non-zero on the first failure.

var failures = 0
func check(_ passed: Bool, _ what: String) {
    print((passed ? "ok   " : "FAIL ") + what)
    if !passed { failures += 1 }
}

let fixture: [String: Any] = [
    "checked_at": 1_785_000_000.0,
    "servers": [
        ["name": "wiki", "state": "ok", "source": "user", "status": "✔ Connected",
         "tools": 3, "toolNames": ["Read", "Write", "Delete"],
         "toolDocs": ["Read": "read a page"],
         "toolParams": ["Read": [["name": "id", "type": "integer", "required": true,
                                  "description": "page id"]]],
         "deniedTools": ["Delete"]],
        ["name": "yt", "state": "failed", "source": "user", "status": "✘ Failed to connect",
         "tools": 2, "toolNames": ["A", "B"], "deniedTools": []],
        ["name": "off-one", "state": "off", "source": "user", "status": "disabled",
         "tools": 5, "toolNames": [], "deniedTools": []],
    ],
    "auth": ["needs-oauth"],
]

let dir = NSTemporaryDirectory() + "ccb-model-test/"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let path = dir + "mcp.json"
try! JSONSerialization.data(withJSONObject: fixture).write(to: URL(fileURLWithPath: path))

let model = MCPModel(path: path)
check(model.reloadIfChanged(), "reads the file")

check(model.servers.count == 3, "three servers parsed")
check(model.visible.count == 2, "a switched-off server is not counted as visible")
check(model.live == 1, "one of the visible two answered")
// wiki has 3 tools with Delete denied -> 2; yt has 2, none denied.
check(model.toolsOn == 4, "tools reaching Claude: \(model.toolsOn), expected 4")
check(model.toolsTotal == 5, "tools offered: \(model.toolsTotal), expected 5")

let wiki = model.servers.first { $0.name == "wiki" }!
check(wiki.tools.first { $0.name == "Delete" }?.enabled == false, "a denied tool reads as off")
check(wiki.tools.first { $0.name == "Read" }?.params.first?.required == true,
      "tool parameters survive the parse")

// The user's report: flipping a switch left every count stale until the menu was reopened.
model.setToolLocally(server: "wiki", tool: "Read", enabled: false)
check(model.toolsOn == 3, "switching a tool off moves the total at once: \(model.toolsOn)")
model.setToolLocally(server: "wiki", tool: "Delete", enabled: true)
check(model.toolsOn == 4, "and back on again: \(model.toolsOn)")

model.setServerLocally("yt", enabled: false)
check(model.visible.count == 1, "switching a server off drops it out of visible")
model.setServerLocally("yt", enabled: true)
// Not "ok": the server list is assembled when a session starts, so switching it back on cannot
// reconnect it. Claiming otherwise would show a green dot for something that is not there.
check(model.servers.first { $0.name == "yt" }?.state == "pending",
      "switching a server back on says pending, not connected")

// A change is only reported against a previous read — otherwise every server "appears" at launch
// and the first look fires a notification storm.
check(model.freshChange() == nil, "the first read reports no change")
var next = fixture
var servers = next["servers"] as! [[String: Any]]
servers[1]["state"] = "ok"
next["servers"] = servers
next["checked_at"] = 1_785_000_100.0
try! JSONSerialization.data(withJSONObject: next).write(to: URL(fileURLWithPath: path))
check(model.reloadIfChanged(force: true), "re-reads on force")
check(model.freshChange()?.up == ["yt"], "a server coming back is reported as up")
check(model.freshChange()?.deservesNotification == true, "a server coming back is worth a notification")

// Switching a server off has to change what its row SAYS, not only whether it counts. Leaving
// a green dot beside an off switch read as the click having done nothing.
model.setServerLocally("wiki", enabled: false)
let offWiki = model.servers.first { $0.name == "wiki" }!
check(offWiki.disabled, "a switched-off server reports itself disabled")
check(mcpGlyph(offWiki.state) == "\u{25CB}", "and its glyph is the hollow one, not the green dot")
check(mcpTint(offWiki.state) == .tertiaryLabelColor, "and its colour is dimmed")
model.setServerLocally("wiki", enabled: true)
check(mcpGlyph(model.servers.first { $0.name == "wiki" }!.state) == "\u{23F8}",
      "back on, it shows the paused glyph until a new session picks it up")

// The spinner claims work is happening, so it needs both halves to be true. "pending" outlives
// the check that resolves it — a server can wait on an authorisation no check will grant — and an
// arc turning against nothing is a promise the app cannot keep.
check(model.isChecking("wiki", backendBusy: true),
      "a pending server spins while the backend is working")
check(!model.isChecking("wiki", backendBusy: false),
      "and stops the moment nothing is checking")
check(!model.isChecking("yt", backendBusy: true),
      "a server that already answered does not spin")
check(!model.isChecking("nosuch", backendBusy: true), "an unknown server does not spin")

// A tool's deny rule is built from the prefix the transcript proves Claude Code uses, not from
// the display name. Built from the name, the rule matched no tool at all: the switch went off,
// the tool kept loading, and the "N/M tools on" count promised a saving that never happened.
let prefixed = try! JSONSerialization.data(withJSONObject: ["servers": [
    ["name": "claude.ai Figma", "toolPrefix": "b6d68fb1", "state": "ok", "source": "claude.ai",
     "toolNames": ["get_screenshot"]],
    ["name": "wiki", "state": "ok", "source": "user", "toolNames": ["GetPageById"]],
]])
try! prefixed.write(to: URL(fileURLWithPath: path))
check(model.reloadIfChanged(force: true), "re-reads the prefixed picture")
check(model.servers.first { $0.name == "claude.ai Figma" }?.toolPrefix == "b6d68fb1",
      "a connector carries the prefix its tools actually use")
check(model.servers.first { $0.name == "wiki" }?.toolPrefix == "wiki",
      "a server without one falls back to its own name")

// The interrupt marker, told apart from a line that merely quotes it. A tool result is itself a
// "type":"user" record, so reading any file containing the phrase used to stop the animation and
// the timer in the middle of a turn that was still running.
check(Transcript.wasInterrupted(
    #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#),
      "the marker as a plain string is an interrupt")
check(Transcript.wasInterrupted(
    #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#),
      "the marker inside a text block is an interrupt too")
check(!Transcript.wasInterrupted(
    #"{"type":"user","message":{"content":[{"type":"tool_result","content":"…interrupted by user…"}]}}"#),
      "a tool result quoting the phrase is NOT an interrupt")
check(!Transcript.wasInterrupted(
    #"{"type":"assistant","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#),
      "and neither is an assistant message that types it out")
check(!Transcript.wasInterrupted("not json at all, interrupted by user"),
      "a line that does not parse is not an interrupt")

// The timestamp of a turn record. A permission prompt keeps the transcript silent while it
// waits, so a user/assistant record younger than the prompt is proof the prompt is gone —
// deny and Esc write one without firing any hook.
check(Transcript.turnTimestamp(
    #"{"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"content":"hi"}}"#)
        == 1_767_225_600,
      "a user record's timestamp parses to unix time")
check(Transcript.turnTimestamp(
    #"{"type":"assistant","timestamp":"2026-01-01T00:00:00.500Z","message":{"content":[]}}"#)
        == 1_767_225_600.5,
      "fractional seconds survive — Claude Code writes milliseconds")
check(Transcript.turnTimestamp(
    #"{"type":"file-history-snapshot","timestamp":"2026-01-01T00:00:00Z"}"#) == nil,
      "a bookkeeping record is not a turn, whatever its timestamp")
check(Transcript.turnTimestamp(#"{"type":"user","message":{"content":"hi"}}"#) == nil,
      "a turn record without a timestamp yields nothing rather than a guess")
check(Transcript.turnTimestamp("not json") == nil,
      "a line that does not parse yields nothing")
// Format drift is the net's silent killer: a numeric timestamp (or any unparseable shape) must
// yield nil — and isTurnRecord is what lets the app log that drift instead of swallowing it,
// while staying quiet for the half-written lines a streaming transcript ends with.
check(Transcript.turnTimestamp(
    #"{"type":"user","timestamp":1767225600,"message":{"content":"hi"}}"#) == nil,
      "a timestamp of a drifted type yields nothing rather than a crash or a guess")
check(Transcript.isTurnRecord(#"{"type":"user","timestamp":1767225600,"message":{}}"#),
      "the drifted record still counts as a turn — that is what makes it drift worth logging")
check(!Transcript.isTurnRecord(#"{"type":"user","timestamp":"2026-"#),
      "a half-written streaming line is not a turn record, so it is not logged as drift")

// Resolving a row's CLI session id to the id Claude for Desktop answers to. Without it every
// desktop row merely focused the app — which is already frontmost — so all of them did the same
// nothing and clicking a session read as broken.
let sessionsRoot = NSTemporaryDirectory() + "ccb-desktop-sessions/"
let workspace = sessionsRoot + "account/workspace/"
try? FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
func writeSession(_ name: String, cli: String, modified: Date) {
    let path = workspace + name + ".json"
    // Exactly how the desktop app writes it: JSON.stringify, no spaces.
    try? #"{"sessionId":"\#(name)","cliSessionId":"\#(cli)","cwd":"/tmp"}"#
        .write(toFile: path, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
}
writeSession("local_older", cli: "cli-1", modified: Date(timeIntervalSince1970: 1_000))
writeSession("local_newer", cli: "cli-1", modified: Date(timeIntervalSince1970: 2_000))
writeSession("local_other", cli: "cli-2", modified: Date(timeIntervalSince1970: 3_000))

check(DesktopSessions.sessionID(forCLI: "cli-2", root: sessionsRoot) == "local_other",
      "a session id resolves through two directory levels")
// Importing a CLI session leaves a second record pointing at the same conversation; the one the
// app is actually showing is the most recent.
check(DesktopSessions.sessionID(forCLI: "cli-1", root: sessionsRoot) == "local_newer",
      "when two records claim one conversation, the newest wins")
check(DesktopSessions.sessionID(forCLI: "cli-3", root: sessionsRoot) == nil,
      "a conversation this machine never opened resolves to nothing")
check(DesktopSessions.sessionID(forCLI: "", root: sessionsRoot) == nil,
      "an empty id matches nothing rather than the first file on disk")
check(DesktopSessions.sessionID(forCLI: "cli-1", root: sessionsRoot + "missing/") == nil,
      "a missing sessions folder is answered, not crashed on")
// /code/ wants a bridge id a local conversation does not have; /resume is an import verb that
// spawns a duplicate record on every click. This route is the only one that focuses.
check(DesktopSessions.focusURL(sessionID: "local_x")?.absoluteString
        == "claude://claude.ai/epitaxy/local_x",
      "the focus link is the epitaxy route")

// The last word on whether the app is still needed. Counting hook-written session files answers
// that only when the hooks fired at all; on the evidence of an empty state.d the app quit about
// ten seconds after launch with Claude Code running in a terminal the whole time.
check(RunningProcesses.exists(named: ProcessInfo.processInfo.processName),
      "a process that is plainly running is found")
check(!RunningProcesses.exists(named: "ccb-no-such-process"),
      "and one that is not, is not")

// The python→swift seam. Everything above parses a fixture written BY HAND — the same schema
// pinned twice independently, so a coordinated key rename passed both suites while the menu
// silently emptied. This file is written by the real refresh() during the python suite
// (SeamContract copies it out); parsing it here is the only check that crosses the language
// border. Run the python suite first — CI does.
let seamPath = FileManager.default.currentDirectoryPath + "/build/seam/mcp.json"
if !FileManager.default.fileExists(atPath: seamPath) {
    check(false, "seam fixture missing at \(seamPath) — run the python suite first "
        + "(/usr/bin/python3 -m unittest discover -s tests), it writes build/seam/mcp.json")
} else {
    let seam = MCPModel(path: seamPath)
    check(seam.reloadIfChanged(), "the mcp.json the real refresh() wrote parses")
    let seamWiki = seam.servers.first { $0.name == "wiki" }
    check(seamWiki != nil, "a user server survives the python→swift trip")
    check(seamWiki?.tools.count == 3, "its tool list arrives whole")
    check(seamWiki?.tools.first { $0.name == "Delete" }?.enabled == false,
          "a deny rule python computed reads as a switched-off tool here")
    check(seamWiki?.tools.first { $0.name == "Read" }?.params.first?.required == true,
          "tool parameters survive the real writer, not just the hand fixture")
    check(seam.servers.first { $0.name == "claude.ai Figma" }?.toolPrefix == "b6d68fb1",
          "a connector's prefix is its uuid across the border — the deny rule depends on it")
    check(seam.servers.first { $0.name == "off-one" }?.disabled == true,
          "a server disabled in settings arrives disabled")
    check(seam.waitingAuth == ["needs-oauth"], "the waiting-for-auth list crosses over")
}

try? FileManager.default.removeItem(atPath: dir)
try? FileManager.default.removeItem(atPath: sessionsRoot)
print(failures == 0 ? "\nall model checks passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
