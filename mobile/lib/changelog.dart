/// Newest first. Shown once after an update; add an entry when bumping the version
/// in pubspec.yaml and android/app/build.gradle.
const changelog = <(String, List<String>)>[
  (
    '1.3.1',
    [
      'Fixed the app getting stuck on "Connecting…" after the phone wakes from sleep.',
    ]
  ),
  (
    '1.3.0',
    [
      'Notifications: get an alert when an agent needs you or finishes, even with the app closed. Tap it to open that pane.',
      'An ongoing notification shows which machine you are connected to and how many agents are working or waiting.',
      'The first launch asks to allow notifications and background use. Turn alerts off under Settings → Notifications.',
      'Needs the updated herdr-bridge. The bridge no longer sends ntfy or Pushover alerts.',
    ]
  ),
  (
    '1.2.0',
    [
      'A message box under the terminal: type with autocorrect, swipe and voice input, and send it to the pane (empty sends Enter).',
      'A simpler key bar: ESC, ^C, TAB, ⇧TAB, CTRL and arrows. CTRL now works, also with the phone keyboard. Hold an arrow to repeat it.',
      'A ⚠ count in the top bar jumps to agents waiting for input in other panes. The waiting banner now sends Enter/Esc.',
      'Scroll back through the full pane history kept by herdr (needs the updated herdr-bridge).',
      'Pinch to change the font size. Long-press to select text, then tap copy next to the message box.',
      'A "Connecting…" strip shows while the bridge is unreachable, and failed actions now show an error.',
      'Machines can have names, and any machine can be removed in Settings.',
      'Switching panes or machines starts from a clean screen; bigger tap targets in the drawer.',
    ]
  ),
  (
    '1.1.0',
    [
      'Multiple machines: add every computer running herdr-bridge and switch between them from the machine menu (top right) or the drawer.',
      'The machine menu is always available, even when not connected.',
      'Welcome guide on first launch and this changelog after updates.',
    ]
  ),
];
