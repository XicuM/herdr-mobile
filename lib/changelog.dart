/// Newest first. Shown once after an update; add an entry when bumping the version in pubspec.yaml.
const changelog = <(String, List<String>)>[
  (
    '1.20.0',
    [
      'Tap https links in the terminal to open them directly in the browser.',
      'Tapping an agent notification navigates straight to its terminal.',
      'Message history and slash commands are scoped per workspace, with swipe-to-delete in recent messages.',
    ]
  ),
  (
    '1.19.0',
    [
      'Swiping an agent left or right reveals a Close or Mute button to press, preventing accidental actions.',
      'Closing an agent from the list closes directly without an Undo snackbar; tabs and workspaces retain Undo.',
      'Tabs reorder by dragging along the strip, and Undo snackbars in the terminal view sit above the message bar.',
    ]
  ),
  (
    '1.18.1',
    [
      'Deleting a worktree checkout asks first, in one question that warns uncommitted work goes with it, and offers no Undo.',
      'The ongoing notification counts monitoring agents apart from idle ones, as the agents list does.',
    ]
  ),
  (
    '1.18.0',
    [
      'Agents can send you files (herdr-bridge send, bridge 0.4.0): an alert with Install or Open, and a card above the agent\'s message box. An APK opens the installer.',
      'The agents list shows a file an agent sent under its name until you open or dismiss it.',
    ]
  ),
  (
    '1.17.1',
    [
      'A tab whose agent is waiting on background monitors shows it in its ring, as the agents list does.',
    ]
  ),
  (
    '1.17.0',
    [
      'Pair a machine from the herdrmobile://pair link that install.sh --phone shows: paste it in the Address field, or scan its QR code (Android).',
      'Branches show ↑ commits to push and ↓ to pull, in the drawer, the search results and the terminal\'s top bar; a workspace can hide its worktrees.',
      'Images paste into the terminal with Ctrl+V and are sent as they were copied, without re-encoding.',
      'With text selected, Ctrl+C copies it; Alt+Up and Alt+Down step through agents.',
      'Dragging a tab shows a line where it will land, and an agent keeps its change time across restarts.',
    ]
  ),
  (
    '1.16.0',
    [
      'The workspaces menu mirrors herdr\'s own sidebar: rename, close or close group, new/open worktree, and delete worktree checkout.',
      'A pane herdr couldn\'t restore shows why in place of the terminal, and the open tab\'s menu can clear it.',
      'Copying in a pane puts the text on the clipboard (OSC 52).',
      'Unreachable SSH machines say why, and say to run herdr machine reconnect when SSH wants a password or MFA.',
    ]
  ),
  (
    '1.15.1',
    [
      'The recent-messages panel has a single close button, and its slash commands sit at the bottom.',
      'Antigravity\'s quota counts only Gemini: its Claude and GPT tiers are listed under "Other models" in the usage sheet.',
    ]
  ),
  (
    '1.15.0',
    [
      'Worktrees: one dialog makes a new branch (from the main checkout or the worktree you\'re in) and opens the existing ones.',
      'A worktree can be closed, keeping its checkout to open again, or deleted; one with uncommitted changes asks before deleting them.',
      'Errors from herdr read as its message instead of raw JSON.',
      'An agent on a machine reached over SSH shows its usage too.',
      'A Linux desktop build, for x86_64 and arm64, comes with each release.',
    ]
  ),
  (
    '1.14.4',
    [
      'Recent messages now stay above the message box, which filters them as you type: tap one to edit and send, or a /command to resend it at once.',
      'A raised keyboard stays up when switching to the control keys, typing straight into the terminal.',
      'Settings can make Enter send the message instead of a new line (Shift+Enter still breaks the line).',
      'Swiping down with two fingers together closes the current tab, undoable like closing it from its menu.',
    ]
  ),
  (
    '1.14.3',
    [
      'Tapping the terminal no longer swaps in the control keys: it only clicks, and the bar is back to a CTRL label with the command-key button beside the message box.',
      'The history sheet keeps your recent slash commands (/models…) for one-tap resend instead of fixed quick replies.',
    ]
  ),
  (
    '1.14.2',
    [
      'The control keys bar shows ⌘ instead of a stale CTRL label.',
    ]
  ),
  (
    '1.14.1',
    [
      'Opening a pane the desktop is viewing no longer steals it and flickers taken-over warnings: it shows an "Another client is viewing this pane" banner with a Take over button instead, retrying quietly in the background.',
    ]
  ),
  (
    '1.14.0',
    [
      'Attach images from the message box: they upload to the bridge and drop an @-reference in to review and send.',
    ]
  ),
  (
    '1.13.1',
    [
      'An agent waiting on background monitors now shows sky-blue Monitoring… instead of Idle in the agents list.',
    ]
  ),
  (
    '1.13.0',
    [
      'Tapping the terminal opens the keyboard at once, with the control keys in place of the message box, and clicks in terminal apps that use the mouse.',
      'The keyboard button shows or hides the keyboard beside the control keys; the message button returns to the message box.',
      'The control keys scroll sideways when they don\'t fit, and a double-tap no longer selects a word.',
      'Shift+Enter in the terminal adds a new line instead of sending.',
      'A pane you come back to keeps its place in the history, unless its agent has moved on since.',
    ]
  ),
  (
    '1.12.6',
    [
      'Nest each worktree under one parent in the drawer and fix open-worktree reload.',
      'Prioritize active pane working directory for workspace git branch resolution in bridge.',
    ]
  ),
  (
    '1.12.4',
    [
      'Fixed worktree creation when initiating from another linked worktree.',
    ]
  ),
  (
    '1.12.3',
    [
      'In the message box, Enter inserts a newline and Ctrl+Enter (or the Send button) sends the message.',
      'Shift+Enter in the terminal sends a newline.',
    ]
  ),
  (
    '1.12.2',
    [
      'The machines panel in landscape wide mode now opens as a slide-in overlay drawer, matching the mobile and workspaces drawer behavior.',
    ]
  ),
  (
    '1.12.1',
    [
      'Antigravity quota limits in the usage panel are now ordered with the 5-hour session window before the weekly window.',
    ]
  ),
  (
    '1.12.0',
    [
      'Terminal connection resilience: automated heartbeat pings, exponential reconnect backoff, and queuing typed messages while reconnecting.',
      'A reconnecting overlay appears when a pane connection drops, preserving the last rendered frame.',
      'Add remote SSH machines directly under any configured bridge.',
      'Fixed message bar send button layout sizing.',
    ]
  ),
  (
    '1.11.0',
    [
      'Multi-provider live quota and token tracking for Claude, Codex, Antigravity, Grok, OpenCode, Copilot, Cursor, OpenRouter, and DeepSeek.',
      'A floating top pill with Undo when closing agents, tabs, or workspaces.',
      'Held-and-lifted context menus with haptic feedback, and smooth reordering for machines and workspaces.',
      'Detailed machine connection diagnostics and clearer socket error messages.',
      'Improved background notifications with workspace context in headers and expandable multi-machine status.',
    ]
  ),
  (
    '1.10.2',
    [
      'The usage chip on the terminal\'s top bar now displays the remaining quota percentage (e.g. 54%) beside the agent logo instead of the lightning icon.',
      'The machine indicator in the terminal top bar is now a matching pill for visual consistency.',
    ]
  ),
  (
    '1.10.1',
    [
      'The usage button on the terminal\'s top bar shows the agent\'s logo beside ⚡, on a chip tinted by how much of its quota is used.',
    ]
  ),
  (
    '1.10.0',
    [
      'Swipe sideways with two fingers on the terminal (or two fingers on a laptop\'s touchpad) to go to the next or previous agent. The agents on either side peek in while you swipe; let go past the tick to switch.',
      'Copying works better: holding a finger on the text no longer brings up the keyboard and moves the text away. The keyboard opens when a quick tap lifts, the selected text holds still until you copy it, and its two handles adjust it.',
      'With the message box typed in, tapping the terminal puts the keyboard away instead of quietly typing into the terminal.',
      'Workspaces and machines have a ⋮ menu to move them up or down, and a long-press drags them. The current tab has a ⋮ menu to move or close it.',
    ]
  ),
  (
    '1.9.0',
    [
      'Alt key navigation shortcuts for hardware keyboards: Alt+Left/Right to switch tabs, Alt+1..9 to jump directly to a tab, Alt+Up/Down to switch workspaces, and Alt+O to jump to agents needing attention.',
      'Shortcut keys to trigger search (Alt+G), workspaces drawer (Alt+B), machines panel (Alt+M), and toggle message input focus (Alt+I).',
      'The bridge now binds to 0.0.0.0 by default, authenticating all incoming traffic via token for streamlined Tailscale and local access.',
    ]
  ),
  (
    '1.8.1',
    [
      'herdr-bridge\'s token is now short, like K3MF-9QXA, and can be typed in any case. A token made before still works; to get a short one, delete ~/.config/herdr-bridge/token and restart the bridge.',
    ]
  ),
  (
    '1.8.0',
    [
      'herdr-bridge now asks for a token, so nobody else on your computers or your tailnet can use it. Update the bridge, run herdr-bridge --print-token there, and enter it when editing the machine (tap it in the machines panel).',
      'The ⚡ usage sheet shows only what the agents\' own files record: today\'s tokens, prompts and model, and Codex\'s real rate limits. Claude\'s limits aren\'t on disk, so they no longer show made-up percentages.',
    ]
  ),
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
