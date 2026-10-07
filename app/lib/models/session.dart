class SessionSnapshot {
  final String? focusedPaneId;
  final List<WorkspaceModel> workspaces;
  final List<TabModel> tabs;
  final List<PaneModel> panes;
  final List<AgentModel> agents;

  SessionSnapshot({
    this.focusedPaneId,
    required this.workspaces,
    required this.tabs,
    required this.panes,
    required this.agents,
  });

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) {
    var rawSnap = json['snapshot'] ?? json;
    return SessionSnapshot(
      focusedPaneId: rawSnap['focused_pane_id'],
      workspaces: (rawSnap['workspaces'] as List<dynamic>? ?? [])
          .map((e) => WorkspaceModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      tabs: (rawSnap['tabs'] as List<dynamic>? ?? []).map((e) => TabModel.fromJson(e as Map<String, dynamic>)).toList(),
      panes:
          (rawSnap['panes'] as List<dynamic>? ?? []).map((e) => PaneModel.fromJson(e as Map<String, dynamic>)).toList(),
      agents: (rawSnap['agents'] as List<dynamic>? ?? [])
          .map((e) => AgentModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// The tab's focused pane, or its first.
  String? paneOfTab(String? tabId) {
    final inTab = panes.where((p) => p.tabId == tabId);
    return (inTab.where((p) => p.focused).firstOrNull ?? inTab.firstOrNull)?.id;
  }

  AgentModel? agentOf(String paneId) => agents.where((a) => a.paneId == paneId).firstOrNull;

  /// Where a pane is: its branch name (falling back to workspace), and its tab in parentheses when the workspace has more than one.
  String placeOf(PaneModel pane) {
    final ws = workspaces.where((w) => w.id == pane.workspaceId).firstOrNull;
    final own = tabs.where((t) => t.workspaceId == pane.workspaceId);
    final tab = own.length > 1 ? own.where((t) => t.id == pane.tabId).firstOrNull : null;
    final branch = ws?.gitBranch?.replaceFirst('worktree/', '') ?? ws?.displayName;
    return [if (branch != null) branch, if (tab != null) '(${tab.displayName})'].join(' ');
  }
}

class WorkspaceModel {
  final String id;
  final int number;
  final String label;
  final String? activeTabId;
  final String agentStatus;

  /// Git repo identity from `worktree.repo_key`; linked worktrees nest under the repo's main workspace.
  final String? repoKey;
  final bool isLinkedWorktree;

  /// Added by the bridge (`git branch --show-current` in the workspace's directory).
  final String? gitBranch;

  WorkspaceModel({
    required this.id,
    required this.number,
    required this.label,
    this.activeTabId,
    required this.agentStatus,
    this.repoKey,
    this.isLinkedWorktree = false,
    this.gitBranch,
  });

  /// Name as Herdr's sidebar shows it: worktrees by branch, minus Herdr's `worktree/` prefix.
  String get displayName {
    if (isLinkedWorktree) {
      return gitBranch?.replaceFirst('worktree/', '') ?? label.replaceFirst('worktree-', '');
    }
    return label.isNotEmpty ? label : 'workspace $number';
  }

  factory WorkspaceModel.fromJson(Map<String, dynamic> json) {
    // The bridge leaves the branch out outside a git repo or on a detached HEAD; an empty one counts as none too.
    final branch = (json['git_branch'] as String?)?.trim();
    return WorkspaceModel(
      id: json['workspace_id'] ?? '',
      number: json['number'] ?? 0,
      label: json['label'] ?? '',
      activeTabId: json['active_tab_id'],
      agentStatus: json['agent_status'] ?? 'unknown',
      repoKey: json['worktree']?['repo_key'],
      isLinkedWorktree: json['worktree']?['is_linked_worktree'] ?? false,
      gitBranch: branch == null || branch.isEmpty ? null : branch,
    );
  }
}

class TabModel {
  final String id;
  final String workspaceId;
  final int number;
  final String label;
  final String agentStatus;

  TabModel({
    required this.id,
    required this.workspaceId,
    required this.number,
    required this.label,
    required this.agentStatus,
  });

  String get displayName => label.isNotEmpty ? label : 'Tab $number';

  factory TabModel.fromJson(Map<String, dynamic> json) {
    return TabModel(
      id: json['tab_id'] ?? '',
      workspaceId: json['workspace_id'] ?? '',
      number: json['number'] ?? 0,
      label: json['label'] ?? '',
      agentStatus: json['agent_status'] ?? 'unknown',
    );
  }
}

class PaneModel {
  final String id;
  final String workspaceId;
  final String tabId;
  final bool focused;
  final String terminalTitle;
  final String agentStatus;

  PaneModel({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.focused,
    required this.terminalTitle,
    required this.agentStatus,
  });

  factory PaneModel.fromJson(Map<String, dynamic> json) {
    // Agents tag their titles their own way: OpenCode's "OC | " in front, Grok's " - grok" after. Claude
    // Code's title before its first summary, and Codex's (the folder it runs in), say nothing.
    final String raw = json['title'] ?? json['terminal_title_stripped'] ?? json['terminal_title'] ?? '';
    final title = raw.replaceFirst(RegExp(r'^OC \| '), '').replaceFirst(RegExp(r' - grok$'), '');
    final String cwd = json['cwd'] ?? '';
    return PaneModel(
      id: json['pane_id'] ?? '',
      workspaceId: json['workspace_id'] ?? '',
      tabId: json['tab_id'] ?? '',
      focused: json['focused'] ?? false,
      terminalTitle: title == 'Claude Code' || cwd.isNotEmpty && title == cwd.split('/').last ? '' : title,
      agentStatus: json['agent_status'] ?? 'unknown',
    );
  }
}

class AgentModel {
  final String name;
  final String paneId;
  final String status;

  /// Bumped by herdr each time the agent completes work, whether or not the pane was viewed.
  final int? completionSeq;

  /// Bumped by herdr each time the agent's status changes.
  final int? stateChangeSeq;

  AgentModel({
    required this.name,
    required this.paneId,
    required this.status,
    this.completionSeq,
    this.stateChangeSeq,
  });

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    return AgentModel(
      // `name` is a name the user gave the pane, when there is one.
      name: json['agent'] ?? json['name'] ?? '',
      paneId: json['pane_id'] ?? '',
      status: json['status'] ?? json['agent_status'] ?? 'unknown',
      completionSeq: json['completion_seq'],
      stateChangeSeq: json['state_change_seq'],
    );
  }
}
