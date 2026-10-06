# Herdr Mobile App (Flutter)

Terminal-first mobile companion app for [Herdr](https://herdr.dev).

## Features

- **Full-Screen Terminal Emulator**: Powered by `xterm.dart` with ANSI color support, scrollback, and smooth gesture scrolling.
- **Agent Awareness**: Live status badges for coding agents:
  - 🟢 **Working**: Agent actively executing instructions
  - 🟡 **Blocked**: Agent waiting for user confirmation/approval
  - 🔵 **Done / Idle**: Agent finished or waiting for next task
- **Quick Action Accessory Bar**: Pinned above the mobile keyboard:
  - `[ESC]` `[^C]` `[TAB]` `[⇧TAB]` `[CTRL]` `[←]` `[↓]` `[↑]` `[→]`
- **1-Tap Approval Banner**: Surfaces quick `[Enter]` and `[Esc]` action buttons when an agent is waiting for approval.
- **Workspace Navigation Drawer**: Swipe from the left edge to view all Workspaces, Tabs, and Panes with live agent status.

## Getting Started

### 1. Prerequisites
- [Flutter SDK](https://flutter.dev) (v3.16+)
- A mobile phone or simulator with [Tailscale](https://tailscale.com) installed and signed into your Tailnet.

### 2. Configure & Run
From your development machine:
```bash
cd mobile
flutter pub get
flutter run
```

### 3. Connect to Herdr
1. Open the app on your phone.
2. Tap the machine icon in the top right (or open the navigation drawer and tap **Settings**).
3. Set **Host** to your host machine's Tailscale IP (e.g. `100.x.y.z`).
4. Set **Port** to `7788`.
5. Tap **Add & Connect**.
6. Allow notifications and background use when asked. The app stays connected to the active machine in the background (shown as an ongoing notification) and alerts you when an agent needs you or finishes.
7. To stop background sessions and save battery at any time, tap the machine icon in the top bar and select **Disconnect**.
