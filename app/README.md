# Herdr Mobile App (Flutter)

Terminal-first mobile companion app for [Herdr](https://herdr.dev).

## Features

- **Full-screen terminal**: `xterm.dart` showing the pane as herdr renders it. Drag to scroll back through herdr's history; a ↓ button returns to live.
- **Agent awareness**: status colours as in herdr: yellow working, red blocked (waiting for you), green done, grey idle. The circle next to the message box lists every agent, most urgent first.
- **Control keys bar**: `[ESC]` `[^C]` `[TAB]` `[⇧TAB]` `[CTRL]` `[←]` `[↓]` `[↑]` `[→]`.
- **Message box**: type with autocorrect and voice; sends as one paste plus Enter. Earlier messages and quick replies are a tap away.
- **Navigation**: tap the title for workspaces, swipe the top bar between tabs and the message bar between agents.
- **Several machines** at once, with background alerts when an agent needs you or finishes.

## Getting Started

### 1. Prerequisites
- [Flutter SDK](https://flutter.dev) (v3.22+; CI builds with 3.24)
- A mobile phone or simulator with [Tailscale](https://tailscale.com) installed and signed into your Tailnet.

### 2. Configure & Run
From your development machine:
```bash
cd app
flutter pub get
flutter run
```

### 3. Connect to Herdr
1. On each computer running Herdr, start the bridge (`deploy/install.sh` sets it up as a service); it listens on the computer's Tailscale IP, port 7788.
2. Open the app on your phone and tap **Add a machine**.
3. Enter the computer's Tailscale IP or MagicDNS name (add `:port` if it isn't 7788), optionally a name, and tap **Add & connect**.
4. Allow notifications and background use when asked. The app stays connected in the background (shown as an ongoing notification) and alerts you when an agent needs you or finishes.
5. To stop a machine's connection and save battery, tap the machine chip in the top bar and turn its switch off.
