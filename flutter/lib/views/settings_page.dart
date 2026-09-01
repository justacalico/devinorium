import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/git_provider_icons.dart';
import '../widgets/git_provider_tile.dart';
import '../widgets/owner_badge.dart';
import 'create_user_dialog.dart';
import 'folder_picker_dialog.dart';
import 'window_title_drag.dart';

part 'settings/account_section.dart';
part 'settings/provider_card.dart';
part 'settings/personalization_section.dart';
part 'settings/accounts_section.dart';
part 'settings/git_section.dart';
part 'settings/clone_root_section.dart';
part 'settings/servers_section.dart';
part 'settings/section_card.dart';
part 'settings/settings_row.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadSettingsData();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;

    final sections = [
      _AccountSection(state: state),
      _ProviderCard(state: state),
      _PersonalizationSection(state: state),
      _GitSection(state: state),
      _CloneRootSection(state: state),
      if (state.isOwner) _AccountsSection(state: state),
      const _ServersSection(),
    ];
    final index = state.settingsTopicIndex.clamp(0, sections.length - 1);

    return Scaffold(
      appBar: AppBar(
        leading: isNarrow
            ? IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              )
            : null,
        title: WindowTitleDrag(
          child: Text(
            l10n(context).settings,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        centerTitle: false,
        backgroundColor: theme.colorScheme.surface,
        scrolledUnderElevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: sections[index],
      ),
    );
  }
}
