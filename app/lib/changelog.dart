/// Newest first. Shown once after an update; add an entry when bumping the version in pubspec.yaml.
const changelog = <(String, List<String>)>[
  (
    '1.7.2',
    [
      'The time on an agent in the list lines up with its summary.',
    ]
  ),
  (
    '1.7.0',
    [
      'A new home screen, like a chat list: every agent on every machine, the ones that need you first and in bold. Each shows its summary on top, and under it its workspace, tab and status ("Working…" while it works), with its logo and when it last changed.',
      'Swipe an agent right to mute it, left to close it (with Undo), or long-press to pick several.',
      'An agent\'s terminal is headed the same way. Tap the header for the workspace\'s actions; the menu mutes, renames the tab or closes the agent. Back returns to the list.',
      'Swiping the message bar now goes on to the agents of your other machines.',
      'The computer icon, top right and green while one is connected, opens a panel with your machines: how each is doing, a switch to turn it on or off, + to add one, and tap one to edit or remove it. Settings no longer lists them.',
      'Errors show on every screen, not only in a terminal.',
      'The accent colour follows your wallpaper (Material You, Android 12+) unless you pick one in Settings.',
      'Each agent keeps its own unsent message while you go to another.',
      'Copied text loses the trailing spaces herdr pads each row with, and lines an agent wrapped are joined again.',
      'The ☰ menu lists every machine\'s workspaces with their worktrees, and Settings: tap one to open it, long-press for its actions, drag to reorder; the + by a machine\'s name opens a new workspace there.',
      'The search bar on top finds agents, workspaces, worktrees, tabs and machines by name, branch, place or status ("needs you").',
      'Easier on the battery: a machine that can\'t be reached is retried less and less often (every few minutes at most), while the app is closed the connection is checked less often, and herdr-bridge no longer sends an update every second or two while an agent works (update it too).',
      'The ⚡ by the message box shows the agent\'s usage: how much of each rate limit is left, when it resets, and today\'s tokens and prompts.',
      'Swipe up on the message bar for your recent messages; with a keyboard, ↑ and ↓ in the message box go through them.',
    ]
  ),
  (
    '1.6.0',
    [
      'This version is signed with a new, permanent key, so it had to be installed fresh. From now on updates install over each other and keep your machines and settings.',
      'The machines saved in a computer\'s herdr (herdr machine) appear under it, reached over SSH from that computer: they need neither Tailscale nor herdr-bridge. One that can\'t be reached says why.',
      'Light and dark themes and an accent colour, in Settings. The volume keys can send ↑/↓ instead of changing the font size.',
      'Long-press and drag a tab onto another to move it, or onto the bin that replaces + to close it. Long-press and let go to rename it.',
      'Deleting a workspace or worktree no longer asks first.',
      'The connection notification has a Disconnect button.',
      'When a terminal can\'t be opened, it says why.',
      'Agents that need you are counted as "needs you", as in the alerts.',
      'Fixes: going back to live after scrolling back now always reaches the bottom; a held arrow key no longer keeps repeating when another is pressed; an agent in a reused pane no longer misses its "Finished" alerts.',
    ]
  ),
  (
    '1.5.1',
    [
      'Showing a disconnected machine no longer connects it, and no longer shows its old tabs and workspaces.',
    ]
  ),
  (
    '1.5.0',
    [
      'Tabs: the top bar shows the workspace\'s tabs like a browser\'s, each with its label and its agents, the current one joined to the terminal. Tap one to switch, + for a new one, long-press to rename or close it.',
      'The menu button at the top left opens the workspaces, with the machines and Settings below them.',
      'Swipe the message bar left or right to go from agent to agent, across workspaces; past the last agent it wraps back to the first.',
      'In the agent list, the bell mutes an agent so it never alerts you, and the X closes it.',
      'The agents button right of the message box shows how many agents are running, badged with how many elsewhere are waiting for you.',
      'The message bar and the current tab take the colour of the app in the terminal.',
      'The history button in the message box offers your earlier messages to edit and resend, and quick replies (yes, no, /clear…) that send with one tap.',
      'Needs the updated herdr-bridge for closing agents. Its start script now listens on the computer\'s Tailscale IP only.',
    ]
  ),
  (
    '1.4.0',
    [
      'Agents: the circle left of the message box shows how many agents are running; tap it for the list, the ones waiting for you first, and tap one to jump to it. Its badge shows the most urgent status elsewhere, with a count when agents are blocked.',
      'Tabs: the dots above the key bar show where you are among the workspace\'s tabs, coloured by their agents. Swipe up on the message bar (or tap the dots) to switch, create, rename or close tabs, or pick a split pane.',
      'Swipe the message bar left or right to slide to the next or previous tab; swiping past the last tab opens a new one.',
      'Tap the title (or ☰) for workspaces. Long-press a workspace for its actions.',
      'Material 3 look throughout.',
      'Agent status colours match herdr: yellow working, red waiting for you, green finished, grey idle.',
      'While scrolled back through history, a ↓ button at the bottom (or typing anything) jumps back to live.',
      '› in the message box offers quick replies and your earlier messages.',
      'Several machines can be connected at once. Tap the machine chip in the top bar for a panel with each machine\'s status; connect or disconnect each one on its own, and tap one to show it.',
      'Alerts come from every connected machine. Disconnected machines stay off, even after a restart, to save battery.',
      "Edit a saved machine's name or address in Settings (tap it). Add one with a single address field (host or host:port).",
      'Opening a pane on the phone marks it seen in herdr, so a finished agent goes from done to idle, and the desktop follows to that pane.',
      'Needs the updated herdr-bridge for renaming tabs and marking panes seen.',
    ]
  ),
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
