class SessionSnapshot {
  final String version;
  final int protocol;
  final String? focusedWorkspaceId;
  final String? focusedTabId;
  final String? focusedPaneId;
  final List<WorkspaceModel> workspaces;
  final List<TabModel> tabs;
  final List<PaneModel> panes;
  final List<AgentModel> agents;

  SessionSnapshot({
    required this.version,
    required this.protocol,
    this.focusedWorkspaceId,
    this.focusedTabId,
    this.focusedPaneId,
    required this.workspaces,
    required this.tabs,
    required this.panes,
    required this.agents,
  });

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) {
    var rawSnap = json['snapshot'] ?? json;
    return SessionSnapshot(
      version: rawSnap['version']?.toString() ?? '',
      protocol: rawSnap['protocol'] ?? 0,
      focusedWorkspaceId: rawSnap['focused_workspace_id'],
      focusedTabId: rawSnap['focused_tab_id'],
      focusedPaneId: rawSnap['focused_pane_id'],
      workspaces: (rawSnap['workspaces'] as List<dynamic>? ?? [])
          .map((e) => WorkspaceModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      tabs: (rawSnap['tabs'] as List<dynamic>? ?? [])
          .map((e) => TabModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      panes: (rawSnap['panes'] as List<dynamic>? ?? [])
          .map((e) => PaneModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      agents: (rawSnap['agents'] as List<dynamic>? ?? [])
          .map((e) => AgentModel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class WorkspaceModel {
  final String id;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;
  final int tabCount;
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
    required this.focused,
    required this.paneCount,
    required this.tabCount,
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
    return WorkspaceModel(
      id: json['workspace_id'] ?? '',
      number: json['number'] ?? 0,
      label: json['label'] ?? '',
      focused: json['focused'] ?? false,
      paneCount: json['pane_count'] ?? 0,
      tabCount: json['tab_count'] ?? 0,
      activeTabId: json['active_tab_id'],
      agentStatus: json['agent_status'] ?? 'unknown',
      repoKey: json['worktree']?['repo_key'],
      isLinkedWorktree: json['worktree']?['is_linked_worktree'] ?? false,
      gitBranch: json['git_branch'],
    );
  }
}

class TabModel {
  final String id;
  final String workspaceId;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;
  final String agentStatus;

  TabModel({
    required this.id,
    required this.workspaceId,
    required this.number,
    required this.label,
    required this.focused,
    required this.paneCount,
    required this.agentStatus,
  });

  factory TabModel.fromJson(Map<String, dynamic> json) {
    return TabModel(
      id: json['tab_id'] ?? '',
      workspaceId: json['workspace_id'] ?? '',
      number: json['number'] ?? 0,
      label: json['label'] ?? '',
      focused: json['focused'] ?? false,
      paneCount: json['pane_count'] ?? 0,
      agentStatus: json['agent_status'] ?? 'unknown',
    );
  }
}

class PaneModel {
  final String id;
  final String workspaceId;
  final String tabId;
  final bool focused;
  final String cwd;
  final String terminalTitle;
  final String agentStatus;

  PaneModel({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.focused,
    required this.cwd,
    required this.terminalTitle,
    required this.agentStatus,
  });

  factory PaneModel.fromJson(Map<String, dynamic> json) {
    return PaneModel(
      id: json['pane_id'] ?? '',
      workspaceId: json['workspace_id'] ?? '',
      tabId: json['tab_id'] ?? '',
      focused: json['focused'] ?? false,
      cwd: json['cwd'] ?? '',
      terminalTitle: json['terminal_title_stripped'] ?? json['terminal_title'] ?? '',
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

  AgentModel({
    required this.name,
    required this.paneId,
    required this.status,
    this.completionSeq,
  });

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    return AgentModel(
      name: json['name'] ?? json['agent'] ?? '',
      paneId: json['pane_id'] ?? '',
      status: json['status'] ?? json['agent_status'] ?? 'unknown',
      completionSeq: json['completion_seq'],
    );
  }
}
