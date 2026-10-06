# Herdr Mobile

Manage and monitor your AI coding agents from your phone with [Herdr](https://herdr.dev).

## Architecture

Herdr Mobile consists of two components:
1. **`bridge/`**: A lightweight companion daemon written in Rust. It communicates with the local Herdr daemon via Unix Domain Socket (`herdr.sock`), exposes real-time session state and bidirectional PTY streaming over WebSockets. The app itself raises the alerts when agents need input or finish.
2. **`mobile/`**: A cross-platform Flutter mobile application. It features a Terminal-First interface powered by `xterm.dart`, a native workspace/tab/agent navigation drawer with live status badges (`working`, `blocked`, `done`, `idle`), and a pinned mobile keyboard accessory bar (`Esc`, `Tab`, `Ctrl`, `Alt`, Arrows, `Ctrl+C`).

## Network Security

The bridge binds to the Tailscale interface (`100.x.y.z:7788`), ensuring secure, authenticated end-to-end communication without exposing ports to the public internet or requiring complex token management.

## Quickstart: Deploying the Bridge

The bridge runs as a lightweight user daemon on the machine hosting Herdr. It requires no `sudo` / root privileges.

### Linux & macOS (Native) / Windows (WSL2)

From the repository root:
```bash
./deploy/install.sh
```

This will:
1. Install `herdr-bridge` to `~/.local/bin/`.
2. Configure and start the background daemon:
   - **Linux / WSL2**: User systemd unit (`systemctl --user status herdr-bridge`).
   - **macOS**: launchd LaunchAgent (`launchctl list | grep dev.herdr.bridge`).
3. Display your Tailscale IP and port (`7788`) ready to enter into the mobile app.

To check service logs:
- **Linux / WSL2**: `journalctl --user -u herdr-bridge -f`
- **macOS**: `tail -f /tmp/herdr-bridge.stdout.log`
