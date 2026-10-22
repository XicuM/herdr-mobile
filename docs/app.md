# Herdr Mobile App (Flutter)

Terminal-first mobile companion app for [Herdr](https://herdr.dev).

## Features

- **Full-screen terminal**: `xterm.dart` showing the pane as herdr renders it. Drag to scroll back through herdr's history; a ↓ button returns to live.
- **Agent awareness**: status colours as in herdr: yellow working, red blocked (waiting for you), green done, grey idle. The circle next to the message box lists every agent, most urgent first.
- **Control keys bar**: `[ESC]` `[^C]` `[TAB]` `[⇧TAB]` `[CTRL]` `[←]` `[↓]` `[↑]` `[→]`.
- **Message box**: type with autocorrect and voice; sends as one paste plus Enter. Earlier messages go back in the box to edit, and recent slash commands send again with one tap.
- **Navigation**: tap the title for workspaces, swipe the top bar between tabs and the message bar between agents.
- **Several machines** at once, with background alerts when an agent needs you or finishes.

## Getting Started

### 1. Prerequisites
- [Flutter SDK](https://flutter.dev) (v3.22+; CI builds with 3.24)
- A mobile phone or simulator with [Tailscale](https://tailscale.com) installed and signed into your Tailnet.

### 2. Configure & Run
From your development machine:
```bash
flutter pub get
flutter run
```

### 3. Connect to Herdr
1. On each computer running Herdr, start the bridge ([herdr-bridge](https://github.com/XicuM/herdr-bridge)'s `plugin/install.sh --bridge` sets it up as a service); it listens on `127.0.0.1:7788`, and `tailscale serve` brings the tailnet to it.
2. Run `plugin/install.sh --phone` there, open the app on your phone and tap **Add a machine**.
3. Scan its pairing QR code with the scan button in **Address** (or paste its link there, or type the computer's Tailscale IP or MagicDNS name and the token), optionally a name, and tap **Add**.
4. Allow notifications and background use when asked. The app stays connected in the background (shown as an ongoing notification) and alerts you when an agent needs you or finishes.
5. To stop a machine's connection and save battery, tap the machine chip in the top bar and turn its switch off.
