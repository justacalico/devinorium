import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';

/// Stable identity for a settings topic, so callers locate a section by
/// name instead of list position (the list changes with ownership).
enum SettingsTopic {
  account,
  providers,
  personalization,
  git,
  directories,
  usage,
  manage,
  audit,
  about,
  servers,
}

/// Sidebar topic order; `git`, `manage` and `audit` are owner-only.
/// Kept separate from `settingsTopics` so callers and tests can resolve a
/// topic to its index without localizing labels.
List<SettingsTopic> settingsTopicOrder(bool isOwner) {
  return [
    SettingsTopic.account,
    SettingsTopic.providers,
    SettingsTopic.personalization,
    if (isOwner) SettingsTopic.git,
    SettingsTopic.directories,
    if (isOwner) SettingsTopic.manage,
    SettingsTopic.about,
    SettingsTopic.servers,
    SettingsTopic.usage,
    // New topics go last so existing topic positions do not shift.
    if (isOwner) SettingsTopic.audit,
  ];
}

/// The sidebar topic list, in display order. `git`, `manage` and `audit`
/// are owner-only.
List<({SettingsTopic topic, IconData icon, String label})> settingsTopics(
  bool isOwner,
  AppLocalizations l,
) {
  return [
    for (final topic in settingsTopicOrder(isOwner))
      switch (topic) {
        SettingsTopic.account => (
            topic: topic,
            icon: Icons.person_outline,
            label: l.account,
          ),
        SettingsTopic.providers => (
            topic: topic,
            icon: Icons.cloud_outlined,
            label: l.providers,
          ),
        SettingsTopic.personalization => (
            topic: topic,
            icon: Icons.palette_outlined,
            label: l.personalization,
          ),
        SettingsTopic.git => (
            topic: topic,
            icon: Icons.code_outlined,
            label: l.git,
          ),
        SettingsTopic.directories => (
            topic: topic,
            icon: Icons.folder_outlined,
            label: l.directories,
          ),
        SettingsTopic.manage => (
            topic: topic,
            icon: Icons.manage_accounts_outlined,
            label: l.manage,
          ),
        SettingsTopic.about => (
            topic: topic,
            icon: Icons.info_outlined,
            label: l.about,
          ),
        SettingsTopic.servers => (
            topic: topic,
            icon: Icons.dns_outlined,
            label: l.servers,
          ),
        SettingsTopic.usage => (
            topic: topic,
            icon: Icons.bar_chart_outlined,
            label: l.usage,
          ),
        SettingsTopic.audit => (
            topic: topic,
            icon: Icons.receipt_long_outlined,
            label: l.auditLog,
          ),
      },
  ];
}
