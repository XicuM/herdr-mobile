# Herdr Mobile

Manage and monitor your AI coding agents from your phone with [Herdr](https://herdr.dev).

## Architecture

Herdr Mobile consists of two components:
1. **`bridge/`**: A lightweight companion daemon written in Rust. It communicates with the local Herdr daemon via Unix Domain Socket (`herdr.sock`), exposes real-time session state and bidirectional PTY streaming over WebSockets, and dispatches instant push alerts via `ntfy.sh` or Pushover when agents are blocked awaiting approval or complete tasks.
2. **`mobile/`**: A cross-platform Flutter mobile application. It features a Terminal-First interface powered by `xterm.dart`, a native workspace/tab/agent navigation drawer with live status badges (`working`, `blocked`, `done`, `idle`), and a pinned mobile keyboard accessory bar (`Esc`, `Tab`, `Ctrl`, `Alt`, Arrows, `Ctrl+C`).

## Network Security

The bridge binds to the Tailscale interface (`100.x.y.z:7788`), ensuring secure, authenticated end-to-end communication without exposing ports to the public internet or requiring complex token management.
