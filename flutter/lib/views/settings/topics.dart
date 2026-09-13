import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Stable identity for a settings topic, so callers locate a section by
/// name instead of list position (the list changes with ownership).
enum SettingsTopic {
  account,
  providers,
  personalization,
  git,
  cloneRoot,
  worktreeRoot,
  usage,
  manage,
  audit,
  about,
  servers,
}

/// The sidebar topic list, in display order. `manage` and `audit` are
/// owner-only.
List<({SettingsTopic topic, IconData icon, String label})> settingsTopics(
  bool isOwner,
  AppLocalizations l,
) {
  return [
    (
      topic: SettingsTopic.account,
      icon: Icons.person_outline,
      label: l.account,
    ),
    (
      topic: SettingsTopic.providers,
      icon: Icons.cloud_outlined,
      label: l.providers,
    ),
    (
      topic: SettingsTopic.personalization,
      icon: Icons.palette_outlined,
      label: l.personalization,
    ),
    (topic: SettingsTopic.git, icon: Icons.code_outlined, label: l.git),
    (
      topic: SettingsTopic.cloneRoot,
      icon: Icons.folder_outlined,
      label: l.cloneRoot,
    ),
    if (isOwner)
      (
        topic: SettingsTopic.manage,
        icon: Icons.manage_accounts_outlined,
        label: l.manage,
      ),
    (topic: SettingsTopic.about, icon: Icons.info_outlined, label: l.about),
    (topic: SettingsTopic.servers, icon: Icons.dns_outlined, label: l.servers),
    (
      topic: SettingsTopic.usage,
      icon: Icons.bar_chart_outlined,
      label: l.usage,
    ),
    // New topics go last so existing topic positions do not shift.
    if (isOwner)
      (
        topic: SettingsTopic.audit,
        icon: Icons.receipt_long_outlined,
        label: l.auditLog,
      ),
    (
      topic: SettingsTopic.worktreeRoot,
      icon: Icons.account_tree_outlined,
      label: l.worktreeRoot,
    ),
  ];
}
