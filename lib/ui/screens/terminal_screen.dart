import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
// ignore: implementation_imports
import 'package:xterm/src/ui/palette_builder.dart'; // the palette xterm paints with, to resolve a cell's colour
import '../../models/agent_status.dart';
import '../../models/session.dart';
import '../../services/attached_image.dart';
import '../../services/herdr_client.dart';
import '../../services/pty_channel.dart';
import '../widgets/agent_avatar.dart';
import '../widgets/keyboard_accessory_bar.dart';
import '../widgets/machines.dart';
import '../widgets/workspaces.dart';

class TerminalScreen extends StatefulWidget {
  final HerdrClientService client;

  /// Beside the agents on a wide screen, rather than a screen of its own: then it never goes back, and
  /// the home screen shows something else once its pane or machine is gone.
  final bool embedded;

  final VoidCallback? onOpenDrawer;
  final VoidCallback? onOpenMachines;
  final VoidCallback? onOpenSearch;

  const TerminalScreen({
    super.key,
    required this.client,
    this.embedded = false,
    this.onOpenDrawer,
    this.onOpenMachines,
    this.onOpenSearch,
  });

  // Unsent message box text per pane, by `machine/pane`; static, so it outlives the screen, which goes back
  // to the agent list.
  static final _drafts = <String, String>{};
  static bool hasDraft(String paneId, String machine) => _drafts['$machine/$paneId']?.isNotEmpty ?? false;
  static String? draftOf(String paneId, String machine) => _drafts['$machine/$paneId'];
  static void setDraftForTesting(String paneId, String machine, String text) => _drafts['$machine/$paneId'] = text;
  static void clearDraftsForTesting() => _drafts.clear();

  // Where each pane left was scrolled back to ([_scrolledUp], [_scrolledLines]), by `machine/pane`, with its
  // agent's `state_change_seq` at the last scroll and the 0-based screen cell scrolled ([_scrollColumn],
  // [_scrollRow]). Restored only while that seq holds: the replay lands as
  // far from the bottom as before, which shows other text once the pane has printed meanwhile.
  static final _places = <String, (int, int, int?, int?, int?)>{};

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  // OSC 52 (`52;c;<base64>`): the pane asks for text on the clipboard, as a program over ssh does. A `?`
  // payload asks to read it back, which is not answered. Over 1 MB of text (base64 is 4/3 of that) is dropped.
  final _terminal = Terminal(onPrivateOSC: (code, args) {
    if (code != '52' || args.length < 2 || args.last == '?' || args.last.length > 1400000) return;
    try {
      Clipboard.setData(ClipboardData(text: utf8.decode(base64.decode(args.last), allowMalformed: true)));
    } on FormatException {
      return; // not base64
    }
  });
  final _controller = TerminalController();
  final _view = GlobalKey<TerminalViewState>();
  final _message = TextEditingController();
  final _messageFocus = FocusNode();
  final _termFocus = FocusNode(); // the terminal's, to open the keyboard when a tap lifts ([_onTap])
  bool _tapSelected = false; // the press began with text selected, so lifting it only clears that
  int _historyIndex = -1;
  String _savedDraft = '';
  PtyChannel? _ptyChannel;
  bool _stale = false; // the pane hasn't streamed for a while: the screen is its last frame, dimmed
  bool _termBusy = false; // another client holds the pane: herdr refused the attach, retrying slowly
  bool _allFiles = false; // every file the agent sent is listed, not only the newest
  bool _takeOver = false; // steal the pane on the next attach, asked once through the banner below
  Timer? _staleTimer;
  late final AppLifecycleListener _lifecycle;
  bool _ctrl = false;
  List<String> _history = []; // sent messages, newest first, shared by every pane
  List<String> _recentCommands = []; // sent slash commands (`/models`…), newest first, for one-tap resend
  bool _showingHistory = false; // the recent-messages panel above the pill; the pill filters it
  String _historyDraft = ''; // the box's text when the panel opened, restored on close without a pick
  String? _draftKey; // the pane whose draft is in the message box
  int _scrolledUp = 0; // scrolls back into the pane's history; 0 is live
  int _scrolledLines = 0; // the lines those scrolls carried, to scroll back there after a reattach
  String? _scrolledPane; // the pane (machine/pane) they were in
  int? _scrolledSeq; // its agent's `state_change_seq` at the last scroll
  int? _scrollColumn; // 0-based screen cell under the last scroll, so herdr's wheel lands on the
  int? _scrollRow; // widget scrolled (an alternate-screen app only scrolls the widget under the wheel)
  bool _left = false; // popped back to the agents, since the machine went off

  // Pinch-to-zoom, two-finger swipes between agents, a two-finger swipe down to close the tab,
  // and history scrolling, tracked from raw pointers so they don't fight the terminal's own gestures.
  final _pointers = <int, Offset>{};
  Offset? _twoAt; // where two fingers' midpoint started, while two are down
  double _twoDistance = 0; // and how far apart they were
  bool? _swiping; // what two fingers do: null until they pinch (false) or move sideways together (true)
  double _swipeDx = 0; // how far the terminal follows a sideways swipe; past [_swipeAt] on release, it switches
  static const _swipeAt = 80.0;
  double _swipeDy = 0; // how far two fingers moved down together; past [_swipeDownAt] on release, it closes the tab
  static const _swipeDownAt = 80.0;
  bool _swipeDown = false; // two fingers heading down together, not swiping sideways nor pinching
  Offset _padPan = Offset.zero; // a touchpad's two-finger pan so far, until it picks an axis
  Axis? _padAxis;
  double _pinchFont = 0;
  Offset _downAt = Offset.zero;
  int? _downPointer; // the press that may be a tap; a right or middle click never is
  Duration _downTime = Duration.zero;
  bool _dragging = false; // set once a one-finger drag counts as a scroll
  double _scrollRest = 0; // scrolled pixels not yet a whole line
  bool _pinched = false; // the rest of a gesture that pinched never scrolls

  // The current tab in the top bar's strip, scrolled into view when it changes.
  final _tabScroll = ScrollController();
  static const _tabWidth = 168.0;
  String? _shownTabId;

  // The message bar, which an undo snackbar sits above.
  final _messageBar = GlobalKey();

  // The terminal's true background: the colour most of the screen's edges are painted, since full-screen agents
  // paint their own over the default. The message bar and the current tab take it, joining the terminal.
  // Null while it's the default: the scheme's surface, like the rest of the app.
  static const _defaultTheme = TerminalThemes.defaultTheme;
  static final _palette = PaletteBuilder(_defaultTheme).build();
  Color? _background;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _send;
    _terminal.onResize = (cols, rows, _, __) => _ptyChannel?.sendResize(cols, rows);
    _terminal.addListener(_findBackground);

    _message.addListener(_onMessageChanged);
    _messageFocus.onKeyEvent = _onMessageKeyEvent;
    // Shows the Copy button and handles while text is selected, and holds the pane still meanwhile.
    _controller.addListener(() {
      _ptyChannel?.hold = _controller.selection != null;
      setState(() {});
    });
    widget.client.addListener(_onClientUpdate);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    // The app now keeps running in the background (for alerts), so the pane is attached only while shown.
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _connectTerminal());
    _connectTerminal();
    if (widget.client.selectedPaneId case final paneId?) _swapDraft('${widget.client.machine}/$paneId');
    SharedPreferences.getInstance().then((p) {
      _history = p.getStringList('message_history') ?? [];
      _recentCommands = p.getStringList('recent_commands') ?? [];
    });
  }

  KeyEventResult _onTermKeyEvent(FocusNode node, KeyEvent event) {
    // Whether Control is down only because the desktop put it there, as Omarchy's SUPER+C does:
    // it reaches the pane as a Ctrl+C whose Control key event was synthesized, with no Control
    // key pressed. A real Ctrl+C always has its own Control keydown first.
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      _controlSynthesized = event is KeyDownEvent && event.synthesized;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed) &&
        !Platform.isAndroid &&
        !Platform.isIOS) {
      // An image goes in as its `@`-reference, text as a paste; handled here so xterm's own paste
      // doesn't ask the clipboard again ([_pasteIntoTerminal]).
      _pasteIntoTerminal();
      return KeyEventResult.handled;
    }
    // Ctrl+C copies a selection, as in VS Code's terminal. Omarchy's SUPER+C arrives as a
    // synthesized Ctrl+C, so a copy gesture must copy or do nothing, never reach the pane as an
    // interrupt. A real Ctrl+C, with a Control key of its own, still interrupts.
    final isCopyChord = event.logicalKey == LogicalKeyboardKey.keyC &&
        (event.character == '\x03' ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    if (isCopyChord) {
      if (_controller.selection != null) {
        _copySelection();
        return KeyEventResult.handled;
      }
      // Nothing selected: a copy gesture does nothing, so that it can never interrupt the pane.
      if (_controlSynthesized || HardwareKeyboard.instance.isMetaPressed) {
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final isShift = HardwareKeyboard.instance.isShiftPressed ||
          HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.shift) ||
          HardwareKeyboard.instance.isPhysicalKeyPressed(PhysicalKeyboardKey.shiftLeft) ||
          HardwareKeyboard.instance.isPhysicalKeyPressed(PhysicalKeyboardKey.shiftRight);
      if (isShift) {
        if (event is KeyDownEvent) {
          _send('\n');
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // Set by the Control key events above: true when Control is down because the desktop
  // synthesized it, as Omarchy's universal copy does, rather than because a key was pressed.
  bool _controlSynthesized = false;

  KeyEventResult _onMessageKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      if (isCtrl) {
        if (event is KeyDownEvent && !_showingHistory) {
          _sendMessage();
        }
        return KeyEventResult.handled;
      }
      // Enter sends when that mode is picked, with Shift+Enter for a new line; otherwise Enter
      // (with or without Shift) inserts a new line and Ctrl+Enter sends.
      if (widget.client.enterBehavior == EnterBehavior.send && !isShift) {
        if (event is KeyDownEvent && !_showingHistory) {
          _sendMessage();
        }
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent) {
        final text = _message.text;
        final sel = _message.selection;
        final start = sel.start >= 0 ? sel.start : text.length;
        final end = sel.end >= 0 ? sel.end : text.length;
        final newText = text.replaceRange(start, end, '\n');
        _message.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + 1),
        );
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyV) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
      // A pasted clipboard image attaches instead; text stays the field's own paste, which runs
      // alongside (see [_pasteClipboardImage]). Desktop only: on phones images come through the
      // attach button, whose picker reads them.
      if (isCtrl && !Platform.isAndroid && !Platform.isIOS) _pasteClipboardImage();
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      // While the history panel is open the pill is a search query: leave the arrows to the field.
      if (_showingHistory) return KeyEventResult.ignored;
      if (_history.isNotEmpty) {
        if (_historyIndex == -1) _savedDraft = _message.text;
        if (_historyIndex + 1 < _history.length) {
          setState(() {
            _historyIndex++;
            final text = _history[_historyIndex];
            _message.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            );
          });
          return KeyEventResult.handled;
        }
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_showingHistory) return KeyEventResult.ignored;
      if (_historyIndex > 0) {
        setState(() {
          _historyIndex--;
          final text = _history[_historyIndex];
          _message.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        });
        return KeyEventResult.handled;
      } else if (_historyIndex == 0) {
        setState(() {
          _historyIndex = -1;
          _message.value = TextEditingValue(
            text: _savedDraft,
            selection: TextSelection.collapsed(offset: _savedDraft.length),
          );
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _onMessageChanged() {
    if (_historyIndex != -1 && (_historyIndex >= _history.length || _message.text != _history[_historyIndex])) {
      _historyIndex = -1;
    }
    if (_showingHistory) return; // the pill is a search query, not a draft, while the panel is open
    if (_draftKey != null) {
      if (_message.text.isNotEmpty) {
        TerminalScreen._drafts[_draftKey!] = _message.text;
      } else {
        TerminalScreen._drafts.remove(_draftKey);
      }
    }
  }

  /// Alt keybindings, volume keys, and Ctrl +/- zoom handling while this screen is active.
  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    final client = widget.client;
    final isAlt = HardwareKeyboard.instance.isAltPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isCtrl = HardwareKeyboard.instance.isControlPressed;

    if (isAlt && !isCtrl) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (event is! KeyUpEvent) {
          if (isShift) {
            client.moveTabPrevious();
          } else {
            client.previousTab();
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        if (event is! KeyUpEvent) {
          if (isShift) {
            client.moveTabNext();
          } else {
            client.nextTab();
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        if (event is! KeyUpEvent) client.stepAgent(-1);
        return true;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        if (event is! KeyUpEvent) client.stepAgent(1);
        return true;
      }
      if (key == LogicalKeyboardKey.escape) {
        if (event is! KeyUpEvent) {
          final pane = client.selectedPane;
          if (pane != null) {
            final m = client.machine;
            closeWithUndo(context, client, client.snapshot?.agentOf(pane.id) != null ? 'Agent closed' : 'Pane closed',
                ['$m/${pane.id}'], () => client.closePane(pane.id, m), above: _messageBar);
            if (!widget.embedded && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyT) {
        if (event is! KeyUpEvent) {
          final wsId = client.selectedPane?.workspaceId ?? client.snapshot?.workspaces.firstOrNull?.id;
          if (wsId != null) client.createTab(wsId);
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyG) {
        if (event is! KeyUpEvent) {
          if (widget.onOpenSearch != null) {
            widget.onOpenSearch!();
          } else if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context, 'search');
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyO) {
        if (event is! KeyUpEvent) client.jumpToAttention();
        return true;
      }
      if (key == LogicalKeyboardKey.keyB) {
        if (event is! KeyUpEvent) {
          if (widget.onOpenDrawer != null) {
            widget.onOpenDrawer!();
          } else if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context, 'drawer');
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyM) {
        if (event is! KeyUpEvent) {
          if (widget.onOpenMachines != null) {
            widget.onOpenMachines!();
          } else if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context, 'machines');
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyH) {
        if (event is! KeyUpEvent) {
          if (!widget.embedded && Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        }
        return true;
      }
      if (key == LogicalKeyboardKey.keyI) {
        if (event is! KeyUpEvent) {
          if (_messageFocus.hasFocus) {
            _messageFocus.unfocus();
          } else {
            _messageFocus.requestFocus();
          }
        }
        return true;
      }

      final digit = switch (key) {
        LogicalKeyboardKey.digit1 || LogicalKeyboardKey.numpad1 => 1,
        LogicalKeyboardKey.digit2 || LogicalKeyboardKey.numpad2 => 2,
        LogicalKeyboardKey.digit3 || LogicalKeyboardKey.numpad3 => 3,
        LogicalKeyboardKey.digit4 || LogicalKeyboardKey.numpad4 => 4,
        LogicalKeyboardKey.digit5 || LogicalKeyboardKey.numpad5 => 5,
        LogicalKeyboardKey.digit6 || LogicalKeyboardKey.numpad6 => 6,
        LogicalKeyboardKey.digit7 || LogicalKeyboardKey.numpad7 => 7,
        LogicalKeyboardKey.digit8 || LogicalKeyboardKey.numpad8 => 8,
        LogicalKeyboardKey.digit9 || LogicalKeyboardKey.numpad9 => 9,
        _ => null,
      };
      if (digit != null && !isShift) {
        if (event is! KeyUpEvent) client.selectTabAt(digit - 1);
        return true;
      }
    }

    if (isCtrl) {
      final isZoomIn =
          key == LogicalKeyboardKey.equal || key == LogicalKeyboardKey.add || key == LogicalKeyboardKey.numpadAdd;
      final isZoomOut = key == LogicalKeyboardKey.minus || key == LogicalKeyboardKey.numpadSubtract;
      final isZoomReset = key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0;

      if (isZoomIn || isZoomOut || isZoomReset) {
        if (event is! KeyUpEvent) {
          if (isZoomIn) {
            client.setFontSize(client.fontSize + 1);
          } else if (isZoomOut) {
            client.setFontSize(client.fontSize - 1);
          } else if (isZoomReset) {
            client.setFontSize(HerdrClientService.defaultFontSize);
          }
        }
        return true;
      }
    }

    if (key != LogicalKeyboardKey.audioVolumeUp && key != LogicalKeyboardKey.audioVolumeDown) return false;
    if (client.volumeKeys == VolumeKeys.volume || !Platform.isAndroid) return false;
    if (event is! KeyUpEvent) {
      final up = key == LogicalKeyboardKey.audioVolumeUp;
      if (client.volumeKeys == VolumeKeys.arrows) {
        _key(up ? TerminalKey.arrowUp : TerminalKey.arrowDown);
      } else {
        client.setFontSize(client.fontSize + (up ? 1 : -1));
      }
    }
    return true;
  }

  /// Everything typed or tapped reaches the pane here, with an armed CTRL applied once. Typing while
  /// scrolled back returns to the live screen first, so you see what you type.
  void _send(String data) {
    _toLive();
    if (_ctrl) {
      final c = data.length == 1 ? data.codeUnitAt(0) : -1;
      if (c == 0x20 || (c >= 0x40 && c < 0x7f)) data = String.fromCharCode(c & 0x1f);
      setState(() => _ctrl = false);
    }
    _ptyChannel?.sendInput(data);
  }

  /// Special keys go through xterm so they follow the pane's cursor-key mode.
  void _key(TerminalKey key, {bool shift = false}) {
    final ctrl = _ctrl;
    _toLive();
    setState(() => _ctrl = false);
    _terminal.keyInput(key, shift: shift, ctrl: ctrl);
  }

  /// Sends the message box as one paste (so multi-line text doesn't submit line by line), then Enter.
  /// An empty box just sends Enter. A [command] is sent in its place, leaving the box and history be.
  void _sendMessage([String? command]) {
    final text = command ?? _message.text;
    if (_ptyChannel == null || !widget.client.connected) return;
    // The pill is a search query while the history panel is open: only one-tap resends go out.
    if (_showingHistory && command == null) return;
    if (_showingHistory) _closeHistory();
    _toLive();
    final channel = _ptyChannel;
    if (text.isEmpty) {
      channel?.sendInput('\r');
    } else {
      channel?.sendInput('\x1b[200~$text\x1b[201~');
      // An Enter in the same read as the paste is taken as part of it (Claude Code), so send it apart.
      // Dropped if the pane was switched meanwhile: its channel is closed.
      Future.delayed(const Duration(milliseconds: 150), () {
        if (_ptyChannel == channel) channel?.sendInput('\r');
      });
    }
    _historyIndex = -1;
    _savedDraft = '';
    final trimmed = text.trim();
    if (trimmed.startsWith('/')) _rememberCommand(trimmed);
    if (command != null) return;
    _message.clear();
    if (trimmed.isEmpty) return;
    _history = [text, ..._history.where((h) => h != text)].take(30).toList();
    SharedPreferences.getInstance().then((p) => p.setStringList('message_history', _history));
  }

  /// Keeps the latest sent slash commands (`/models`…) for one-tap resend, newest first.
  void _rememberCommand(String text) {
    _recentCommands = [text, ..._recentCommands.where((c) => c != text)].take(8).toList();
    SharedPreferences.getInstance().then((p) => p.setStringList('recent_commands', _recentCommands));
  }

  /// Picks an image and uploads it as an `@`-reference for the box ([_uploadImage]).
  Future<void> _attachImage() async {
    if (_uploadingImage) return;
    const images = XTypeGroup(label: 'images', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp']);
    late final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: [images]);
    } catch (e) {
      return _imageError('Could not open the file picker ($e).');
    }
    if (file == null || !mounted) return; // picked nothing
    late final Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      return _imageError('Could not read that image ($e).');
    }
    await _uploadImage(bytes, failure: 'Could not attach that image');
  }

  void _imageError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _uploadingImage = false; // an upload in flight: the attach button shows it, another waits

  /// Uploads [bytes] to the active machine's bridge ([HerdrClientService.uploadImage]) and puts the
  /// `@`-reference it answers in the box, or types it into the pane's own prompt when [intoTerminal]:
  /// nothing binary ever reaches a pane, the agent opens the file. [failure] starts the error shown.
  Future<void> _uploadImage(Uint8List bytes, {required String failure, bool intoTerminal = false}) async {
    if (_uploadingImage) return;
    setState(() => _uploadingImage = true);
    try {
      final (image, mime) = AttachedImage.uploadable(bytes);
      final path = await widget.client.uploadImage(image, mime);
      if (path == null || !mounted) return; // reported through onError
      if (intoTerminal) {
        _pasteFromClipboard('@$path ');
        return;
      }
      final cur = _message.text;
      final next = cur.isEmpty ? '@$path ' : '${cur.endsWith(' ') ? cur : '$cur '}@$path ';
      _message.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: next.length));
    } catch (e) {
      _imageError('$failure ($e).');
    } finally {
      if (mounted) setState(() => _uploadingImage = false);
    }
  }

  /// Pastes an image from the clipboard into the box as an `@`-reference ([_uploadImage]); text is
  /// left to the field's own paste, so the two never double-insert. The clipboard tools' types are
  /// read first, and [Clipboard.getData] is not asked at all: an image has no text to find, and that
  /// ask is a round trip through the desktop's clipboard to whoever owns it.
  void _pasteClipboardImage() {
    if (_uploadingImage || !widget.client.connected) return;
    () async {
      try {
        final bytes = await AttachedImage.readClipboardImage();
        if (bytes == null || !mounted) return; // text (or nothing): the field pastes it
        await _uploadImage(bytes, failure: 'Could not paste that image');
      } catch (e) {
        _imageError('Could not paste that image ($e).');
      }
    }();
  }

  /// Ctrl+V in the terminal: an image on the clipboard goes in as its `@`-reference, anything else as
  /// text. The key is handled here so it never reaches xterm's own paste, which would ask the
  /// clipboard for text a second time.
  void _pasteIntoTerminal() {
    if (!widget.client.connected) return;
    () async {
      try {
        final bytes = await AttachedImage.readClipboardImage();
        if (!mounted) return;
        if (bytes != null) return await _uploadImage(bytes, failure: 'Could not paste that image', intoTerminal: true);
        _pasteFromClipboard((await Clipboard.getData(Clipboard.kTextPlain))?.text);
      } catch (e) {
        _imageError('Could not paste that image ($e).');
      }
    }();
  }

  /// Recent messages live in a panel above the pill, which stays on screen as its search box:
  /// typing filters the list, a message goes back in the box to edit or send, and a slash command
  /// sends at once. Closing without a pick brings back the box's text from before the search.
  void _toggleHistory() {
    if (_showingHistory) {
      _closeHistory();
      return;
    }
    setState(() {
      _historyDraft = _message.text;
      _historyIndex = -1;
      _showingHistory = true;
      // The pill becomes a search box: start with an empty query over the full
      // history. The pre-search text is parked in [_historyDraft], not saved as
      // a draft (see [_onMessageChanged]), and comes back on close.
      _message.value = const TextEditingValue(text: '');
    });
    _messageFocus.requestFocus();
  }

  void _closeHistory() {
    setState(() {
      _showingHistory = false;
      _message.value = TextEditingValue(
        text: _historyDraft,
        selection: TextSelection.collapsed(offset: _historyDraft.length),
      );
      _historyDraft = '';
    });
  }

  void _pickHistory(String text) {
    setState(() {
      _showingHistory = false;
      _historyDraft = '';
      _historyIndex = -1;
      _message.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    });
    _messageFocus.requestFocus();
  }

  List<String> _filterHistory(List<String> items, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items.where((h) => h.toLowerCase().contains(q)).toList();
  }

  /// How much of a quota is [used], as a colour from the status palette: done's green while there's plenty,
  /// draft peach from 75%, needs-you red from 90%; grey when nothing is recorded, so that never looks fine.
  static Color _quotaColor(ColorScheme scheme, double? used) => switch (used) {
        null => scheme.onSurfaceVariant,
        >= 0.90 => AgentStatus.blocked.color,
        >= 0.75 => AgentStatus.draftColor,
        _ => AgentStatus.done.color,
      };

  static String _formatResetTime(String raw) {
    try {
      final parsed = DateTime.parse(raw).toLocal();
      final diff = parsed.difference(DateTime.now());
      if (diff.isNegative) return 'shortly';
      if (diff.inHours >= 24) {
        final days = diff.inDays;
        final h = diff.inHours % 24;
        return 'in ${days}d ${h}h';
      }
      if (diff.inHours > 0) {
        final m = diff.inMinutes % 60;
        return m > 0 ? 'in ${diff.inHours}h ${m}m' : 'in ${diff.inHours}h';
      }
      if (diff.inMinutes > 0) {
        return 'in ${diff.inMinutes}m';
      }
      return 'in < 1m';
    } catch (_) {
      return raw;
    }
  }

  static String _formatTokens(int count) {
    if (count >= 1000000000) return '${(count / 1000000000).toStringAsFixed(1)}B';
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '$count';
  }

  void _showUsage(AgentModel? agent, AgentUsage? usage) {
    _messageFocus.unfocus();
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      // Sized to its content: the default caps a sheet at 9/16 of the screen, which cuts an agent with several
      // limits (Antigravity's Gemini + Claude/GPT tiers) off at its edge, its last card flush against it with no hint there's more.
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final title = agent?.name.isNotEmpty == true ? agent!.name : 'Agent';
        final tier = usage?.tierLabel;
        // Primary (Gemini) quotas first; secondary tiers (Claude/GPT sharing
        // the Antigravity plan) after, still visible but out of the headline.
        final limits = [...(usage?.limits ?? [])]
          ..sort((a, b) => (a.isPrimary ? 0 : 1).compareTo(b.isPrimary ? 0 : 1));

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AgentAvatar(name: agent?.name ?? '', radius: 14),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                          if (tier != null && tier.isNotEmpty)
                            Text(tier, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (limits.isNotEmpty) ...[
                  for (var i = 0; i < limits.length; i++) ...[
                    if (i > 0 && !limits[i].isPrimary && limits[i - 1].isPrimary)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Other models',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    Builder(builder: (context) {
                      final limit = limits[i];
                      final leftPct = ((1.0 - limit.percent).clamp(0.0, 1.0) * 100).round();
                      final usedPct = (limit.percent.clamp(0.0, 1.0) * 100).round();
                      final statusColor = _quotaColor(scheme, limit.percent);
                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  limit.label,
                                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  '$leftPct% left',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: limit.percent.clamp(0.0, 1.0),
                                minHeight: 8,
                                backgroundColor: scheme.surfaceContainerHighest,
                                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$usedPct% used',
                                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                ),
                                if (limit.resetsAt != null && limit.resetsAt!.isNotEmpty)
                                  Text(
                                    'Resets ${_formatResetTime(limit.resetsAt!)}',
                                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ] else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No active rate limits recorded for this agent.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (usage?.todayTokens != null || usage?.todayPrompts != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        if (usage?.todayTokens case final tokens?)
                          Column(
                            children: [
                              Text(_formatTokens(tokens),
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                              Text('Tokens today',
                                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ],
                          ),
                        if (usage?.todayPrompts case final prompts?)
                          Column(
                            children: [
                              Text('$prompts',
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                              Text('Prompts today',
                                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Takes the background most of the screen's edge cells have as [_background]: the top and bottom rows
  /// and the outer columns, which meet the tab strip and the message bar. What's drawn in the middle (a
  /// diff, a selection) doesn't sway it. The default counts as the theme's.
  void _findBackground() {
    final counts = <int, int>{};
    final buffer = _terminal.buffer;
    final first = buffer.height - buffer.viewHeight;
    // Runs on every frame the pane sends, so it visits only those cells.
    for (var y = first; y < buffer.height; y++) {
      final line = buffer.lines[y];
      final edgeRow = y == first || y == buffer.height - 1;
      final last = line.length - 1;
      for (var x = 0; x <= last; x = edgeRow || x == last ? x + 1 : last) {
        final bg = line.getBackground(x);
        counts[bg] = (counts[bg] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return;
    final top = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final background = switch (top & CellColor.typeMask) {
      CellColor.normal => null,
      CellColor.rgb => Color(top & CellColor.valueMask | 0xFF000000),
      _ => _palette[top & CellColor.valueMask],
    };
    if (background != _background) setState(() => _background = background);
  }

  /// Back to the bottom of the pane's history. Herdr's own scrollback takes a scroll's line count, so
  /// one scroll long enough reaches the bottom (herdr caps it at a u16); an app on the alternate screen
  /// (Claude Code) gets each scroll as one wheel tick whatever its count, so it needs as many ticks back
  /// as went up. Send twice that: going past the bottom does nothing, falling short leaves the view up.
  /// Input goes through here, so it also lets go of a selection, whose hold would hide what the input does.
  void _toLive() {
    if (_controller.selection != null) _controller.clearSelection();
    if (_scrolledUp == 0) return;
    for (var i = 0; i < 2 * _scrolledUp; i++) {
      _ptyChannel?.sendScroll(-65535, column: _scrollColumn, row: _scrollRow);
    }
    setState(() => _scrolledUp = _scrolledLines = 0);
  }

  /// The agent running in a tab (focused pane's first), or null if it runs none.
  AgentModel? _tabAgent(TabModel tab) {
    final snapshot = widget.client.snapshot;
    if (snapshot == null) return null;
    final panes = snapshot.panes.where((p) => p.tabId == tab.id).toList();
    final focusedPane = panes.where((p) => p.focused).firstOrNull ?? panes.firstOrNull;
    if (focusedPane != null) {
      final agent = snapshot.agents.where((a) => a.paneId == focusedPane.id).firstOrNull;
      if (agent != null) return agent;
    }
    final paneIds = {for (final p in panes) p.id};
    return snapshot.agents.where((a) => paneIds.contains(a.paneId)).firstOrNull;
  }

  /// A concise summary of what's happening in [tab]: the terminal title of its focused pane,
  /// or the running agent's name, falling back to the tab's display name.
  String _tabSummary(TabModel tab) {
    final snapshot = widget.client.snapshot;
    if (snapshot == null) return tab.displayName;
    final panes = snapshot.panes.where((p) => p.tabId == tab.id).toList();
    final pane = panes.where((p) => p.focused).firstOrNull ?? panes.firstOrNull;
    if (pane != null && pane.terminalTitle.isNotEmpty) {
      return pane.terminalTitle;
    }
    final agent = _tabAgent(tab);
    if (agent != null && agent.name.isNotEmpty) {
      return agent.name;
    }
    return tab.displayName;
  }

  /// A tab's menu, from a hold or a right-click ([HoldMenu]): open it (or clear it, when it is), move it, or close it.
  Future<void> _showTabMenu(Offset at, TabModel tab, List<TabModel> tabs, int index) async {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (tab.id != client.selectedPane?.tabId)
          const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.tab), title: Text('Open tab')))
        else
          const PopupMenuItem(
              value: 'clear', child: ListTile(leading: Icon(Icons.cleaning_services_outlined), title: Text('Clear'))),
        if (index > 0)
          const PopupMenuItem(
              value: 'left', child: ListTile(leading: Icon(Icons.arrow_back), title: Text('Move left'))),
        if (index < tabs.length - 1)
          const PopupMenuItem(
              value: 'right', child: ListTile(leading: Icon(Icons.arrow_forward), title: Text('Move right'))),
        PopupMenuItem(
          value: 'close',
          child: ListTile(
            leading: Icon(Icons.close, color: scheme.error),
            title: Text('Close tab', style: TextStyle(color: scheme.error)),
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'open':
        client.selectTab(tab.id);
      case 'clear':
        // The history scrolled back into goes, so the screen is live again.
        _toLive();
        client.clearPane(client.selectedPaneId!);
      case 'left':
        if (index > 0) client.moveTab(tab.id, tabs[index - 1].id);
      case 'right':
        if (index < tabs.length - 1) client.moveTab(tab.id, tabs[index + 1].id);
      case 'close':
        final m = client.machine;
        closeWithUndo(context, client, 'Tab closed', ['$m/${tab.id}'], () => client.closeTab(tab.id, m),
            above: _messageBar);
    }
  }

  /// The workspace's tabs, and the current one's index in them.
  (List<TabModel>, int)? _tabs() {
    final snapshot = widget.client.snapshot;
    final pane = widget.client.selectedPane;
    if (pane == null) return null;
    final tabs = snapshot!.tabs.where((t) => t.workspaceId == pane.workspaceId).toList();
    return (tabs, tabs.indexWhere((t) => t.id == pane.tabId));
  }

  void _copySelection() {
    // herdr repaints every cell, blanks included, so each row ends in spaces up to the terminal's width.
    // And agents wrap their own text into rows, continued indented, so a row is joined to the next when
    // that one is indented, isn't a list item, and its first word wouldn't have fit on this row.
    final selection = _controller.selection!.normalized;
    final lines = _terminal.buffer.lines;
    final text = StringBuffer();
    var joined = false;
    for (final segment in selection.toSegments()) {
      final row = segment.line;
      if (row < 0 || row >= lines.length) continue;
      final part = lines[row].getText(segment.start, segment.end).trimRight();
      text.write(joined ? part.trimLeft() : part);
      if (row == selection.end.y || row + 1 >= lines.length) break;
      final line = lines[row].getText().trimRight();
      final next = RegExp(r'^( +)(?![-*•] |\d+[.)] )(\S+)').firstMatch(lines[row + 1].getText());
      joined = line.trim().isNotEmpty &&
          next != null &&
          next[1]!.length >= line.length - line.trimLeft().length &&
          line.length + 1 + next[2]!.length >= _terminal.viewWidth;
      text.write(joined ? ' ' : '\n');
    }
    Clipboard.setData(ClipboardData(text: text.toString()));
    _controller.clearSelection();
  }

  /// Where a selection handle points, in the terminal's box: under the selection's first cell, or after its
  /// last ([begin] false).
  Offset? _handleAt(bool begin) {
    final selection = _controller.selection?.normalized;
    final render = _view.currentState?.renderTerminal;
    if (selection == null || render == null || !render.hasSize) return null;
    final at = render.getOffset(begin ? selection.begin : selection.end);
    return Offset(at.dx + (widget.embedded ? 4 : 0), at.dy + render.lineHeight);
  }

  /// Moves the selection's first cell, or its last, to under the finger dragging its handle at [global].
  void _dragHandle(bool begin, Offset global) {
    final selection = _controller.selection?.normalized;
    final render = _view.currentState?.renderTerminal;
    if (selection == null || render == null) return;
    // The finger holds the handle's drop, beside and below the point it moves; that point is the line's bottom.
    final cell = render.getCellOffset(render.globalToLocal(global) + Offset(begin ? 10 : -10, -10 - render.lineHeight / 2));
    final buffer = _terminal.buffer;
    _controller.setSelection(buffer.createAnchorFromOffset(begin ? selection.end : selection.begin),
        buffer.createAnchorFromOffset(cell));
  }

  /// Where the Copy button sits: just above the selection, or below it when that's off the top.
  double? _copyTop() {
    final selection = _controller.selection?.normalized;
    final render = _view.currentState?.renderTerminal;
    if (selection == null || render == null || !render.hasSize) return null;
    final above = render.getOffset(selection.begin).dy - 48;
    return above >= 0 ? above : render.getOffset(selection.end).dy + render.lineHeight + 8;
  }

  /// Right/middle mouse buttons never start pinch-zoom or history scrolling: they are
  /// for selection and the context menu. Up/cancel still clears the tracked pointer.
  bool _isMouseSecondary(PointerEvent e) =>
      e.kind == PointerDeviceKind.mouse &&
      e is! PointerUpEvent &&
      e is! PointerCancelEvent &&
      (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton)) != 0;

  /// Desktop context menu: copy the selection, paste the clipboard, select all.
  /// Right-click never clears the selection, unlike a left tap.
  Future<void> _showTerminalMenu(TapDownDetails details) async {
    final hasSelection = _controller.selection != null;
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    final canPaste = (clipboard?.text?.isNotEmpty ?? false) && _ptyChannel != null && widget.client.connected;
    if (!mounted) return;
    final at = details.globalPosition;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (hasSelection)
          const PopupMenuItem(value: 'copy', child: ListTile(leading: Icon(Icons.content_copy), title: Text('Copy'))),
        if (canPaste)
          const PopupMenuItem(
              value: 'paste', child: ListTile(leading: Icon(Icons.content_paste), title: Text('Paste'))),
        const PopupMenuItem(
            value: 'selectAll', child: ListTile(leading: Icon(Icons.select_all), title: Text('Select all'))),
        if (hasSelection)
          const PopupMenuItem(
              value: 'clear', child: ListTile(leading: Icon(Icons.clear), title: Text('Clear selection'))),
      ],
    );
    switch (picked) {
      case 'copy':
        _copySelection();
      case 'paste':
        _pasteFromClipboard(clipboard?.text);
      case 'selectAll':
        _selectAll();
      case 'clear':
        _controller.clearSelection();
    }
  }

  /// Pastes clipboard text as one bracketed paste (like the message box), then Enter is left to the user.
  /// Always bracketed: herdr's frames never carry the pane's `?2004h`, so our terminal can't know the
  /// mode, while herdr drops the markers itself for a pane that didn't ask for them.
  void _pasteFromClipboard(String? text) {
    if (text == null || text.isEmpty) return;
    if (_controller.selection != null) _controller.clearSelection(); // as xterm's own paste does
    _send('\x1b[200~$text\x1b[201~');
  }

  /// Selects the visible screen, like xterm's own Select-all action.
  void _selectAll() {
    final buffer = _terminal.buffer;
    final top = buffer.height - _terminal.viewHeight;
    _controller.setSelection(
      buffer.createAnchor(0, top < 0 ? 0 : top),
      buffer.createAnchor(_terminal.viewWidth, buffer.height - 1),
    );
    setState(() {});
  }

  void _trackPointer(PointerEvent e) {
    if (_isMouseSecondary(e)) return;
    if (e is PointerUpEvent || e is PointerCancelEvent) {
      _pointers.remove(e.pointer);
    } else {
      _pointers[e.pointer] = e.position;
    }
    if (e is PointerDownEvent && _pointers.length == 1) {
      _downAt = e.position;
      _downTime = e.timeStamp;
      _dragging = false;
      _pinched = false;
      _tapSelected = _controller.selection != null;
      _downPointer = e.pointer;
    }
    if (e.kind == PointerDeviceKind.touch) _gateKeyboard(e);
    // A press that has made a selection by the time it lifts was a long-press, not a tap.
    if (e is PointerUpEvent &&
        e.pointer == _downPointer &&
        _controller.selection == null &&
        _pointers.isEmpty &&
        !_dragging &&
        !_pinched &&
        e.timeStamp - _downTime < kLongPressTimeout &&
        (e.position - _downAt).distance < kTouchSlop) {
      return _onTap(e);
    }
    if (e is PointerMoveEvent && _pointers.length == 1 && !_pinched) return _scroll(e);
    if (_pointers.length != 2) {
      if (_twoAt != null) _endSwipe();
      _twoAt = null;
      return;
    }
    _pinched = true; // the rest of the gesture never scrolls
    final p = _pointers.values.toList();
    final distance = (p[0] - p[1]).distance;
    final centre = (p[0] + p[1]) / 2;
    if (_twoAt == null) {
      _twoAt = centre;
      _twoDistance = distance;
      _pinchFont = widget.client.fontSize;
      _swiping = null;
      _swipeDown = false;
      _swipeDy = 0;
      return;
    }
    // Fingers moving sideways together swipe; moving apart or together pinch; moving down together
    // close the tab on release; whichever shows first wins.
    final dx = centre.dx - _twoAt!.dx;
    final dy = centre.dy - _twoAt!.dy;
    final stretch = distance - _twoDistance;
    if (!_swipeDown) {
      _swiping ??= dx.abs() > kPanSlop && dx.abs() > stretch.abs()
          ? true
          : stretch.abs() > kPanSlop && widget.client.pinchZoom
              ? false
              : null;
    }
    if (!_swipeDown && _swiping == null && dy > kPanSlop && dy > dx.abs() && dy > stretch.abs()) {
      _swipeDown = true;
    }
    if (_swiping == false) widget.client.setFontSize((_pinchFont * distance / _twoDistance).roundToDouble());
    if (_swiping == true) _swipe(dx);
    if (_swipeDown) {
      if ((dy >= _swipeDownAt) != (_swipeDy >= _swipeDownAt)) HapticFeedback.selectionClick();
      _swipeDy = dy;
    }
  }

  /// Where a swipe [step] agents along leads, named as the list does: the agent's summary, then where it is.
  String? _peek(int step) {
    final client = widget.client;
    final (m, paneId) = client.agentAt(step) ?? ('', '');
    final snapshot = client.snapshotOf(m);
    final pane = snapshot?.panes.where((p) => p.id == paneId).firstOrNull;
    if (pane == null) return null;
    final agent = snapshot!.agents.where((a) => a.paneId == paneId).firstOrNull;
    final place = [snapshot.placeOf(pane), if (m != client.machine) client.nameOf(m)].join(' · ');
    return '${pane.terminalTitle.isNotEmpty ? pane.terminalTitle : agent?.name ?? ''}\n$place';
  }

  /// The soft keyboard never opens on a tap: typing is what the control keys are for, and opening it
  /// would shrink the pane and make herdr redraw it under the tap. It opens only from the keyboard button
  /// beside the keys. xterm would still open it on tap-down, before it knows a long-press or a scroll, so
  /// this holds it off by `canRequestFocus` on the terminal's focus node, and never puts it back: only the
  /// keyboard button does. A keyboard already up stays up.
  void _gateKeyboard(PointerEvent e) {
    if (e is PointerDownEvent && _pointers.length == 1) {
      // Unless its keyboard is up already. Focused with it put away (e.g. by back), xterm would bring it back on
      // tap-down too, so this unfocuses it.
      if (!_termFocus.hasFocus || MediaQuery.viewInsetsOf(context).bottom == 0) _termFocus.canRequestFocus = false;
    }
  }

  /// A tap (or a left click) is a click for the pane's program, which herdr drops unless it asked for the mouse.
  /// A tap that clears a selection does only that. xterm selects a word on a double-tap, which isn't wanted
  /// here, so its second tap clears that once the gesture arena has run (which is after this, at the lift).
  void _onTap(PointerUpEvent e) {
    if (_tapSelected) return;
    scheduleMicrotask(() {
      if (mounted && _controller.selection != null) _controller.clearSelection();
    });
    final render = _view.currentState?.renderTerminal;
    if (render == null) return;
    final cell = render.getCellOffset(render.globalToLocal(e.position));
    if (_urlAt(cell.x, cell.y) case final url?) {
      widget.client.openUrl(url);
      return;
    }
    // xterm counts rows from the buffer's top; herdr, from the screen's.
    final top = _terminal.buffer.height - _terminal.viewHeight;
    _ptyChannel?.sendClick(cell.x, (cell.y - top).clamp(0, _terminal.viewHeight - 1));
  }

  /// The https URL under the cell at ([col], [row]), if any, joining wrapped terminal lines.
  String? _urlAt(int col, int row) {
    final lines = _terminal.buffer.lines;
    if (row < 0 || row >= lines.length || col < 0 || col >= _terminal.viewWidth) return null;
    final line = lines[row].getText();
    if (col >= line.length || line[col] == ' ') return null;

    var startCol = col;
    while (startCol > 0 && line[startCol - 1] != ' ') startCol--;
    var endCol = col;
    while (endCol + 1 < line.length && line[endCol + 1] != ' ') endCol++;

    var curRow = row;
    var curStartCol = startCol;
    final chunks = <String>[line.substring(startCol, endCol + 1)];
    var tapOffset = col - startCol;

    while (curStartCol == 0 && curRow > 0) {
      final prevLine = lines[curRow - 1].getText().trimRight();
      if (prevLine.length >= _terminal.viewWidth && prevLine.isNotEmpty && prevLine[prevLine.length - 1] != ' ') {
        var prevTailStart = prevLine.length - 1;
        while (prevTailStart > 0 && prevLine[prevTailStart - 1] != ' ') prevTailStart--;
        final prevChunk = prevLine.substring(prevTailStart);
        chunks.insert(0, prevChunk);
        tapOffset += prevChunk.length;
        curStartCol = prevTailStart;
        curRow--;
      } else {
        break;
      }
    }

    curRow = row;
    var curEndCol = endCol;
    while (curEndCol >= _terminal.viewWidth - 1 && curRow + 1 < lines.length) {
      final nextLine = lines[curRow + 1].getText();
      if (nextLine.isNotEmpty && nextLine[0] != ' ') {
        var nextHeadEnd = 0;
        while (nextHeadEnd + 1 < nextLine.length && nextLine[nextHeadEnd + 1] != ' ') nextHeadEnd++;
        final nextChunk = nextLine.substring(0, nextHeadEnd + 1);
        chunks.add(nextChunk);
        curEndCol = nextHeadEnd;
        curRow++;
      } else {
        break;
      }
    }

    final candidate = chunks.join('');
    final matches = RegExp(r"https://[^\s<>'`]+", caseSensitive: false).allMatches(candidate);
    for (final m in matches) {
      if (tapOffset >= m.start && tapOffset < m.end) {
        var url = m.group(0)!.replaceAll(RegExp(r'''[.,;:!?'"]+$'''), '');
        while (url.endsWith(')') || url.endsWith(']')) {
          final openParen = '('.allMatches(url).length;
          final closeParen = ')'.allMatches(url).length;
          if (closeParen > openParen && url.endsWith(')')) {
            url = url.substring(0, url.length - 1);
            continue;
          }
          final openBracket = '['.allMatches(url).length;
          final closeBracket = ']'.allMatches(url).length;
          if (closeBracket > openBracket && url.endsWith(']')) {
            url = url.substring(0, url.length - 1);
            continue;
          }
          break;
        }
        url = url.replaceAll(RegExp(r'''[.,;:!?'"]+$'''), '');
        final uri = Uri.tryParse(url);
        if (uri != null && uri.scheme.toLowerCase() == 'https' && uri.hasAuthority) {
          return url;
        }
      }
    }
    return null;
  }

  /// Opens the soft keyboard into the terminal, from the keyboard button beside the control keys.
  void _openKeyboard() {
    _termFocus.canRequestFocus = true;
    _view.currentState?.requestKeyboard();
  }

  /// Two fingers have moved [dx] sideways together: the terminal follows them, with a tick as they pass the
  /// point where letting go switches agent ([_endSwipe]).
  void _swipe(double dx) {
    if ((dx.abs() >= _swipeAt) != (_swipeDx.abs() >= _swipeAt)) HapticFeedback.selectionClick();
    setState(() => _swipeDx = dx);
  }

  /// Fingers lifted: past [_swipeAt], the next agent (fingers gone left, as a page turns) or the previous
  /// ([stepAgent]); either way the terminal springs back into place. Two fingers swiped down together
  /// past [_swipeDownAt] close the current tab instead ([_closeTabByGesture]).
  void _endSwipe() {
    if (_swipeDx.abs() >= _swipeAt) widget.client.stepAgent(_swipeDx < 0 ? 1 : -1);
    if (_swipeDx != 0) setState(() => _swipeDx = 0);
    if (_swipeDown && _swipeDy >= _swipeDownAt) _closeTabByGesture();
    _swipeDown = false;
    _swipeDy = 0;
  }

  /// Two fingers swiped down together close the current tab, undoable like its menu's Close tab. Never
  /// with text selected: that gesture is for the selection, not the tab.
  void _closeTabByGesture() {
    if (_controller.selection != null) return;
    final tabId = widget.client.selectedPane?.tabId;
    if (tabId == null) return;
    final client = widget.client;
    final m = client.machine;
    HapticFeedback.mediumImpact();
    closeWithUndo(context, client, 'Tab closed', ['$m/$tabId'], () => client.closeTab(tabId, m), above: _messageBar);
  }

  /// Herdr holds the pane's history (see [PtyChannel.connect]), so dragging scrolls herdr's view a line
  /// per text row moved. A press held still past the long-press timeout is text selection instead, and
  /// so is any mouse drag: a mouse scrolls with its wheel ([_scrollSignal]).
  void _scroll(PointerMoveEvent e) {
    if (e.kind == PointerDeviceKind.mouse) return;
    if (!_dragging) {
      if (e.timeStamp - _downTime >= kLongPressTimeout || (e.position.dy - _downAt.dy).abs() < kTouchSlop) return;
      _dragging = true;
      _scrollRest = 0;
      return;
    }
    _scrollBy(e.delta.dy, e.position);
  }

  /// A mouse wheel scrolls herdr's view like a drag does, and so does a desktop touchpad's two-finger pan
  /// up or down; sideways, it swipes between agents as two fingers on a phone do. A pan keeps the axis
  /// it first moves along.
  void _scrollSignal(PointerEvent e) {
    if (e is PointerScrollEvent) _scrollBy(-e.scrollDelta.dy, e.position);
    if (e is PointerPanZoomStartEvent) {
      _padPan = Offset.zero;
      _padAxis = null;
    }
    if (e is PointerPanZoomEndEvent) _endSwipe();
    if (e is! PointerPanZoomUpdateEvent) return;
    _padPan += e.panDelta;
    if (_padAxis == null && _padPan.distance > kTouchSlop) {
      _padAxis = _padPan.dx.abs() > _padPan.dy.abs() ? Axis.horizontal : Axis.vertical;
      if (_padAxis == Axis.vertical) return _scrollBy(_padPan.dy, e.position);
    }
    if (_padAxis == Axis.vertical) _scrollBy(e.panDelta.dy, e.position);
    if (_padAxis == Axis.horizontal) _swipe(_padPan.dx);
  }

  /// The 0-based screen cell under [global], or null when the terminal has no size yet.
  (int, int)? _cellAt(Offset global) {
    final render = _view.currentState?.renderTerminal;
    if (render == null || !render.hasSize || _terminal.viewWidth <= 0 || _terminal.viewHeight <= 0) return null;
    final cell = render.getCellOffset(render.globalToLocal(global));
    // xterm counts rows from the buffer's top; herdr, from the screen's (see [_onTap]).
    final top = _terminal.buffer.height - _terminal.viewHeight;
    return (
      cell.x.clamp(0, _terminal.viewWidth - 1),
      (cell.y - top).clamp(0, _terminal.viewHeight - 1),
    );
  }

  /// Scrolls by [dy] pixels, positive toward older history. [at] is where the gesture is, so herdr's
  /// wheel lands on the widget scrolled; without it the wheel lands top-left, where OpenCode has
  /// nothing scrollable and the scroll does nothing.
  void _scrollBy(double dy, [Offset? at]) {
    if (_controller.selection != null) _controller.clearSelection(); // it would stay on rows whose text moves
    final cell = at == null ? null : _cellAt(at);
    if (cell != null) {
      _scrollColumn = cell.$1;
      _scrollRow = cell.$2;
    }
    final lineHeight = widget.client.fontSize * 1.1; // TerminalStyle height is 1.1
    _scrollRest += dy;
    final lines = _scrollRest ~/ lineHeight;
    if (lines == 0) return;
    _ptyChannel?.sendScroll(lines, column: _scrollColumn, row: _scrollRow);
    _scrollRest -= lines * lineHeight;
    // Counts scrolls, not lines: an app on the alternate screen moves a wheel tick per scroll, however
    // many lines it carries (see [_toLive]). Herdr stops at the bottom, so the count does too; it may
    // overshoot the top, which only means the way back scrolls further than needed. Capped, since the
    // way back sends a scroll per count.
    _scrolledSeq = widget.client.snapshot?.agentOf(widget.client.selectedPaneId ?? '')?.stateChangeSeq;
    setState(() {
      _scrolledUp = (_scrolledUp + lines.sign).clamp(0, 1000);
      _scrolledLines = _scrolledUp == 0 ? 0 : (_scrolledLines + lines).clamp(_scrolledUp, 65535);
    });
  }

  /// Parks the box's text as the current pane's draft and brings back [key]'s.
  void _swapDraft(String? key) {
    // A pane switch ends a history search: the query never becomes a draft.
    _showingHistory = false;
    _historyDraft = '';
    if (_draftKey != null) TerminalScreen._drafts[_draftKey!] = _message.text;
    TerminalScreen._drafts.removeWhere((_, text) => text.isEmpty);
    _draftKey = key;
    final text = TerminalScreen._drafts[key] ?? '';
    _message.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void _onClientUpdate() {
    if (!mounted) return;
    // Each pane keeps its own draft: park the box's text and bring back the new pane's.
    final paneId = widget.client.selectedPaneId;
    final key = paneId == null ? null : '${widget.client.machine}/$paneId';
    if (key != _draftKey) _swapDraft(key);
    // Switched off (e.g. from the notification, or its sheet) or removed: nothing to show, so back to the
    // agents, once, along with whatever is open over it.
    final client = widget.client;
    if ((client.isDisconnected || !client.machines.contains(client.machine)) && !_left && !widget.embedded) {
      _left = true;
      final route = ModalRoute.of(context);
      Navigator.popUntil(context, (r) => r == route);
      Navigator.maybePop(context);
    }
    setState(() {});
    _connectTerminal();
  }

  /// (Re)attaches when the selected pane or bridge address changes, or the app comes back on screen.
  void _connectTerminal() {
    final client = widget.client;
    final paneId = client.selectedPaneId;
    final pty = _ptyChannel;
    final state = WidgetsBinding.instance.lifecycleState;
    if (paneId == null ||
        client.selectedPane?.restoreError != null ||
        client.isDisconnected ||
        (state != null && state != AppLifecycleState.resumed && state != AppLifecycleState.inactive)) {
      // Machine switched, disconnected, pane not restored, or app in background: detach
      pty?.dispose();
      _ptyChannel = null;
      return;
    }
    final headers = client.headersOf(client.machine);
    // A new token for the machine reconnects too.
    if (pty != null &&
        pty.paneId == paneId &&
        pty.machine == client.machine &&
        pty.headers[HttpHeaders.authorizationHeader] == headers[HttpHeaders.authorizationHeader]) {
      return;
    }
    pty?.dispose();
    if (_controller.selection != null) _controller.clearSelection(); // the old pane's text
    // The same pane, reattached, keeps its place in history; another goes back to where it was left, unless
    // its agent changed status since, which starts it live.
    final pane = '${client.machine}/$paneId';
    if (pane != _scrolledPane) {
      _parkPlace();
      _scrolledPane = pane;
      final place = TerminalScreen._places.remove(pane);
      final kept = place != null && place.$3 == client.snapshot?.agentOf(paneId)?.stateChangeSeq;
      _scrolledUp = kept ? place.$1 : 0;
      _scrolledLines = kept ? place.$2 : 0;
      _scrolledSeq = kept ? place.$3 : null;
      _scrollColumn = kept ? place.$4 : null;
      _scrollRow = kept ? place.$5 : null;
    }
    _ptyChannel = PtyChannel(
      machine: client.machine,
      paneId: paneId,
      terminal: _terminal,
      headers: headers,
      takeover: _takeOver,
      onClose: _onTermClosed,
      // Herdr shows a freshly attached pane live, also after a lost connection, so scroll back to where
      // it was: as many scrolls as went up (an app on the alternate screen counts each as one wheel tick,
      // see [_toLive]), sharing the lines they carried (herdr's own scrollback counts those), at the cell
      // scrolled so the wheel lands on the same widget.
      onAttach: () {
        for (var i = 0; i < _scrolledUp; i++) {
          _ptyChannel?.sendScroll((_scrolledLines / _scrolledUp).ceil(),
              column: _scrollColumn, row: _scrollRow);
        }
      },
    );
    _takeOver = false; // spent on this attach; reconnects stay polite unless asked again
    _termBusy = false; // a new attach: herdr hasn't refused it yet
    _ptyChannel!.attached.addListener(_onAttached);
    _onAttached();
    _ptyChannel!.connect();
  }

  /// Keeps where the pane on screen is scrolled to, for when it's shown again.
  void _parkPlace() {
    if (_scrolledPane != null && _scrolledUp > 0) {
      TerminalScreen._places[_scrolledPane!] = (_scrolledUp, _scrolledLines, _scrolledSeq, _scrollColumn, _scrollRow);
    }
  }

  /// Marks the screen stale once the pane has been off for a second, so an ordinary attach never flashes it.
  void _onAttached() {
    _staleTimer?.cancel();
    if (_ptyChannel?.attached.value ?? true) {
      if ((_stale || _termBusy) && mounted) {
        setState(() {
          _stale = false;
          _termBusy = false;
        });
      }
      return;
    }
    _staleTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _stale = true);
    });
  }

  /// Herdr ended the session: when another client holds the pane, show the
  /// banner instead of fighting it; the channel retries slowly on its own.
  void _onTermClosed(String reason) {
    if (!mounted || _termBusy || !PtyChannel.isBusyReason(reason)) return;
    setState(() => _termBusy = true);
  }

  /// Steals the pane from the client holding it, once: the banner's Take over.
  void _takeOverPane() {
    _takeOver = true;
    if (mounted) setState(() => _termBusy = false);
    _ptyChannel?.dispose();
    _ptyChannel = null;
    _connectTerminal();
  }

  @override
  void dispose() {
    _parkPlace();
    _onMessageChanged();
    _message.removeListener(_onMessageChanged);
    _tabScroll.dispose();
    _messageFocus.dispose();
    _termFocus.dispose();
    _lifecycle.dispose();
    widget.client.removeListener(_onClientUpdate);
    _controller.dispose();
    _message.dispose();
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _ptyChannel?.dispose();
    _staleTimer?.cancel();
    super.dispose();
  }

  AgentModel? _currentAgent() {
    final snapshot = widget.client.snapshot;
    if (snapshot == null) return null;
    final paneId = widget.client.selectedPaneId;
    if (paneId != null) {
      final agent = snapshot.agentOf(paneId);
      if (agent != null) return agent;
      final pane = snapshot.panes.where((p) => p.id == paneId).firstOrNull;
      if (pane != null) {
        final tabPanes = snapshot.panes.where((p) => p.tabId == pane.tabId).map((p) => p.id).toSet();
        final agentInTab = snapshot.agents.where((a) => tabPanes.contains(a.paneId)).firstOrNull;
        if (agentInTab != null) return agentInTab;
      }
    }
    return null;
  }

  /// A file the agent sent: its name and what it is, and Install (an APK, on Android) or Open, which
  /// downloads it first, showing how far.
  Widget _deliveryCard(Delivery d, ColorScheme scheme) {
    final text = Theme.of(context).textTheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Icon(d.isApk ? Icons.android : Icons.insert_drive_file_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                Text(d.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ValueListenableBuilder<double?>(
            valueListenable: d.progress,
            builder: (context, progress, _) => progress != null
                ? SizedBox(width: 72, child: LinearProgressIndicator(value: progress))
                : FilledButton.tonal(
                    onPressed: () => widget.client.openDelivery(d),
                    child: Text(d.isApk && Platform.isAndroid ? 'Install' : 'Open'),
                  ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => widget.client.dismissDelivery(d),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.client;
    final scheme = Theme.of(context).colorScheme;
    final background = _background ?? scheme.surface;
    // The message bar's own buttons sit on the pane's background, which may be light in a dark theme or dark
    // in a light one: then they take the inverse colour.
    final onBackground = ThemeData.estimateBrightnessForColor(background) == scheme.brightness
        ? Theme.of(context)
        : Theme.of(context).copyWith(
            colorScheme: scheme.copyWith(onSurfaceVariant: scheme.onInverseSurface, primary: scheme.onInverseSurface),
          );
    final snapshot = client.snapshot;
    final pane = client.selectedPane;
    final currentAgent = _currentAgent();
    final currentUsage = currentAgent?.usage;
    final workspace = snapshot?.workspaces.where((w) => w.id == pane?.workspaceId).firstOrNull;
    final connecting = client.machines.isNotEmpty && !client.connected && !client.isDisconnected;
    final unavailable = client.errorOf(client.machine) != null && snapshot == null
        ? (Icons.cloud_off, "Can't reach ${client.nameOf(client.machine)}", client.errorOf(client.machine)!)
        : pane?.restoreError != null
            ? (Icons.restore_page_outlined, "Couldn't restore this pane", pane!.restoreError!)
            : null;
    if (pane?.tabId != _shownTabId) {
      _shownTabId = pane?.tabId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // The strip builds lazily, so the current tab may not exist yet to scroll to; tabs are all one width.
        final at = _tabs()?.$2 ?? -1;
        if (at < 0 || !_tabScroll.hasClients) return;
        final pos = _tabScroll.position;
        final offset = (at * _tabWidth - (pos.viewportDimension - _tabWidth) / 2).clamp(0.0, pos.maxScrollExtent);
        _tabScroll.animateTo(offset, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
      });
    }

    final isWorktree = workspace?.isLinkedWorktree ?? false;
    final title = workspace == null ? 'workspace' : snapshot?.titleOf(workspace) ?? workspace.displayName;
    final branch = workspace?.branchName ?? '';

    return PopScope(
      canPop: !_showingHistory,
      onPopInvokedWithResult: (didPop, _) {
        // System back closes the history search first, restoring the box's text.
        if (!didPop && _showingHistory) _closeHistory();
      },
      child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        // Beside the back button; embedded, with none, the usual inset from the agents.
        titleSpacing: widget.embedded ? NavigationToolbar.kMiddleSpacing : 0,
        // The terminal isn't content scrolling under the bar: keep the bar's colour when it scrolls.
        notificationPredicate: (_) => false,
        // A step above the terminal's surface, so the current tab stands out joined to the terminal.
        backgroundColor: scheme.surfaceContainerHigh,
        // The workspace's name and branch; its actions are in the workspaces panel.
        title: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (isWorktree || branch.isNotEmpty)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isWorktree) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'worktree',
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: scheme.onSecondaryContainer,
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                      if (branch.isNotEmpty) const SizedBox(width: 6),
                    ],
                    if (branch.isNotEmpty)
                      Flexible(
                        child: Text.rich(
                          TextSpan(text: branch, children: aheadBehind(workspace!)),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          // The agent's usage; a plain shell has none.
          if (currentAgent != null)
            Builder(
              builder: (context) {
                final quotaFg = _quotaColor(scheme, currentUsage?.highestPercent);
                final quotaBg = quotaFg.withAlpha(35);
                final pct = currentUsage?.highestPercent != null
                    ? ((1.0 - currentUsage!.highestPercent!).clamp(0.0, 1.0) * 100).round()
                    : null;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: 'Usage and quotas',
                    child: Material(
                      color: quotaBg,
                      borderRadius: BorderRadius.circular(16),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _showUsage(currentAgent, currentUsage),
                        child: Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AgentIcon(name: currentAgent.name, size: 14, color: quotaFg),
                              if (pct != null) ...[
                                const SizedBox(width: 4),
                                Text(
                                  '$pct%',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: quotaFg,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: '${client.nameOf(client.machine)} · ${machineStatus(client, client.machine)}',
              child: ActionChip(
                backgroundColor: scheme.secondaryContainer,
                side: BorderSide.none,
                labelStyle: TextStyle(color: scheme.onSecondaryContainer),
                avatar: switch (machineStatusIcon(client, client.machine, scheme)) {
                  final icon? => FittedBox(child: SizedBox.square(dimension: 24, child: icon)),
                  null => null,
                },
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(client.nameOf(client.machine), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  showMachineSheet(context, client, client.machine);
                },
              ),
            ),
          ),
        ],
        // The workspace's tabs, like Vivaldi's: equal 168dp tabs, scrolling when they overflow.
        // The current one is rounded on top and takes the terminal's color, joined to it below.
        // Each shows its agent icon with an online status ring and truncated tab summary. Hold a tab and lift for its
        // menu (or right-click), hold and drag to move it.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(34),
          // While connecting, a thin progress bar over the strip's top edge, taking no room of its own.
          child: Stack(
            children: [
              SizedBox(
                height: 34,
                child: switch (_tabs()) {
                  (final tabs, final i) when i >= 0 => Row(
                      children: [
                        Expanded(
                          // Hold and drag a tab: the others slide aside to show where it lands, anywhere along the
                          // strip. [to] counts in the order before the move, so a tab goes in the place of the one
                          // now at its final index.
                          child: ReorderableListView(
                            scrollDirection: Axis.horizontal,
                            scrollController: _tabScroll,
                            buildDefaultDragHandles: false,
                            onReorder: (from, to) {
                              if (to > from) to--;
                              if (to != from) client.moveTab(tabs[from].id, tabs[to].id);
                            },
                            proxyDecorator: (child, _, __) => Material(
                              color: scheme.secondaryContainer,
                              elevation: 3,
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                              child: child,
                            ),
                            children: [
                              for (final (j, t) in tabs.indexed)
                                Builder(
                                  key: ValueKey(t.id),
                                  builder: (context) {
                                    final tabAgent = _tabAgent(t);
                                    final summary = _tabSummary(t);
                                    const top = BorderRadius.vertical(top: Radius.circular(10));
                                    // Held and lifted, its menu; held and dragged, it moves.
                                    return HoldMenu(
                                      onMenu: (at) => _showTabMenu(at, t, tabs, j),
                                      child: ReorderableDelayedDragStartListener(
                                        index: j,
                                        // The full line on hover (manual: hover still shows, touch doesn't fight the hold menu).
                                        child: Tooltip(
                                          message: summary,
                                          triggerMode: TooltipTriggerMode.manual,
                                          waitDuration: const Duration(milliseconds: 500),
                                          child: Container(
                                            width: _tabWidth,
                                            decoration:
                                                j == i ? BoxDecoration(color: background, borderRadius: top) : null,
                                            child: InkWell(
                                              customBorder: const RoundedRectangleBorder(borderRadius: top),
                                              onTap: () => client.selectTab(t.id),
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                                child: Row(
                                                  children: [
                                                    // herdr's `idle` is `monitoring` while the agent waits on monitors, as in the list.
                                                    AgentAvatar(
                                                        name: tabAgent?.name ?? '',
                                                        radius: 7.5,
                                                        status: t.agentStatus == 'idle' && tabAgent?.monitoring == true
                                                            ? 'monitoring'
                                                            : t.agentStatus),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      child: Text(
                                                        summary,
                                                        maxLines: 1,
                                                        overflow: TextOverflow.ellipsis,
                                                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                                            color: j == i ? scheme.onSurface : scheme.onSurfaceVariant),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'New tab',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(width: 40, height: 34),
                          iconSize: 18,
                          icon: const Icon(Icons.add),
                          onPressed: () => client.createTab(tabs[i].workspaceId),
                        ),
                      ],
                    ),
                  _ => null,
                },
              ),
              if (connecting) const LinearProgressIndicator(minHeight: 2),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_termBusy)
              // Another client (usually the desktop) holds this pane: herdr refused the
              // attach rather than taking it over, and retries slowly. Take over steals it.
              Container(
                color: scheme.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.desktop_windows_outlined, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Another client is viewing this pane',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    TextButton(
                      onPressed: _takeOverPane,
                      child: const Text('Take over'),
                    ),
                  ],
                ),
              ),
            Expanded(
              // Connected to its bridge, which can't show it (e.g. a machine it reaches over SSH is down), or
              // herdr couldn't restore the pane, which then has no terminal.
              child: unavailable != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(unavailable.$1, size: 48, color: scheme.onSurfaceVariant),
                            const SizedBox(height: 12),
                            Text(unavailable.$2, style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 8),
                            Text(unavailable.$3,
                                textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    )
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: Listener(
                            onPointerDown: _trackPointer,
                            onPointerMove: _trackPointer,
                            onPointerUp: _trackPointer,
                            onPointerCancel: _trackPointer,
                            onPointerSignal: _scrollSignal,
                            onPointerPanZoomStart: _scrollSignal,
                            onPointerPanZoomUpdate: _scrollSignal,
                            onPointerPanZoomEnd: _scrollSignal,
                            // Embedded, a little room from the agents and the screen's edge, in the pane's colour.
                            child: Container(
                                color: background,
                                padding: EdgeInsets.symmetric(horizontal: widget.embedded ? 4 : 0),
                                // Following a two-finger swipe until it switches agent, and springing back after;
                                // behind it, where each way leads.
                                child: Stack(children: [
                                  if (_swipeDx != 0)
                                    Positioned.fill(
                                      child: Row(children: [
                                        for (final step in [-1, 1])
                                          if (_peek(step) case final label?)
                                            Expanded(
                                              child: Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                                child: Text(step < 0 ? '‹ $label' : '$label ›',
                                                    maxLines: 4,
                                                    overflow: TextOverflow.ellipsis,
                                                    textAlign: step < 0 ? TextAlign.left : TextAlign.right,
                                                    style: Theme.of(context).textTheme.labelLarge),
                                              ),
                                            ),
                                      ]),
                                    ),
                                  AnimatedContainer(
                                    duration: _swipeDx == 0 ? const Duration(milliseconds: 150) : Duration.zero,
                                    curve: Curves.easeOut,
                                    transform: Matrix4.translationValues(_swipeDx, 0, 0),
                                    child: TerminalView(
                                      _terminal,
                                      key: _view,
                                      controller: _controller,
                                      onSecondaryTapDown: (details, _) => _showTerminalMenu(details),
                                      backgroundOpacity: 1.0,
                                      // xterm's default colours, on the app's surface.
                                      theme: TerminalTheme(
                                        cursor: _defaultTheme.cursor,
                                        selection: _defaultTheme.selection,
                                        foreground: scheme.onSurface,
                                        background: scheme.surface,
                                        black: _defaultTheme.black,
                                        white: _defaultTheme.white,
                                        red: _defaultTheme.red,
                                        green: _defaultTheme.green,
                                        yellow: _defaultTheme.yellow,
                                        blue: _defaultTheme.blue,
                                        magenta: _defaultTheme.magenta,
                                        cyan: _defaultTheme.cyan,
                                        brightBlack: _defaultTheme.brightBlack,
                                        brightRed: _defaultTheme.brightRed,
                                        brightGreen: _defaultTheme.brightGreen,
                                        brightYellow: _defaultTheme.brightYellow,
                                        brightBlue: _defaultTheme.brightBlue,
                                        brightMagenta: _defaultTheme.brightMagenta,
                                        brightCyan: _defaultTheme.brightCyan,
                                        brightWhite: _defaultTheme.brightWhite,
                                        searchHitBackground: _defaultTheme.searchHitBackground,
                                        searchHitBackgroundCurrent: _defaultTheme.searchHitBackgroundCurrent,
                                        searchHitForeground: _defaultTheme.searchHitForeground,
                                      ),
                                      textStyle: TerminalStyle(
                                        fontSize: client.fontSize,
                                        fontFamily: 'MesloLGS Nerd Font Mono',
                                        height: 1.1,
                                      ),
                                      focusNode: _termFocus,
                                      // Not on the focus node: xterm's own Focus widgets replace a handler set there.
                                      onKeyEvent: _onTermKeyEvent,
                                      // For a hardware keyboard; on a phone it would open the soft one with every agent.
                                      autofocus: !Platform.isAndroid,
                                      simulateScroll: false,
                                    )),
                                  ]),
                                ),
                          ),
                        ),
                        if (_copyTop() case final top?)
                          // Copy floats by the selection, like Android's own text toolbar.
                          Positioned(
                            top: top,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: FilledButton.tonalIcon(
                                onPressed: _copySelection,
                                icon: const Icon(Icons.content_copy, size: 18),
                                label: const Text('Copy'),
                              ),
                            ),
                          ),
                        // A text field's handles, to adjust the selection once the long-press has let go.
                        for (final begin in [true, false])
                          if (_handleAt(begin) case final at?)
                            Positioned(
                              left: at.dx - (begin ? 32 : 0),
                              top: at.dy,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanUpdate: (d) => _dragHandle(begin, d.globalPosition),
                                child: SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: Align(
                                    alignment: begin ? Alignment.topRight : Alignment.topLeft,
                                    // A drop whose point touches the text, as Android's.
                                    child: Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        color: scheme.primary,
                                        borderRadius: BorderRadius.only(
                                          topLeft: Radius.circular(begin ? 10 : 0),
                                          topRight: Radius.circular(begin ? 0 : 10),
                                          bottomLeft: const Radius.circular(10),
                                          bottomRight: const Radius.circular(10),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        if (_stale)
                          // The connection dropped: the screen is the pane's last frame until it's back.
                          Positioned.fill(
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: background.withAlpha(128),
                                child: const Align(
                                  alignment: Alignment(0, -0.8),
                                  child: Chip(
                                    avatar: Icon(Icons.wifi_off),
                                    label: Text('Reconnecting…'),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (_scrolledUp > 0)
                          // Back to live: a small round arrow, centred at the bottom.
                          Positioned(
                            bottom: 12,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: FloatingActionButton.small(
                                tooltip: 'Back to live',
                                onPressed: _toLive,
                                child: const Icon(Icons.arrow_downward),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            // Files the agent sent (herdr-bridge send), above the box until opened or dismissed: the newest,
            // and the others behind "N more".
            ...() {
              final files = client.deliveriesOf(client.machine, pane?.id).reversed.toList();
              return [
                for (final d in _allFiles ? files : files.take(1)) _deliveryCard(d, scheme),
                if (files.length > 1)
                  Container(
                    color: scheme.surfaceContainerHigh,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 4),
                    child: TextButton.icon(
                      onPressed: () => setState(() => _allFiles = !_allFiles),
                      icon: Icon(_allFiles ? Icons.expand_less : Icons.expand_more, size: 18),
                      label: Text(_allFiles ? 'Show fewer' : '${files.length - 1} more'),
                    ),
                  ),
              ];
            }(),
            // Two places to type: the message box, or the terminal itself with the control keys in the
            // box's place. The box leads with the control keys' button, which brings the keys without
            // the keyboard; the keys lead with the box's button back, and end with the keyboard's,
            // which shows or hides it. A keyboard that is up stays up across the swap.
            if (!client.hideMessageTerminal)
              Container(
                // The undo snackbar sits above the message bar, as Gmail's sits above its composer.
                key: _messageBar,
                color: background,
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Recent messages stay above the pill, which doubles as their search box.
                    if (_showingHistory && !client.keyBar)
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _message,
                        builder: (context, val, _) {
                          final messages = _filterHistory(_history, val.text);
                          final commands = _filterHistory(_recentCommands, val.text);
                          final empty = messages.isEmpty && commands.isEmpty;
                          return ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 300),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                              child: Material(
                                color: scheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(16),
                                clipBehavior: Clip.antiAlias,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                                      child: Text('Recent messages',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleSmall
                                              ?.copyWith(color: Theme.of(context).colorScheme.primary)),
                                    ),
                                    Flexible(
                                      child: empty
                                          ? Padding(
                                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                                              child: Text(
                                                _history.isEmpty && _recentCommands.isEmpty
                                                    ? 'No recent messages yet'
                                                    : 'No matches',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodyMedium
                                                    ?.copyWith(color: scheme.onSurfaceVariant),
                                              ),
                                            )
                                          : ListView(
                                              shrinkWrap: true,
                                              children: [
                                                for (final h in messages)
                                                  ListTile(
                                                    dense: true,
                                                    leading: const Icon(Icons.history),
                                                    title: Text(h,
                                                        maxLines: 2, overflow: TextOverflow.ellipsis),
                                                    onTap: () => _pickHistory(h),
                                                  ),
                                              ],
                                            ),
                                    ),
                                    if (commands.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 4,
                                          children: [
                                            for (final r in commands)
                                              ActionChip(
                                                backgroundColor: scheme.secondaryContainer,
                                                side: BorderSide.none,
                                                labelStyle: TextStyle(color: scheme.onSecondaryContainer),
                                                label: Text(r),
                                                onPressed: () => _sendMessage(r),
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    Row(
                      children: [
                    Theme(
                      data: onBackground,
                      child: client.keyBar
                          ? IconButton(
                              tooltip: 'Message box',
                              icon: const Icon(Icons.chat_bubble_outline),
                              onPressed: () {
                                // Focus moves before the swap, in one frame.
                                if (MediaQuery.viewInsetsOf(context).bottom > 0) _messageFocus.requestFocus();
                                client.setKeyBar(false);
                              },
                            )
                          : IconButton(
                              tooltip: 'Control keys',
                              icon: const Icon(Icons.keyboard_command_key),
                              onPressed: () {
                                if (_showingHistory) _closeHistory();
                                // Focus moves before the swap, in one frame, mirroring the message box
                                // button: a keyboard that is up stays up, now into the terminal. The gate
                                // relocks in the same block (see [_gateKeyboard]): split these apart and a
                                // stray focus could summon the keyboard uninvited.
                                if (MediaQuery.viewInsetsOf(context).bottom > 0) {
                                  _termFocus.canRequestFocus = true;
                                  _view.currentState?.requestKeyboard();
                                  _termFocus.canRequestFocus = false;
                                }
                                client.setKeyBar(true);
                              },
                            ),
                    ),
                    Expanded(
                      child: client.keyBar
                          ? KeyboardAccessoryBar(
                              ctrl: _ctrl,
                              onCtrl: () => setState(() => _ctrl = !_ctrl),
                              onKey: _key,
                              onText: _send,
                            )
                          : TextField(
                              controller: _message,
                              focusNode: _messageFocus,
                              minLines: 1,
                              maxLines: 4,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: client.enterBehavior == EnterBehavior.send
                                  ? TextInputAction.send
                                  : TextInputAction.newline,
                              onSubmitted: client.enterBehavior == EnterBehavior.send && !_showingHistory
                                  ? (_) => _sendMessage()
                                  : null,
                              // An M3 filled text field, pill-shaped like a search bar.
                              // With the history panel open it is the panel's search box.
                              decoration: InputDecoration(
                                hintText: _showingHistory ? 'Search recent messages…' : 'Message terminal…',
                                filled: true,
                                fillColor: scheme.surfaceContainerHigh,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(24),
                                  borderSide: BorderSide.none,
                                ),
                                prefixIcon: _showingHistory
                                    ? IconButton(
                                        tooltip: 'Close history',
                                        icon: const Icon(Icons.close),
                                        onPressed: _closeHistory,
                                      )
                                    : IconButton(
                                        tooltip: 'History and recent commands',
                                        icon: const Icon(Icons.history),
                                        onPressed: _toggleHistory,
                                      ),
                                suffixIcon: _showingHistory
                                    ? null
                                    : IconButton(
                                        tooltip: _uploadingImage ? 'Uploading image…' : 'Attach image',
                                        icon: _uploadingImage
                                            ? const SizedBox.square(
                                                dimension: 18,
                                                child: CircularProgressIndicator(strokeWidth: 2),
                                              )
                                            : const Icon(Icons.image_outlined),
                                        onPressed: _uploadingImage ? null : _attachImage,
                                      ),
                              ),
                            ),
                    ),
                    if (client.keyBar)
                      Theme(
                        data: onBackground,
                        child: _termFocus.hasFocus && MediaQuery.viewInsetsOf(context).bottom > 0
                            ? IconButton(
                                tooltip: 'Hide keyboard',
                                icon: const Icon(Icons.keyboard_hide_outlined),
                                onPressed: _termFocus.unfocus,
                              )
                            : IconButton(
                                tooltip: 'Keyboard',
                                icon: const Icon(Icons.keyboard_outlined),
                                onPressed: _openKeyboard,
                              ),
                      ),
                    // While searching the pill filters; sending waits for a pick.
                    if (!client.keyBar && !_showingHistory) ...[
                      const SizedBox(width: 6),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _message,
                        builder: (context, val, _) => IconButton.filled(
                          style: IconButton.styleFrom(
                            fixedSize: Platform.isAndroid ? const Size(48, 48) : null,
                            backgroundColor: scheme.primary,
                            foregroundColor: scheme.onPrimary,
                          ),
                          tooltip: val.text.isEmpty ? 'Enter' : 'Send',
                          icon: Icon(val.text.isEmpty ? Icons.keyboard_return : Icons.send_rounded),
                          onPressed: _sendMessage,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ));
  }
}
