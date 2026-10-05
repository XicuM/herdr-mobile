/// Newest first. Shown once after an update; add an entry when bumping the version
/// in pubspec.yaml and android/app/build.gradle.
const changelog = <(String, List<String>)>[
  (
    '1.2.0',
    [
      'Compose (✎ in the key bar): type a message with autocorrect, swipe and voice input, then send it to the pane.',
      'CTRL and ALT now work, for key bar keys and the phone keyboard alike. New keys: ⇧TAB, HOME/END, PGUP/PGDN, | / ~ -, paste and copy. Hold an arrow to repeat it.',
      'A ⚠ count in the top bar jumps to agents waiting for input in other panes. The waiting banner now sends Enter/Esc.',
      'Scroll back through the full pane history kept by herdr (needs the updated herdr-bridge).',
      'Pinch to change the font size. Long-press to select text, then copy it from the key bar.',
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
