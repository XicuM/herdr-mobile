# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A phone companion for [Herdr](https://herdr.dev) (a terminal multiplexer for AI coding agents). It has two parts that talk over HTTP/WebSocket on port 7788, and the bridge is meant to bind to the host's Tailscale IP. There's no auth layer: Tailscale is the security boundary.

- `bridge/`: Rust daemon (axum + tokio). It translates between Herdr's Unix-socket JSON-RPC (`~/.config/herdr/herdr.sock`) and HTTP/WS.
- `mobile/`: Flutter app (Android only; no `ios/` dir). It's a terminal-first UI on `xterm` 4.x.

## Commands

Bridge (run from `bridge/`):
```bash
cargo build --release
cargo run -- --bind 0.0.0.0 --port 7788   # flags also read from env: HERDR_SOCKET, HERDR_BRIDGE_BIND, HERDR_BRIDGE_PORT
RUST_LOG=herdr_bridge=debug cargo run
../deploy/start-bridge.sh        # auto-detects the Tailscale IP, runs target/release (falls back to target/debug)
```
The bridge has no tests. `deploy/herdr-bridge.service` is a systemd unit with hardcoded `/home/xicu/herdr-mobile` paths.

Mobile (run from `mobile/`):
```bash
flutter pub get
flutter run
flutter test                                  # only test/widget_test.dart (model JSON parsing)
flutter test test/widget_test.dart --plain-name "SessionSnapshot parses correctly from JSON"
flutter analyze                               # no analysis_options.yaml, so flutter_lints isn't actually applied
flutter build apk --release
```
CI (`.github/workflows/build-apk.yml`) runs on every push to main and on `v*` tags: `flutter build apk --release` on Flutter 3.24.x / JDK 17, plus `cargo build --release` for the bridge on native ubuntu-22.04 x86_64 and arm runners. On a tag it attaches the APK and `herdr-bridge-linux-{x86_64,aarch64}` to the GitHub release. No tests run. Keep Flutter/Gradle/AGP versions compatible with 3.24.x. Recent commits were spent fixing CI build breakage.

## Architecture

**Bridge data flow** (`bridge/src/`):
- `herdr.rs` `HerdrClient`: each `call()` opens a new Unix socket connection, writes one newline-delimited JSON request `{id, method, params}`, and reads one response line. The methods used are `session.snapshot`, `pane.read` (visible screen, ANSI), `pane.send_input` (`text` and/or `keys`) and `pane.resize`. A separate long-lived connection runs `events.subscribe` and fans the events out through a `tokio::broadcast` channel. It reconnects forever.
- `server.rs` routes:
  - `GET /health`, `GET /api/snapshot`
  - `POST /api/pane/{id}/input` (no longer used by the app), `POST /api/tab`, `POST /api/workspace`
  - `WS /ws/session`: forwards every Herdr event as `{"type":"event","data":…}`, and every 1.5 s polls the snapshot and sends it as `{"type":"snapshot","data":…}` when it changed (the first one on connect). The poll is needed because herdr's global `events.subscribe` carries no agent status changes (`pane.agent_status_changed` requires a `pane_id`).
  - `WS /ws/term/{id}?cols&rows`: a real terminal stream. It spawns `herdr terminal session control <pane> --takeover` and relays its base64 frames as binary WS frames. Binary frames in are terminal input. A text frame with a `type` (e.g. `{"type":"terminal.scroll","direction":"up"|"down","lines":N}`) goes to herdr as-is; one without is a resize `{"cols","rows"}`. The frames out are herdr's *rendered viewport* (clear screen plus absolute cursor moves, no newlines), so the client never accumulates scrollback: history lives in herdr and is reached with `terminal.scroll`. On close it sends `terminal.release` so the desktop gets its size back.
- Herdr payload shapes are handled loosely: code checks both `/event/<field>` and top-level `<field>`, and `snapshot.snapshot` vs bare snapshot. Keep that tolerance unless you've confirmed the real schema.

**Mobile** (`mobile/lib/`):
- State lives in `HerdrClientService` (a `ChangeNotifier` created in `main.dart` and passed down through constructors). `flutter_riverpod` is a dependency but isn't used.
- `HerdrClientService` holds the `/ws/session` socket. On any `event` it re-fetches `/api/snapshot` over HTTP instead of applying the event. It reconnects every 3 s. It talks to one bridge (machine) at a time: the active host and port are in `SharedPreferences` keys `herdr_host` and `herdr_port`, and saved machines are in `herdr_machines` (a list of `host:port`), and optional names in `herdr_machine_names` (`host:port=name`). `configure()` switches machines and clears the snapshot and the selected pane. Failed bridge requests go to the `onError` callback, which `TerminalScreen` shows as a SnackBar.
- `PtyChannel` holds one `/ws/term/{id}` socket for the selected pane and writes incoming bytes straight into the single xterm `Terminal`. It switches xterm to the alt screen (no local scrollback) and clears it on every (re)connect, because herdr repaints the pane on attach. One-finger drags on the terminal send `terminal.scroll` (`TerminalScreen._scroll`); xterm's own `simulateScroll` is off. `TerminalScreen` rebuilds the channel whenever `selectedPaneId` or the machine changes, and drops it while the app is in the background so the takeover ends.
- **Background alerts** (Android side in `android/.../HerdrApp.kt`): `HerdrApp` (the `Application`) owns the Flutter engine, so Dart, and with it `HerdrClientService`, outlives `MainActivity`. While alerts are on (pref `background_alerts`), Dart drives `StatusService`, a foreground service whose ongoing notification shows the connection state, over the `herdr/android` MethodChannel (`status`, `alert`, `cancel`, `askPermissions`; native calls back `open` when an alert is tapped). The `HerdrClientService.notifyListeners` override pushes the status on every change. `_alertChanges` diffs consecutive snapshots: a pane entering `blocked` raises "Needs you", and an agent's `completion_seq` changing raises "Finished". Don't key completion on `done`: herdr only shows `done` until the pane is viewed, so a visible pane goes straight from `working` to `idle`. There are no Flutter plugins for this; the Kotlin is plain platform APIs.
- All input goes over the pane WS. Terminal keystrokes and the key bar go through `TerminalScreen._send`, which applies an armed CTRL once; special keys use `Terminal.keyInput` so they follow cursor-key mode. The message box under the key bar (`_sendMessage`) sends its text as one bracketed paste (when the pane has enabled it) plus Enter; an empty box sends just Enter.
- `lib/changelog.dart` (newest first) drives the first-launch welcome and the one-time "What's new" dialog, keyed by the `last_seen_changelog` pref. When releasing, bump the version in both `pubspec.yaml` and `android/app/build.gradle`, then add a changelog entry.
- `models/session.dart` mirrors the Herdr snapshot schema (`workspaces`/`tabs`/`panes`/`agents`, snake_case ids like `w1:p1`). Agent statuses are `working | blocked | done | idle | unknown`.
