# Suisto

A macOS "tab-of-tabs" terminal grouper. *Suisto* is Finnish for a river delta —
one current arriving, many channels leaving, which is the shape of the window.
(The repository folder is still `projects-term`; only the app was renamed.) Projects run down the left as the major
grouping; that project's own command and agent tabs run across the top as the
minor grouping. Sessions keep running when you switch away — that is the point.

```
          ┌ shell │ claude ✳ │ vim │ ⇡ remote │ + ┐
 ┌────────┼───────────────────────────────────────┐
 │ mike   │                                       │
 │ 2/4 ◐1 │   the selected tab's live terminal    │
 │ ✳1 🔔2 │                                       │
 └────────┴───────────────────────────────────────┘
```

A bell rings three ways, depending on where you are. Looking at the tab, it
beeps. Looking at another tab, it raises that tab's dot and the project's
**🔔n**. Looking at another *app*, it bounces the Dock icon, as Terminal.app
does — because neither the beep nor the badge reaches you when the window is
buried. A burst of bells is coalesced into one bounce, and the request is
cancelled the moment you come back, so the icon is never still asking about
something you have already answered.

Each project row carries live badges: **busy/total** sessions, **◐n** agents
thinking and **✳n** agents waiting on you, **CPU%** of the whole child process
tree, **◆n** tabs that produced output while you were away, and **🔔n** bells.
Each project gets its own colour, which also tints its tab bar.

Tabs are per-project and freeform. Each one is configured to run locally or over
SSH, and that choice is saved.

Quitting and reopening restores the layout, the project and tab you were on, and
each tab's scrollback. A tab can also be backed by `screen` or `tmux`, in which
case the **processes** survive too — see [Session restore](#session-restore).

Projects and tabs reorder by dragging. Font and colour scheme are under
Settings (⌘,).

## Keyboard

| Shortcut | Does |
|---|---|
| `⌘1` … `⌘9` | Go to the nth **tab** of the current project |
| `⌘⇧1` … `⌘⇧9` | Go to the nth **project** |
| `⌃⇥` / `⌃⇧⇥` | Next / previous tab |
| `⌘⇧]` / `⌘⇧[` | Next / previous project |
| `⌘C` / `⌘V` | Copy selection / paste |
| `⌘K` | Clear the screen and scrollback, keeping the prompt |
| `⌘,` | Settings — font, size, theme, terminal translucency |

The narrower scope gets the easier chord, since switching tabs within a project
is the more frequent move. An index with nothing behind it does nothing — `⌘5`
with four tabs open neither clamps to the last tab nor wraps to the first — and
the menu greys those entries out so it shows how many there actually are.

`⌘K` behaves as it does in Terminal.app: the line the cursor is on moves to
the top and everything else — screen and scrollback — goes. It is written
straight to the display, never to the PTY, so nothing is typed on the running
program's behalf. It greys out on the alternate screen, where there is no
scrollback to clear and wiping the grid would leave the display disagreeing
with what a full-screen program believes it drew.

## Mouse

| Action | Does |
|---|---|
| Drag | Select text |
| Double-click / triple-click | Select a word / a line |
| ⌥-drag | Rectangular (block) selection |
| Right-click or ⌃-click | Copy, Paste, Select All, Clear Selection |
| ⇧-click | Force a local selection when the program is reading the mouse |

A program that asked for mouse reporting — vim, tmux, a pager — gets the
button first, the right button as well as the left, so a right-click inside
one reaches the program; ⇧-right-click takes the menu instead. A right-click
never clears the selection, since that is usually the thing you were about to
copy.

Dragging past the top or bottom edge scrolls the view and keeps scrolling
while you hold still out there, which is what makes it possible to select more
than one screen. AppKit only delivers drag events when the pointer actually
moves, so a timer drives the overshoot once motion stops.

## Agents

A tab running `claude` gets its own mark, and the project row counts them:
**◐n** thinking, **✳n** stopped and waiting on you.

Claude Code already reports this — it writes its state into the terminal title
(OSC 0/2) as a half-filled circle that alternates `◐` / `◑` while it works and
an asterisk `✳` once it stops, which is what Terminal.app shows in its
titlebar. We read the same title, so there is nothing to install and nothing to
poll: the title arrives as an event like any other, and the badge is already
tracked state.

It is a different question from **busy/total**, which asks the process table
what the foreground program is. An agent tab's foreground program is `claude`
— or whatever it has shelled out to — whether it is thinking or sitting at an
empty prompt, so the process table calls such a tab busy for its entire life
and never says the one thing worth knowing: whose turn it is. That is why
waiting is the colour that stands out and working is just the project's own
tint.

Two details. The badge shows one fixed glyph per state rather than the live
character, because echoing the spinner's phase into a view that redraws on
every title change would strobe it a few times a second — progress rendered as
a glitch. And the mark on a tab pill outranks the unread dot: an agent writes
constantly, so one left running in a background tab is *always* unread, and a
dot that is always lit says nothing.

Unlike busy and CPU, this one survives SSH. The title is set by the program
itself and comes down the same connection as its output, so an agent on another
machine is counted exactly like a local one.

## Appearance and the icon

The whole window is frosted glass. The sidebar, the tab bar and the strip
behind the titlebar are `.behindWindow` vibrancy, so they sample what is
actually behind the window, and the terminal sits on a frosted panel of its
own. That only works because the window is non-opaque with a clear background
— an opaque window gives the material nothing to sample and it flattens to a
plain fill, which is what the first attempt here looked like.

The terminal is frosted but much less so, because text has to stay readable
over a backdrop that moves. Only the *default* background is translucent:
cells with a colour of their own — coloured output, selections, inverse video
— stay fully opaque, so a highlighted line never goes see-through.

How much is a **Translucency slider in Settings (⌘,)**. It is live: the
terminal follows the thumb rather than waiting for the mouse-up, Save writes
it to `workspace.json`, and Cancel puts back what the preview changed under
you. It is clamped to 0–70%, because a slider that reaches fully transparent
leaves the terminal in a state you cannot then see well enough to undo.

Dragging it deliberately does *not* go through the same path as a font
change: a font change re-measures the grid and resizes every PTY, which means
a SIGWINCH to every running program, and that is not something to send on each
frame of a drag. The slider only repaints.

Two details that bite. The rendered bitmap persists between frames and is
repainted a row at a time, so a translucent fill has to `clear` the row first
or it compounds towards opaque over a few frames. And the backdrops are
`.active` rather than `.followsWindowActiveState`: a terminal is usually the
window you are *not* looking at while something runs, and chrome that
flattens to grey on losing focus stops looking like glass exactly when it is
most on screen.

On top of that, the controls are Liquid Glass. The sidebar is a translucent panel, the tab bar a
vibrant header, and both the selected project and every tab are
`NSGlassEffectView` pills — the selected one tinted with the project's colour,
which is why a project's identity carries through the glass instead of being
painted over it. The tab pills live in an `NSGlassEffectContainerView`, so
neighbouring pills merge into one piece of glass and render in a single pass.

Two things are deliberate. A row's label is the glass view's `contentView`
rather than a sibling drawn on top: the API only guarantees z-order for the
content view, and a sibling gets re-elevated by the container and ends up
blurred underneath its own pill. And there is no glass behind the terminal
grid, where a shifting translucent backdrop would fight the text for contrast.

The icon is vector art in `Resources/Icon/Suisto.vectorcraft`, exported to SVG
and PNG and assembled into `Suisto.icns` — a glass tile holding a lens, and in
the lens a river running out of a notch in the hills and breaking into a delta.

## Requirements

Apple Silicon macOS (the released RioKit xcframework is `macos-arm64` only),
Xcode 26.5+ toolchain. No Rust toolchain needed.

## Build and run

```sh
make smoke     # gate: proves RioKit links and the PTY round-trips
make run       # build, assemble Suisto.app, launch it
swift test     # 114 tests
```

`make fetch-rio` downloads and SHA-256-verifies `RioKit.xcframework` into
`vendor/` (pinned to Rio v0.5.28 in the Makefile). Every other target depends on
it, so it runs on its own the first time.

## Architecture

The terminal core is **Rio's `librio`**, consumed as the prebuilt
`RioKit.xcframework`: PTY, VT parser, grid, and a host-pulled render-state API
with per-row dirty tracking. It has no renderer and no windowing — those are
ours, in Swift.

```
Sources/Suisto/        main.swift only
Sources/SuistoKit/
  Model/      Workspace, Project, TabSpec (argv construction), Store,
              AgentStatus (agent state read off the terminal title),
              HistoryStore (scrollback restore),
              WorkspaceController (sessions, selection, badge aggregation)
  Terminal/   RioEngine (+ event mailbox), TerminalSession, TerminalView,
              CoreTextRenderer, GlyphCache, KeyTranslator, RioFlags, Palette
  Metrics/    ProcessTable (sysctl + rusage), ProcessSampler
  UI/         ProjectSidebar, TabBar, Editors, MenuBuilder
Tools/smoke/  headless librio check
```

Everything but `main.swift` lives in `SuistoKit` so the tests can reach it
with `@testable` and no `public` annotations.

### librio's threading contract

Non-negotiable, and the reason for the event mailbox in `RioEngine`:

- `wakeup_cb` and `action_cb` may fire on librio's PTY IO thread, and may **only
  flag or schedule work**. Calling any `rio_*` function from inside a callback is
  undefined behaviour.
- All `rio_render_state_*` calls must come from one thread; we use the main actor.
- Input entry points are callable from any thread.

So the callbacks do nothing but append to a lock-guarded mailbox, and the first
event after each drain schedules a single coalesced main-queue hop. A firehose of
output costs one drain, not one per byte.

### Rendering

Pulled, not pushed. A wakeup only marks the view dirty; `rio_render_state_update`
happens in `updateLayer`, which AppKit calls at most once per display refresh.
Only rows librio marks dirty are repainted, into a persistent bitmap the view
presents as its layer contents. librio never clears the dirty flags itself — the
host must, after consuming the snapshot.

Glyphs resolve in three tiers: the styled system monospace font, then librio's
embedded "Symbols Nerd Font Mono" (`rio_symbols_nerd_font`) for the powerline
separators and icon ranges the system font has no coverage for, then a cached
`CTLine` for anything else — CJK, emoji, combining clusters. Glyph ids are
per-font, so the resolved font travels with the glyph all the way to the draw
call.

`rio_color_s` carries resolved RGB for every cell, so the renderer never needs to
own a palette; `rio_set_colors` tells librio which RGB to resolve to (it is
process-wide, not per surface).

## Session restore

There are two levels, chosen per tab.

**Replay (default).** Reopening brings back the window frame, projects, tabs,
the project and tab you were last on, and each tab's scrollback. The processes
are gone — they died with the PTY — so a restored tab shows what it previously
said, a dim `── restored <time> ──` marker, then a fresh shell underneath.

Scrollback lives in `~/Library/Application Support/Suisto/history/<tab
id>.txt`, one file per tab, capped at 256 KB (the tail is kept). It is written
on quit and every two minutes, so a crash costs at most a couple of minutes.
Deleting a tab deletes its history.

**Reattach (`screen` / `tmux`).** Set a tab's *Persistence* and the session is
run inside a multiplexer on whichever machine the tab targets. Now the real
session outlives the app: reopening reattaches to the still-running programs
rather than replaying a transcript of them. This is the difference between
seeing what a build said and finding it still running.

- screen: `screen -T screen-256color -D -RR <session>` — detach it from
  anywhere else it is attached, reattach here, create it if absent.
- tmux: `tmux new-session -A -s <session>` — attach if it exists, else create.

The session name is `pt-` plus the first eight hex digits of the tab id, so it
is stable across renames and cannot collide with a session you started by hand.
Scrollback replay is skipped for these tabs, because the live session repaints
itself on reattach and a transcript on top would just duplicate it.

Spawning stays lazy: a tab's program starts the first time that tab is shown.
Note what that means on reopen — the tab you were last on *is* shown
immediately, so if that was an SSH tab it reconnects right away. Every other
tab stays dormant until you click it.

Two replay details that are easy to get wrong, both covered by `HistoryTests`:

- `rio_surface_dump` returns **plain UTF-8**, so replayed history has no
  colours. Live output is unaffected, and reattached sessions keep their colour.
- A dump carries bare `\n`. Replaying that as-is stair-steps every line further
  right, because `\n` moves down a row without returning to column 0, so the
  replay rewrites them as `\r\n`.

## Appearance

Settings (⌘,) picks the font — any fixed-pitch face installed, or the system
monospace default — its size, and one of three colour schemes (Dark, Muted,
Light). Changes apply immediately to every session.

A font change moves the cell size, so the grid is re-measured and every PTY is
told its new dimensions. The palette also goes to librio via `rio_set_colors`,
because librio resolves named and indexed cell colours itself and would
otherwise keep handing back the old RGB.

## Five things worth knowing

These were found by measurement during the build, and each one is guarded by a
test or a comment in the code.

**librio exports `TERM=rio`.** `rio_surface_config_s` has no environment field,
so every session is spawned through `/usr/bin/env TERM=…`. This matters: the
remote host was confirmed to have no `rio` terminfo entry, so without the wrapper
vim and tmux would break over SSH. It also keeps us honest — this renderer
implements a subset of what `TERM=rio` advertises.

**`ri_user_time` is mach absolute time, not nanoseconds.** Reading it as
nanoseconds under-reports CPU by ~41.7× on Apple Silicon (125/3 ns per tick): a
fully busy core showed as 2%. `ProcessTable.machTicksToSeconds` converts, and
`ProcessTreeTests` fails if the units regress.

**Swift's synthesised `Decodable` ignores property defaults.** A key that is
simply absent is a hard error, not a fallback — so the first time a field was
added to `TabSpec`, every existing `workspace.json` failed to decode and users
would have been silently started over. Every persisted model now decodes with
`decodeIfPresent`, and `WorkspaceTests` loads a real pre-upgrade file.

**`CTLineDraw` leaves a translation in the context's text matrix**, and
`CTFontDrawGlyphs` adds it to every position it is given. One fallback glyph — an
emoji, or a powerline icon in a remote prompt — pushed every plain glyph drawn
after it off the canvas, blanking the terminal. `CoreTextRenderer` resets the
text matrix before each glyph batch; `RendererTests` asserts ASCII still renders
after a fallback glyph, measured against a control render.

**AppKit reports Shift-Tab as U+0019, not as Tab with a shift flag.**
`NSBackTabCharacter` arrives as both `characters` and
`charactersIgnoringModifiers`, so a translator that only knows U+0009 treats
it as an ordinary character and librio encodes the raw 0x19 byte. That is
Ctrl-Y, which every readline-style editor reads as *yank* — so Shift-Tab
pasted the kill ring instead of sending CSI Z, and `claude` never saw the key
it cycles its modes with. `KeyboardTests` sends the key into a real PTY and
reads the tty's own echo back off the grid, because what the program receives
is librio's decision, not ours.


## Known limitations

- **CPU is blank for SSH tabs.** The local process tree is just the `ssh` client,
  so it says nothing about the work on the far side. Remote tabs show `—` rather
  than a misleading `0%`. Real remote CPU would need an agent on the other end.
- **Busy is local-only**, for the same reason: an SSH tab's foreground process is
  always `ssh`, so a remote session is never reported busy rather than always.
  The agent badges are the exception — they come from the title, which crosses
  the connection.
- **Agent state is only as honest as the title.** Anything that writes a leading
  `◐` or `✳` into its title is counted as an agent, and an agent that is
  launched without setting titles at all is not counted. Nothing here inspects
  the process.
- **arm64 only**, following the released xcframework. A universal build would
  mean building `librio` from source.
- Replayed scrollback is plain text — librio's dump carries no colours. Use a
  `screen`/`tmux` tab when that matters.
- `screen`/`tmux` must already be installed on the machine a persistent tab
  targets; nothing is installed for you.

## Debugging

`SUISTO_DEBUG_RENDER=1 ./.build/debug/Suisto` logs grid size, dirty-row count,
non-blank cell count and a whole-buffer digest on every frame — which is how the
text-matrix bug was isolated.
