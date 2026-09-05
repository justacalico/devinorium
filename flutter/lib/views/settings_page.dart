import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/models.dart';
import '../servers/server_profile.dart';
import '../state/app_state.dart';
import '../theme/theme.dart';
import '../utils/link_opener.dart';
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
part 'settings/about_section.dart';
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
    final theme = Theme.of(context);
    final isNarrow = MediaQuery.of(context).size.width < 768;
    final state = context.read<AppState>();

    return Selector<AppState, ({bool isOwner, int settingsTopicIndex})>(
      selector: (_, s) => (
        isOwner: s.isOwner,
        settingsTopicIndex: s.settingsTopicIndex,
      ),
      builder: (context, model, _) {
        final sections = [
          _AccountSection(state: state),
          _ProviderCard(state: state),
          _PersonalizationSection(state: state),
          _GitSection(state: state),
          _CloneRootSection(state: state),
          if (model.isOwner) _AccountsSection(state: state),
          _AboutSection(state: state),
          const _ServersSection(),
        ];
        final index = model.settingsTopicIndex.clamp(0, sections.length - 1);

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
  });
  }
}
