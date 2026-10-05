# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A phone companion for [Herdr](https://herdr.dev) (a terminal multiplexer for AI coding agents). It has two parts that talk over HTTP/WebSocket on port 7788, and the bridge is meant to bind to the host's Tailscale IP. There's no auth layer: Tailscale is the security boundary.

- `bridge/`: Rust daemon (axum + tokio). It translates between Herdr's Unix-socket JSON-RPC (`~/.config/herdr/herdr.sock`) and HTTP/WS, and sends push alerts.
- `mobile/`: Flutter app (Android only; no `ios/` dir). It's a terminal-first UI on `xterm` 4.x.

## Commands

Bridge (run from `bridge/`):
```bash
cargo build --release
cargo run -- --bind 0.0.0.0 --port 7788 --ntfy-topic <topic>   # flags also read from env: HERDR_SOCKET, HERDR_BRIDGE_BIND, HERDR_BRIDGE_PORT, NTFY_TOPIC, PUSHOVER_USER, PUSHOVER_TOKEN
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
CI (`.github/workflows/build-apk.yml`) runs only `flutter build apk --release` on Flutter 3.24.x / JDK 17 for every push to main, and uploads the APK. It doesn't test or check the bridge. Keep Flutter/Gradle/AGP versions compatible with 3.24.x. Recent commits were spent fixing CI build breakage.

## Architecture

**Bridge data flow** (`bridge/src/`):
- `herdr.rs` `HerdrClient`: each `call()` opens a new Unix socket connection, writes one newline-delimited JSON request `{id, method, params}`, and reads one response line. The methods used are `session.snapshot`, `pane.read` (visible screen, ANSI), `pane.send_input` (`text` and/or `keys`) and `pane.resize`. A separate long-lived connection runs `events.subscribe` and fans the events out through a `tokio::broadcast` channel. It reconnects forever.
- `server.rs` routes:
  - `GET /`, `/app`: the embedded `index.html` web client (`include_str!`, so rebuild after you edit it)
  - `GET /health`, `GET /api/snapshot`
  - `POST /api/pane/{id}/input`, `POST /api/pane/{id}/resize`
  - `WS /ws/session`: sends the initial `{"type":"snapshot","data":…}`, then forwards every Herdr event as `{"type":"event","data":…}`
  - `WS /ws/pane/{id}`: **there's no real PTY stream.** The bridge polls `pane.read` every 150 ms (and also after events for that pane) and, when the content has changed, sends the full visible screen as a text frame. Inbound frames are either `{"type":"input","text"|"keys"}` or `{"type":"resize","cols","rows"}`. Anything else is treated as raw input text.
- `notifier.rs`: does nothing unless ntfy or Pushover is configured. When it is, two paths run in parallel: an event watcher, plus a 1.5 s snapshot poller that diffs each pane's `agent_status` and alerts on `→ blocked` and `working → done`. Both paths can fire for the same transition.
- Herdr payload shapes are handled loosely: code checks both `/event/<field>` and top-level `<field>`, and `snapshot.snapshot` vs bare snapshot. Keep that tolerance unless you've confirmed the real schema.

**Mobile** (`mobile/lib/`):
- State lives in `HerdrClientService` (a `ChangeNotifier` created in `main.dart` and passed down through constructors). `flutter_riverpod` is a dependency but isn't used.
- `HerdrClientService` holds the `/ws/session` socket. On any `event` it re-fetches `/api/snapshot` over HTTP instead of applying the event. It reconnects every 3 s. Host and port come from `SharedPreferences` keys `herdr_host` and `herdr_port`.
- `PtyChannel` holds one `/ws/pane/{id}` socket per selected pane and writes incoming frames straight into the xterm `Terminal`. Terminal output (keystrokes) goes back as `input` JSON. `TerminalScreen` rebuilds the channel and clears the display whenever `selectedPaneId` changes.
- Input travels two ways: terminal keystrokes over the pane WS, and the accessory bar and approval banner over `HerdrClientService.sendPaneInput` (HTTP POST).
- `models/session.dart` mirrors the Herdr snapshot schema (`workspaces`/`tabs`/`panes`/`agents`, snake_case ids like `w1:p1`). Agent statuses are `working | blocked | done | idle | unknown`.
