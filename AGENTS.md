# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A phone companion for [Herdr](https://herdr.dev) (a terminal multiplexer for AI coding agents). It has two parts that talk over HTTP/WebSocket on port 7788, and the bridge is meant to bind to the host's Tailscale IP. There's no auth layer: Tailscale is the security boundary. The bridge refuses any request carrying an `Origin` header (`reject_browsers`), since browsers let any web page open a WebSocket to any address and the app's Dart client sends none.

- `bridge/`: Rust daemon (axum + tokio). It translates between Herdr's Unix-socket JSON-RPC (`~/.config/herdr/herdr.sock`) and HTTP/WS.
- `app/`: Flutter app (Android only; no `ios/` dir, and `linux/` is only the stock desktop runner). It's a terminal-first UI on `xterm` 4.x.

## Commands

Bridge (run from `bridge/`):
```bash
cargo build --release
cargo run -- --bind 127.0.0.1 --port 7788 # the default bind; flags also read from env: HERDR_SOCKET, HERDR_BRIDGE_BIND, HERDR_BRIDGE_PORT
RUST_LOG=herdr_bridge=debug cargo run
../deploy/start-bridge.sh        # binds the Tailscale IP (fails until Tailscale is up); runs ~/.local/bin, target/release, target/debug or PATH
```
The bridge has no tests. `deploy/install.sh` installs the binary and `start-bridge.sh` to `~/.local/bin` and sets up `herdr-bridge.service` (systemd user unit, which sets its own `PATH` so `herdr`, `git` and `tailscale` resolve) or `dev.herdr.bridge.plist` (launchd).

Mobile (run from `app/`):
```bash
flutter pub get
flutter run
flutter test                                  # test/widget_test.dart: model parsing, client state, widget tests
flutter test test/widget_test.dart --plain-name "SessionSnapshot parses correctly from JSON"
flutter analyze                               # flutter_lints via analysis_options.yaml
flutter build apk --release
```
CI (`.github/workflows/build-apk.yml`) runs on every push to main, on `v*` tags and by hand: `flutter build apk --release` on Flutter 3.24.x / JDK 17, plus `cargo build --release` for the bridge on native ubuntu-22.04 x86_64 and arm runners. On a tag it attaches the APK and `herdr-bridge-linux-{x86_64,aarch64}` to the GitHub release. No tests run. Keep Flutter/Gradle/AGP versions compatible with 3.24.x (a newer local Flutter flags `ReorderableListView.onReorder` as deprecated; its replacement isn't in 3.24). Recent commits were spent fixing CI build breakage.

## Architecture

**Bridge data flow** (`bridge/src/`):
- `herdr.rs` `HerdrClient`: each `call()` opens a new Unix socket connection, writes one newline-delimited JSON request `{id, method, params}`, and reads one response line. `snapshot()` wraps `session.snapshot` and adds each workspace's `git_branch` (`git branch --show-current` in its directory; left out when empty). Server routes pass most calls straight through via `server.rs` `rpc`. A separate long-lived connection runs `events.subscribe` and fans the events out through a `tokio::broadcast` channel. It reconnects forever.
- `server.rs` routes:
  - `GET /health`, `GET /api/snapshot`
  - `POST /api/tab`, `DELETE /api/tab/{id}`, `POST /api/tab/{id}/rename`, `POST /api/workspace` (plus workspace delete/rename, `POST /api/workspace/move` → `workspace.move_block`, and worktree routes)
  - `WS /ws/session`: sends the snapshot as `{"type":"snapshot","data":…}` whenever it changed: right after any Herdr event (a burst makes one snapshot), and from a poll every 1.5 s (the first one on connect). The poll is needed because herdr's global `events.subscribe` carries no agent status changes (`pane.agent_status_changed` requires a `pane_id`).
  - `WS /ws/term/{id}?cols&rows`: a real terminal stream. It first calls `pane.focus`, the only thing that marks a pane seen in herdr (`done` turns `idle`; the takeover alone doesn't), so the desktop follows the phone. Then it spawns `herdr terminal session control <pane> --takeover` and relays its base64 frames as binary WS frames. Binary frames in are terminal input. A text frame with a `type` (e.g. `{"type":"terminal.scroll","direction":"up"|"down","lines":N}`) goes to herdr as-is; one without is a resize `{"cols","rows"}`. The frames out are herdr's *rendered viewport* (clear screen plus absolute cursor moves, no newlines), so the client never accumulates scrollback: history lives in herdr and is reached with `terminal.scroll`. On close it sends `terminal.release` so the desktop gets its size back.
- Herdr payload shapes are handled loosely: code accepts both `snapshot.snapshot` and a bare snapshot, and alternate field names (`terminal_title_stripped`/`terminal_title`, `status`/`agent_status`). Keep that tolerance unless you've confirmed the real schema.

**Mobile** (`app/lib/`):
- State lives in `HerdrClientService` (a `ChangeNotifier` created in `main.dart` and passed down through constructors).
- `HerdrClientService` keeps one `/ws/session` socket per saved machine (`_Conn`: socket, retry timer, last snapshot, selected pane), so several machines are connected at once. It applies each pushed snapshot (older bridges also send raw `event`s, which it ignores); a dropped socket retries every 3 s. `_sync` (run from `notifyListeners`, after `start()`) opens a socket for every machine not in `_off`, the set the user disconnected (pref `herdr_machines_off`); `connect(m)`/`disconnect(m)` toggle one machine. The *active* machine (prefs `herdr_host`/`herdr_port`) is only the one on screen: `snapshot`, `selectedPaneId` and the bridge requests are its; `switchMachine` shows another without touching the rest. Saved machines are in `herdr_machines` (`host:port`), names in `herdr_machine_names` (`host:port=name`). `MachineList` (`machine_drawer.dart`), at the foot of the workspace drawer, lists them with a switch each. Bridge requests all go through `_request` (then refetch the snapshot over HTTP); failures go to the `onError` callback, which `TerminalScreen` shows as a SnackBar.
- `PtyChannel` holds one `/ws/term/{id}` socket for the selected pane and writes incoming bytes straight into the single xterm `Terminal`. It switches xterm to the alt screen (no local scrollback) and clears it in front of every (re)connect's first frame, because herdr repaints the pane on attach; `onAttach` then resets the screen's scroll count. One-finger drags on the terminal send `terminal.scroll` (`TerminalScreen._scroll`); xterm's own `simulateScroll` is off. The screen counts lines scrolled back (`_scrolledUp`) to show a centred ↓ button that returns to live, and any input scrolls back to live first. `TerminalScreen` rebuilds the channel whenever `selectedPaneId` or the machine changes, and drops it while the app is in the background so the takeover ends.
- **Background alerts** (Android side in `android/.../HerdrApp.kt`): `HerdrApp` (the `Application`) owns the Flutter engine, so Dart, and with it `HerdrClientService`, outlives `MainActivity`. While alerts are on (pref `background_alerts`), Dart drives `StatusService`, a foreground service whose ongoing notification shows the connection state, over the `herdr/android` MethodChannel (`status`, `alert`, `cancel`, `askPermissions`; native calls back `open` when an alert is tapped). The `HerdrClientService.notifyListeners` override pushes the status on every change. `_alertChanges` diffs consecutive snapshots: a pane entering `blocked` raises "Needs you", and an agent's `completion_seq` rising past the highest seen for that pane (`_Conn.completions`, since an HTTP-fetched snapshot can land after a newer pushed one) raises "Finished". Don't key completion on `done`: herdr only shows `done` until the pane is viewed, so a visible pane goes straight from `working` to `idle`. There are no Flutter plugins for this; the Kotlin is plain platform APIs.
- All input goes over the pane WS. Terminal keystrokes and the control keys go through `TerminalScreen._send`, which applies an armed CTRL once; special keys use `Terminal.keyInput` so they follow cursor-key mode. The keyboard button left of the message box swaps it for the control keys (`KeyboardAccessoryBar`) and back (pref `show_keys`, default off). The message box (`_sendMessage`) sends its text as one bracketed paste (when the pane has enabled it) plus Enter; an empty box sends just Enter. Sent messages are kept in pref `message_history` and offered, with quick replies, by the box's history button.
- Workspaces, tabs and agents are kept apart. `WorkspaceDrawer` (opened by the workspace button at the left of the top bar or swiping from the left edge) lists workspaces; long-press a workspace for its actions; its drag handle reorders it, worktrees included (herdr's own order, so the desktop follows). The rest of the top bar is the current workspace's tabs, like a browser's: a scrolling strip of `ChoiceChip`s with each tab's agent status dot, kept scrolled to the current one, plus a new-tab button. `showTabSheet` (`tab_sheet.dart`), opened by swiping up on the message bar or long-pressing a tab, has the current tab's split panes and rename/close per tab. Swiping the message bar sideways (raw pointers in `_trackSwipe`, since the text field would win a gesture arena) slides the terminal (`_slide`) to the neighbouring agent from `_stops`, across all workspaces in herdr's order (workspace, tab, pane; not the agent sheet's urgency order, so swiping back returns where you were). `showAgentSheet` (`agent_sheet.dart`), opened by `AgentsButton` right of the message box, lists every agent most urgent first; the button shows the agent count in a ring, and its badge takes the most urgent status among agents not on screen, with the blocked count. The UI is Material 3: the theme in `main.dart` is `ColorScheme.fromSeed`, widgets use scheme roles, the type scale and stock M3 components; the list-tile pill style is set once in its `listTileTheme`; only the terminal uses the Meslo font, and only `AgentStatus.color` is hardcoded.
- `lib/changelog.dart` (newest first) drives the first-launch welcome and the one-time "What's new" dialog, keyed by the `last_seen_changelog` pref. When releasing, bump the version in `pubspec.yaml` (Gradle reads it), then add a changelog entry.
- `models/session.dart` mirrors the Herdr snapshot schema (`workspaces`/`tabs`/`panes`/`agents`, snake_case ids like `w1:p1`). Agent statuses are `working | blocked | done | idle | unknown` (`AgentStatus`, an enum with each one's label and colour).
