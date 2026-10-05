/// Newest first. Shown once after an update; add an entry when bumping the version
/// in pubspec.yaml and android/app/build.gradle.
const changelog = <(String, List<String>)>[
  (
    '1.1.0',
    [
      'Multiple machines: add every computer running herdr-bridge and switch between them from the machine menu (top right) or the drawer.',
      'The machine menu is always available, even when not connected.',
      'Welcome guide on first launch and this changelog after updates.',
    ]
  ),
];
