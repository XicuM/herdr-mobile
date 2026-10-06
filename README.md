# Herdr Mobile

Manage and monitor your AI coding agents from your phone with [Herdr](https://herdr.dev).

## Architecture

Herdr Mobile consists of two components:
1. **`bridge/`**: A lightweight companion daemon written in Rust. It communicates with the local Herdr daemon via Unix Domain Socket (`herdr.sock`), exposes real-time session state and bidirectional PTY streaming over WebSockets. The app itself raises the alerts when agents need input or finish.
2. **`app/`**: An Android Flutter app. It features a terminal-first interface powered by `xterm.dart`, a workspace drawer plus tab and agent sheets with live status colours (`working`, `blocked`, `done`, `idle`), and a control keys bar (`Esc`, `^C`, `Tab`, `⇧Tab`, `Ctrl`, arrows).

## Network Security

The bridge has no authentication of its own: anyone who can reach it can type into your terminals. `deploy/start-bridge.sh` therefore binds it to the Tailscale interface only (`100.x.y.z:7788`), so only devices on your tailnet can reach it; run on its own, the bridge listens on `127.0.0.1`. Don't bind it to `0.0.0.0` on an untrusted network. It also refuses requests from web browsers, so a web page open on one of your devices can't reach it.

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
