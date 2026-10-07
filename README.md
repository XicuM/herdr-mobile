# Herdr Mobile

Manage and monitor your AI coding agents from your phone with [Herdr](https://herdr.dev).

## Architecture

Herdr Mobile consists of two components:
1. **`bridge/`**: A lightweight companion daemon written in Rust. It communicates with the local Herdr daemon via Unix Domain Socket (`herdr.sock`), exposes real-time session state and bidirectional PTY streaming over WebSockets. The app itself raises the alerts when agents need input or finish.
2. **`app/`**: An Android Flutter app. It features a terminal-first interface powered by `xterm.dart`, a workspace drawer plus tab and agent sheets with live status colours (`working`, `blocked`, `done`, `idle`), and a control keys bar (`Esc`, `^C`, `Tab`, `⇧Tab`, `Ctrl`, arrows).

## Network Security

Every request to the bridge must carry its token (`Authorization: Bearer …`). The bridge makes the token on first start, in `~/.config/herdr-bridge/token` (readable by you only). `install.sh` prints it, and `herdr-bridge --print-token` shows it again. Enter it in the app when adding the machine. The token keeps out other users of the same computer and other devices on your tailnet, which Tailscale alone lets in.

`deploy/start-bridge.sh` also binds the bridge to the Tailscale interface only (`100.x.y.z:7788`); run on its own, the bridge listens on `127.0.0.1`. Traffic is plain HTTP, encrypted only by Tailscale, so don't bind it to `0.0.0.0` on an untrusted network. To narrow it further, a [Tailscale ACL](https://tailscale.com/kb/1018/acls) can limit port 7788 to your own devices. The bridge also refuses requests from web browsers, so a web page open on one of your devices can't reach it.

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
3. Display your Tailscale IP, port (`7788`) and token, ready to enter into the mobile app.

To check service logs:
- **Linux / WSL2**: `journalctl --user -u herdr-bridge -f`
- **macOS**: `tail -f /tmp/herdr-bridge.stdout.log`
