// Headless verification that RioKit links, spawns a PTY, and that the
// wakeup + render-state pull model works. Mirrors librio/ctest/main.c.
//
// Exits 0 on success, 1 on any failed expectation.

import Foundation
import RioKit
import Synchronization

private let wakeups = Atomic<Int>(0)
private let bells = Atomic<Int>(0)

/// Fires on librio's PTY IO thread. Per librio's contract a callback may only
/// flag or schedule work; calling any rio_* function from here is UB.
private let onWakeup: @convention(c) (UnsafeMutableRawPointer?, rio_surface_id_t) -> Void = { _, _ in
    wakeups.add(1, ordering: .relaxed)
}

private let onAction: @convention(c) (UnsafeMutableRawPointer?, rio_surface_id_t, rio_action_s) -> Void = { _, _, action in
    if action.tag == RIO_ACTION_RING_BELL {
        bells.add(1, ordering: .relaxed)
    }
}

/// Reads the grid as text, one string per row, mapping anything non-printable
/// to a space so `contains` is meaningful.
func gridRows(_ state: OpaquePointer) -> [String] {
    let lines = rio_render_state_lines(state)
    let cols = rio_render_state_columns(state)
    return (0..<lines).map { line in
        var row = ""
        row.reserveCapacity(Int(cols))
        for col in 0..<cols {
            let cp = rio_render_state_cell(state, line, col).codepoint
            row.append(cp >= 32 && cp <= 126 ? Character(UnicodeScalar(cp)!) : " ")
        }
        return row
    }
}

/// Polls the render state for `needle`, up to ~5s.
func waitFor(_ state: OpaquePointer, _ needle: String) -> String? {
    for _ in 0..<200 {
        rio_render_state_update(state)
        let hit = gridRows(state).first { $0.contains(needle) }
        rio_render_state_reset_dirty(state)
        if let hit { return hit }
        usleep(25_000)
    }
    return nil
}

func typeText(_ surface: OpaquePointer, _ text: String) {
    text.withCString { rio_surface_text(surface, $0, strlen($0)) }
}

func pasteText(_ surface: OpaquePointer, _ text: String) {
    text.withCString { rio_surface_paste(surface, $0, strlen($0)) }
}

/// Takes ownership of the returned C string, as librio requires.
func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    defer { rio_text_free(ptr) }
    return String(cString: ptr)
}

// MARK: - Engine

var runtime = rio_runtime_config_s()
runtime.wakeup_cb = onWakeup
runtime.action_cb = onAction

guard let engine = rio_engine_new(&runtime) else {
    FileHandle.standardError.write(Data("FAIL: rio_engine_new returned NULL\n".utf8))
    exit(1)
}

var failures: [String] = []

// MARK: - Default shell surface

var cfg = rio_surface_config_s()
cfg.shell = nil          // $SHELL, falling back to /bin/sh
cfg.cols = 80
cfg.rows = 24
cfg.pixel_width = 720
cfg.pixel_height = 432
cfg.scrollback = 1000

guard let surface = rio_surface_new(engine, &cfg) else {
    FileHandle.standardError.write(Data("FAIL: rio_surface_new returned NULL\n".utf8))
    rio_engine_free(engine)
    exit(1)
}

let pid = rio_surface_child_pid(surface)
usleep(400_000)   // let the shell come up and print a prompt

// Split the marker so the echoed command line can't match it: only real
// program output contains "librio-cgate".
typeText(surface, "printf '%s%s\\n' li brio-cgate\r")

let state = rio_render_state_new(surface)!
if let hit = waitFor(state, "librio-cgate") {
    print("  shell output   : \(hit.trimmingCharacters(in: .whitespaces))")
} else {
    failures.append("shell never produced the output marker")
}

// What TERM does librio hand the child? rio_surface_config_s has no env
// field, so this decides whether sessions need an /usr/bin/env wrapper to be
// usable over SSH (a remote host will not have rio's terminfo).
// The marker is split by printf so the echoed command line cannot match it.
typeText(surface, "printf 'TER%s=%s\\n' MIS \"$TERM\"\r")
let termLine = waitFor(state, "TERMIS=")
    .flatMap { $0.components(separatedBy: "TERMIS=").last }?
    .trimmingCharacters(in: .whitespaces) ?? "(not reported)"

// Bell: the terminal should report BEL through action_cb.
typeText(surface, "printf '\\a'\r")
for _ in 0..<80 where bells.load(ordering: .relaxed) == 0 { usleep(25_000) }

let fgName = takeString(rio_surface_foreground_process_name(surface)) ?? "(unknown)"
let workingDir = takeString(rio_surface_working_dir(surface)) ?? "(unset — needs OSC 7)"

// MARK: - Paste into `cat`, to dodge the shell's line editor

let catShell = strdup("/bin/cat")!
defer { free(catShell) }

var catCfg = cfg
catCfg.shell = UnsafePointer(catShell)
let catSurface = rio_surface_new(engine, &catCfg)
var catState: OpaquePointer?

if let catSurface {
    catState = rio_render_state_new(catSurface)
    pasteText(catSurface, "librio-pgate")
    if waitFor(catState!, "librio-pgate") == nil {
        failures.append("paste never echoed back from cat")
    }

    // Enable bracketed paste (mode 2004) and confirm librio brackets it.
    typeText(catSurface, "\u{1b}[?2004h\n")
    var bracketed = false
    for _ in 0..<200 {
        if rio_surface_mode_bits(catSurface) & (1 << 3) != 0 { bracketed = true; break }
        usleep(25_000)
    }
    if bracketed {
        pasteText(catSurface, "librio-bgate")
        if waitFor(catState!, "[200~librio-bgate") == nil {
            failures.append("bracketed paste was not wrapped in ESC[200~")
        }
    } else {
        failures.append("bracketed-paste mode bit never set")
    }
} else {
    failures.append("rio_surface_new for /bin/cat returned NULL")
}

// MARK: - Report

let cursor = rio_render_state_cursor(state)
let wokeUp = wakeups.load(ordering: .relaxed)
let rang = bells.load(ordering: .relaxed)

print("  child pid      : \(pid)")
print("  TERM           : \(termLine)")
print("  foreground     : \(fgName)")
print("  working dir    : \(workingDir)")
print("  cursor         : line \(cursor.line), col \(cursor.column)")
print("  grid           : \(rio_render_state_columns(state))x\(rio_render_state_lines(state))")
print("  wakeups        : \(wokeUp)")
print("  bells          : \(rang)")

if wokeUp == 0 { failures.append("wakeup_cb never fired") }
if rang == 0 { failures.append("BEL never arrived as RIO_ACTION_RING_BELL") }
if pid == 0 { failures.append("child pid was 0") }

// Teardown, in reverse order. rio_surface_free already hangs up the process
// group and reaps, so we must not signal the pid ourselves.
if let catState { rio_render_state_free(catState) }
if let catSurface { rio_surface_free(catSurface) }
rio_render_state_free(state)
rio_surface_free(surface)
rio_engine_free(engine)

if failures.isEmpty {
    print("\nPASS: RioKit links, PTY round-trips, wakeup/bell/render-state all live.")
    exit(0)
} else {
    print("\nFAIL:")
    for f in failures { print("  - \(f)") }
    exit(1)
}
