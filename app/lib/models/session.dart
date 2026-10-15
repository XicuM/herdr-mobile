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

  /// Where a pane is: its workspace name, and its tab in parentheses when the workspace has more than one.
  String placeOf(PaneModel pane) {
    final ws = workspaces.where((w) => w.id == pane.workspaceId).firstOrNull;
    final own = tabs.where((t) => t.workspaceId == pane.workspaceId);
    final tab = own.length > 1 ? own.where((t) => t.id == pane.tabId).firstOrNull : null;
    final wsName = ws?.displayName;
    return [if (wsName != null) wsName, if (tab != null) '(${tab.displayName})'].join(' ');
  }

  /// A repo's main workspace: the first non-linked one with [repoKey] in herdr's order, which is
  /// also the workspace herdr's `worktree.list` answers from (`source_workspace_id`).
  WorkspaceModel? mainOf(String? repoKey) {
    if (repoKey == null) return null;
    return workspaces.where((w) => !w.isLinkedWorktree && w.repoKey == repoKey).firstOrNull;
  }

  /// What a workspace's header calls it, over its [WorkspaceModel.branchName]: a linked worktree not renamed
  /// by its repository's workspace.
  String titleOf(WorkspaceModel ws) => (ws.named ? null : mainOf(ws.repoKey)?.displayName) ?? ws.displayName;

  /// One block per top-level workspace, so a block drags with its worktrees: each linked worktree
  /// nests under its repo's main workspace ([mainOf]); one whose repo has no open main workspace
  /// stands alone. Every workspace appears exactly once, even when several workspaces share a repo.
  List<List<WorkspaceModel>> get worktreeBlocks {
    final blocks = <List<WorkspaceModel>>[];
    for (final w in workspaces) {
      if (w.isLinkedWorktree && mainOf(w.repoKey) != null) continue;
      blocks.add([
        w,
        if (!w.isLinkedWorktree && w.repoKey != null)
          ...workspaces.where((c) => c.isLinkedWorktree && c.repoKey == w.repoKey && mainOf(c.repoKey)?.id == w.id),
      ]);
    }
    return blocks;
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

  /// Name as Herdr's sidebar shows it: its label (the name it was given, else its checkout folder's), but a
  /// linked worktree not renamed by its branch, minus Herdr's `worktree/` prefix. herdr names a new worktree's
  /// checkout folder after its branch (`branch_to_path_slug`), so a label that is still that slug wasn't given.
  String get displayName => named ? (label.isNotEmpty ? label : 'workspace $number') : branchName!;

  /// Whether it shows its label: anything but a linked worktree still named after its branch.
  bool get named => !isLinkedWorktree || gitBranch == null || label != _slug(gitBranch!);

  /// The checked-out branch, minus Herdr's `worktree/` prefix in a linked worktree.
  String? get branchName => isLinkedWorktree ? gitBranch?.replaceFirst('worktree/', '') : gitBranch;

  /// herdr's `branch_to_path_slug`: lowercase alphanumerics, every other run one `-`, trimmed of them.
  static String _slug(String branch) {
    final slug = branch.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'worktree' : slug;
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

  /// Why herdr couldn't bring the pane back after a restart (its folder is gone, its shell won't start):
  /// it has no terminal to show until that is fixed.
  final String? restoreError;

  PaneModel({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.focused,
    required this.terminalTitle,
    required this.agentStatus,
    this.restoreError,
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
      restoreError: json['restore_error'],
    );
  }
}

class AgentModel {
  final String name;
  final String paneId;
  final String status;

  /// True when the bridge saw background monitors running in the pane while
  /// herdr calls it `idle`: the agent is waiting on a result, not idle.
  final bool monitoring;

  /// While idle after completing work (not after an interrupt), the `state_change_seq` of that change, so it
  /// rises with each completion whether or not the pane was viewed; null otherwise.
  final int? completionSeq;

  /// Bumped by herdr each time the agent's status changes.
  final int? stateChangeSeq;

  /// Optional subscription usage and rate limits attached by the bridge.
  final AgentUsage? usage;

  AgentModel({
    required this.name,
    required this.paneId,
    required this.status,
    this.monitoring = false,
    this.completionSeq,
    this.stateChangeSeq,
    this.usage,
  });

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    return AgentModel(
      // `name` is a name the user gave the pane, when there is one.
      name: json['agent'] ?? json['name'] ?? '',
      paneId: json['pane_id'] ?? '',
      status: json['status'] ?? json['agent_status'] ?? 'unknown',
      monitoring: json['monitoring'] == true,
      completionSeq: json['completion_seq'],
      stateChangeSeq: json['state_change_seq'],
      usage: json['usage'] is Map<String, dynamic> ? AgentUsage.fromJson(json['usage'] as Map<String, dynamic>) : null,
    );
  }

  /// What the agents list shows: `monitoring` while herdr says `idle` but the
  /// bridge saw background monitors running. Any other herdr status wins.
  String get displayStatus => status == 'idle' && monitoring ? 'monitoring' : status;
}

class AgentUsage {
  final String? tierLabel;
  final List<UsageLimit> limits;
  final int? todayTokens;
  final int? todayPrompts;

  AgentUsage({
    this.tierLabel,
    this.limits = const [],
    this.todayTokens,
    this.todayPrompts,
  });

  /// The highest utilization percentage among the primary (Gemini) limits, or
  /// null if no limits. Secondary tiers (Claude/GPT sharing the Antigravity
  /// plan) are still listed in the usage sheet but never drive this number;
  /// when nothing is tagged primary (older bridges), all limits count.
  double? get highestPercent {
    if (limits.isEmpty) return null;
    final primary = limits.where((l) => l.isPrimary).toList();
    final counted = primary.isNotEmpty ? primary : limits;
    return counted.map((l) => l.percent).reduce((a, b) => a > b ? a : b);
  }

  factory AgentUsage.fromJson(Map<String, dynamic> json) {
    return AgentUsage(
      tierLabel: json['tier_label'] ?? json['tierLabel'],
      limits: (json['limits'] as List<dynamic>? ?? [])
          .map((e) => UsageLimit.fromJson(e as Map<String, dynamic>))
          .toList(),
      todayTokens: json['today_tokens'] ?? json['todayTotalTokens'],
      todayPrompts: json['today_prompts'] ?? json['todayPrompts'],
    );
  }
}

class UsageLimit {
  final String label;
  final double percent;
  final String? resetsAt;

  /// False for non-Gemini Antigravity tiers (Claude/GPT): shown in the usage
  /// sheet but excluded from [AgentUsage.highestPercent].
  final bool isPrimary;

  UsageLimit({
    required this.label,
    required this.percent,
    this.resetsAt,
    this.isPrimary = true,
  });

  /// Labels of the secondary tiers sharing an Antigravity plan. Kept in sync
  /// with the bridge's `antigravity_is_secondary` for limits from old bridges
  /// that carry no `primary` flag.
  static bool isPrimaryLabel(String label) {
    final lower = label.toLowerCase();
    return !['claude', 'anthropic', 'gpt', 'openai', 'codex'].any(lower.contains);
  }

  factory UsageLimit.fromJson(Map<String, dynamic> json) {
    var p = (json['percent'] as num?)?.toDouble() ?? 0.0;
    if (p > 1.0) p = p / 100.0;
    final label = json['label'] ?? json['title'] ?? 'Quota';
    return UsageLimit(
      label: label,
      percent: p.clamp(0.0, 1.0),
      resetsAt: json['resets_at'] ?? json['resetsAt'],
      isPrimary: json['primary'] is bool ? json['primary'] as bool : isPrimaryLabel(label),
    );
  }
}

