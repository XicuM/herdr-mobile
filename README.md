# 🐮 Herdr Mobile

<p align="center">
  <strong>Pocket command center for your AI coding agents.</strong><br>
  Monitor, prompt, and control your AI agents from anywhere with <a href="https://herdr.dev">Herdr</a>.
</p>

<p align="center">
  <a href="https://github.com/herdr-dev/herdr-mobile/releases"><img src="https://img.shields.io/github/v/release/herdr-dev/herdr-mobile?color=blue&label=release" alt="Release"></a>
  <img src="https://img.shields.io/badge/Flutter-3.24+-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/Rust-2021-DEA584?logo=rust&logoColor=white" alt="Rust">
  <img src="https://img.shields.io/badge/Tailscale-Ready-4E73DF?logo=tailscale&logoColor=white" alt="Tailscale">
  <img src="https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white" alt="Android">
</p>

---

## 📸 Screenshots

<p align="center">
  <img src="docs/screenshots/agents_home.png" width="30%" alt="Agents Home Feed" />
  <img src="docs/screenshots/terminal_view.png" width="30%" alt="Interactive Terminal" />
  <img src="docs/screenshots/workspaces_drawer.png" width="30%" alt="Workspaces & Tabs" />
</p>

> *Place your screenshots inside [`docs/screenshots/`](docs/screenshots/) (`agents_home.png`, `terminal_view.png`, `workspaces_drawer.png`) to update the previews above.*

---

## ✨ Features

- 💬 **WhatsApp-Style Agent Feed**: All your AI coding agents across multiple machines aggregated in a single list, prioritized by urgency (`working`, `needs you`, `done`, `idle`).
- ⚡ **Interactive Terminal Streaming**: Low-latency PTY takeover with rendered viewports, touch-friendly scrollback, and bracketed paste message input.
- 🎛️ **Mobile-First Dev Keyboard**: One-tap access to essential terminal keys (`Esc`, `^C`, `Tab`, `⇧Tab`, `Ctrl`, arrow keys) and persistent prompt history / quick replies.
- 🔔 **Instant Background Alerts**: Native Android background notifications ping you the second an agent requires feedback or completes a task.
- 🌐 **Multi-Machine & Multi-Agent**: Manage local processes, remote SSH machines, and Tailscale nodes seamlessly from one app.
- 📂 **Workspaces & Worktrees**: Full tab and workspace management with drag-and-drop reordering, branch switching, and worktree support.
- 📱 **Responsive List-Detail UI**: Optimized for single-hand phone use and side-by-side split screen on tablets and foldable devices.

---

## 🏗️ Architecture

```text
┌─────────────────┐       WebSocket / HTTP        ┌───────────────────┐       Unix Socket / SSH       ┌─────────────────┐
│  Flutter Client │ ◄───────────────────────────► │    Rust Bridge    │ ◄───────────────────────────► │  Herdr Daemon   │
│  (Android App)  │   Bearer Auth + Tailscale     │  (herdr-bridge)   │     ~/.config/herdr/herdr.sock │  (AI Agents)    │
└─────────────────┘                               └───────────────────┘                               └─────────────────┘
```

Herdr Mobile is composed of two minimal, zero-bloat pieces:
1. **`bridge/`**: A lightweight companion daemon written in Rust (Axum + Tokio). Connects to Herdr's local IPC socket (`herdr.sock`), multiplexes remote machines over SSH, and streams real-time state and PTY sessions over authenticated WebSockets.
2. **`app/`**: A native Android Flutter client powered by `xterm.dart` and Material 3 design, delivering smooth terminal interaction and instant alerts.

---

## 🚀 Quickstart: Deploying the Bridge

The bridge runs as a lightweight user daemon on your development machine where Herdr is active. It requires **no root / `sudo` privileges**.

### Linux & macOS (Native) / Windows (WSL2)

Run the automated installer from the repository root:

```bash
./deploy/install.sh
```

**What this does:**
1. Installs `herdr-bridge` binary to `~/.local/bin/`.
2. Generates a secure authorization token at `~/.config/herdr-bridge/token`.
3. Registers and starts the background user service:
   - **Linux / WSL2**: User systemd unit (`herdr-bridge.service`).
   - **macOS**: launchd agent (`dev.herdr.bridge.plist`).
4. Prints your **Tailscale IP**, **Port (`7788`)**, and **Token** to plug straight into the mobile app.

---

## 📱 Mobile App Setup

1. Grab the latest APK from the [**Releases**](https://github.com/herdr-dev/herdr-mobile/releases) page.
2. Open the app, tap the **Machines** icon (top right) ➔ **Add Bridge**.
3. Enter:
   - **Host / IP**: Your Tailscale IP (e.g. `100.x.y.z` or MagicDNS name)
   - **Port**: `7788` (default)
   - **Token**: The 8-character token printed by `./deploy/install.sh` (or `herdr-bridge --print-token`)
4. That's it! Your active agents and workspaces will sync immediately.

---

## 🔒 Security & Networking

Herdr Mobile is designed to be secure by default:

- **Token Authentication**: Every request (except `/health`) requires `Authorization: Bearer <token>`. Failed attempts are delayed and rate-limited to eliminate brute-force risks.
- **Tailscale First**: The bridge is built to sit on your Tailnet. Direct internet port forwarding is neither needed nor recommended.
- **Anti-Rebinding & Browser Blocking**: Refuses browser requests (rejects `Origin` headers) and blocks non-Tailscale dotted domain names to protect against malicious websites on your network.

---

## 🛠️ Service Management

<details>
<summary><b>Useful Bridge Commands</b></summary>

```bash
# Print your auth token
herdr-bridge --print-token

# View live service logs
journalctl --user -u herdr-bridge -f          # Linux / WSL2
tail -f ~/Library/Logs/herdr-bridge.log       # macOS

# Check service status
systemctl --user status herdr-bridge          # Linux / WSL2
launchctl list | grep dev.herdr.bridge        # macOS

# Start manually in foreground with debug logs
RUST_LOG=herdr_bridge=debug herdr-bridge --port 7788
```
</details>

---

## 🤝 Contributing & Development

- **Bridge**: `cargo check`, `cargo test`, `cargo build --release`
- **Mobile App**: `flutter analyze`, `flutter test`, `flutter run`
