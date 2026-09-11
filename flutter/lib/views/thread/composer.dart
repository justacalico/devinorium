part of '../thread_page.dart';

typedef _ComposerModel = ({
  String? activeThreadId,
  bool sending,
  ComposerMode composerMode,
  List<({String filename, String mime, Uint8List bytes})> attachments,
  List<PathRef> pathRefs,
  List<ThreadReference> threadReferences,
  String selectedModel,
  String selectedReasoning,
  String selectedPermission,
  String selectedProvider,
  bool providerLocked,
  List<ModelInfo> models,
  List<ProviderInfo> providers,
});

/// The available width for the composer dropdowns below which they switch to
/// compact labels and a horizontally scrolling row.
const _compactDropdownsBreakpoint = 360.0;

const _outerRadius = 28.0;
const _outlineWidth = 2.0;
const _innerRadius = _outerRadius - _outlineWidth;

class _PromptOutline extends StatelessWidget {
  final ComposerMode mode;
  final bool isBypass;
  final bool showOutline;
  final Color modeColor;
  final Widget child;

  const _PromptOutline({
    required this.mode,
    required this.isBypass,
    required this.showOutline,
    required this.modeColor,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!showOutline) return child;

    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    final shadow = theme.colorScheme.shadow;

    return Container(
      key: const Key('composer_outline'),
      clipBehavior: Clip.antiAlias,
      decoration: _decoration(error, shadow),
      child: Padding(
        padding: const EdgeInsets.all(_outlineWidth),
        child: child,
      ),
    );
  }

  BoxDecoration _decoration(Color error, Color shadow) {
    final borderRadius = BorderRadius.circular(_outerRadius);
    final boxShadow = [
      BoxShadow(
        color: shadow.withValues(alpha: 0.12),
        blurRadius: 2,
        offset: const Offset(0, 1),
      ),
    ];
    if (mode == ComposerMode.code) {
      return BoxDecoration(
        color: error,
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      );
    }
    if (isBypass) {
      return BoxDecoration(
        gradient: LinearGradient(
          colors: [modeColor, error],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: borderRadius,
        boxShadow: boxShadow,
      );
    }
    return BoxDecoration(
      color: modeColor,
      borderRadius: borderRadius,
      boxShadow: boxShadow,
    );
  }
}

class _Composer extends StatefulWidget {
  final TextEditingController controller;
  const _Composer({required this.controller});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _focusNode = FocusNode();
  ComposerMode? _preAskMode;
  bool _promptDrivenAsk = false;
  String? _lastThreadId;
  AppState? _appState;
  bool _wasSending = false;

  static const _pasteShortcut = SingleActivator(
    LogicalKeyboardKey.keyV,
    control: true,
  );
  static const _macPasteShortcut = SingleActivator(
    LogicalKeyboardKey.keyV,
    meta: true,
  );
  static const _sendShortcut = SingleActivator(LogicalKeyboardKey.enter);
  static const _cycleModeShortcut = SingleActivator(
    LogicalKeyboardKey.tab,
    shift: true,
  );

  Future<void> _handlePaste() async {
    final state = context.read<AppState>();
    final l = l10n(context);

    final imageBytes = await getClipboardImage();
    if (!mounted) return;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      final result = await readAttachment(
        InMemoryAttachmentSource('pasted-image', imageBytes),
      );
      if (!mounted) return;
      switch (result) {
        case AttachmentSuccess():
          final attachment = result.attachment;
          state.addAttachments([
            (
              filename: _pastedImageName(attachment.mime),
              mime: attachment.mime,
              bytes: attachment.bytes,
            ),
          ]);
        case AttachmentTooLarge():
          state.setGlobalError(l.dropZoneFileTooLarge(result.filename));
        case AttachmentReadError():
          state.setGlobalError(l.dropZoneReadFileFailed('${result.error}'));
      }
      return;
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text;
    if (text == null || text.isEmpty) return;

    final result = await maybeAttachPath(text);
    if (!mounted) return;
    switch (result) {
      case PathAttached():
        state.addAttachments([
          (filename: result.filename, mime: result.mime, bytes: result.bytes),
        ]);
      case PathTooLarge():
        state.setGlobalError(l.dropZoneFileTooLarge(result.filename));
      case PathFallback():
        _insertText(text);
    }
  }

  static String _pastedImageName(String mime) {
    final ext = switch (mime) {
      'image/png' => 'png',
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      'image/svg+xml' => 'svg',
      _ => 'bin',
    };
    return 'pasted-image.$ext';
  }

  void _insertText(String text) {
    final state = context.read<AppState>();
    final value = widget.controller.value;
    final selection = value.selection;
    late final String newText;
    late final TextSelection newSelection;

    if (selection.isValid) {
      newText = value.text.replaceRange(selection.start, selection.end, text);
      newSelection = TextSelection.collapsed(
        offset: selection.start + text.length,
      );
    } else {
      newText = value.text + text;
      newSelection = TextSelection.collapsed(offset: newText.length);
    }

    widget.controller.value = value.copyWith(
      text: newText,
      selection: newSelection,
    );
    _updateComposerFromText(newText, state);
  }

  void _onTextChanged(String text) {
    final state = context.read<AppState>();
    _updateComposerFromText(text, state);
  }

  void _updateComposerFromText(String text, AppState state) {
    _applySlashCommandMode(text, state);
    state.setComposerText(text);
  }

  void _applySlashCommandMode(String text, AppState state) {
    final has = hasAskPrefix(text);
    if (has && state.composerMode != ComposerMode.ask) {
      _preAskMode = state.composerMode;
      _promptDrivenAsk = true;
      state.setComposerMode(ComposerMode.ask, persist: false);
    } else if (!has &&
        _promptDrivenAsk &&
        state.composerMode == ComposerMode.ask &&
        _preAskMode != null) {
      _promptDrivenAsk = false;
      state.setComposerMode(_preAskMode!, persist: false);
    }

    if (state.composerMode != ComposerMode.ask) {
      _preAskMode = state.composerMode;
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isMobile {
    return switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => false,
      _ => true,
    };
  }

  void _submit(AppState state) {
    if ((_effectivePrompt(state).isNotEmpty ||
            state.pathRefs.isNotEmpty ||
            state.threadReferences.isNotEmpty) &&
        state.activeThreadId != null &&
        !state.sending) {
      widget.controller.clear();
      state.sendMessage();
    }
  }

  String _effectivePrompt(AppState state) {
    var prompt = state.composerText.trim();
    if (state.composerMode == ComposerMode.ask) {
      prompt = stripAskPrefix(prompt);
    }
    return prompt;
  }

  void _cycleComposerMode(AppState state) {
    state.setComposerMode(state.composerMode.next);
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final state = _appState!;
    if (_wasSending && !state.sending && !_isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    _wasSending = state.sending;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    if (_appState == null) {
      _appState = state;
      _wasSending = state.sending;
      state.addListener(_onAppStateChanged);
    }

    final threadId = state.activeThreadId;
    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _preAskMode = null;
      _promptDrivenAsk = false;
      _wasSending = state.sending;
      _applySlashCommandMode(state.composerText, state);
      if (state.composerMode == ComposerMode.ask &&
          hasAskPrefix(state.composerText)) {
        _promptDrivenAsk = true;
        _preAskMode = state.defaultComposerMode;
      }
    }

    if (state.composerMode == ComposerMode.ask &&
        !hasAskPrefix(state.composerText)) {
      _promptDrivenAsk = false;
      _preAskMode = null;
    }
  }

  static Color _modeColor(ComposerMode mode, SemanticColors semantic) =>
      switch (mode) {
        ComposerMode.code => Colors.transparent,
        ComposerMode.plan => semantic.warning,
        ComposerMode.ask => semantic.success,
      };

  static Color? _badgeBackground(ComposerMode mode, SemanticColors semantic) =>
      switch (mode) {
        ComposerMode.code => null,
        ComposerMode.plan => semantic.warningContainer,
        ComposerMode.ask => semantic.successContainer,
      };

  static Color? _badgeForeground(ComposerMode mode, SemanticColors semantic) =>
      switch (mode) {
        ComposerMode.code => null,
        ComposerMode.plan => semantic.onWarningContainer,
        ComposerMode.ask => semantic.onSuccessContainer,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();

    return Selector<AppState, _ComposerModel>(
      selector: (_, s) => (
        activeThreadId: s.activeThreadId,
        sending: s.sending,
        composerMode: s.composerMode,
        attachments: s.attachments,
        pathRefs: s.pathRefs,
        threadReferences: s.threadReferences,
        selectedModel: s.selectedModel,
        selectedReasoning: s.selectedReasoning,
        selectedPermission: s.selectedPermission,
        selectedProvider: s.selectedProvider,
        providerLocked: s.activeThreadDetail?.thread.devinSessionId != null,
        models: s.models,
        providers: s.providers,
      ),
      builder: (context, model, _) {
        final isSending = model.sending;
        final hasActiveThread = model.activeThreadId != null;
        final mode = model.composerMode;
        final semantic = SemanticColors.of(context);
        final modeColor = _modeColor(mode, semantic);
        final showBadge = mode != ComposerMode.code;

        final isBypass = model.selectedPermission == 'bypass';
        final showOutline = mode != ComposerMode.code || isBypass;
        final cardRadius = showOutline ? _innerRadius : _outerRadius;
        final cardElevation = showOutline ? 0.0 : 1.0;

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _PromptOutline(
                  mode: mode,
                  isBypass: isBypass,
                  showOutline: showOutline,
                  modeColor: modeColor,
                  child: Material(
                    color: theme.colorScheme.surfaceContainer,
                    elevation: cardElevation,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(cardRadius),
                      side: BorderSide.none,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (model.threadReferences.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (
                                    var i = 0;
                                    i < model.threadReferences.length;
                                    i++
                                  )
                                    Chip(
                                      key: Key(
                                        'thread_ref_${model.threadReferences[i].id}',
                                      ),
                                      avatar: const Icon(
                                        Icons.chat_bubble_outline,
                                        size: 14,
                                      ),
                                      label: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 280,
                                        ),
                                        child: Text(
                                          model.threadReferences[i].title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 0,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: theme
                                          .colorScheme
                                          .surfaceContainerHigh,
                                      onDeleted: () =>
                                          state.removeThreadReference(i),
                                    ),
                                ],
                              ),
                            ),
                          if (model.pathRefs.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (
                                    var i = 0;
                                    i < model.pathRefs.length;
                                    i++
                                  )
                                    Chip(
                                      avatar: Icon(
                                        model.pathRefs[i].isDir
                                            ? Icons.folder_outlined
                                            : Icons.insert_drive_file_outlined,
                                        size: 14,
                                      ),
                                      label: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 280,
                                        ),
                                        child: Text(
                                          model.pathRefs[i].path,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 0,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: theme
                                          .colorScheme
                                          .surfaceContainerHigh,
                                      onDeleted: () => state.removePathRef(i),
                                    ),
                                ],
                              ),
                            ),
                          if (model.attachments.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (
                                    var i = 0;
                                    i < model.attachments.length;
                                    i++
                                  )
                                    Chip(
                                      avatar: const Icon(
                                        Icons.attach_file,
                                        size: 14,
                                      ),
                                      label: Text(
                                        model.attachments[i].filename,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 0,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: theme
                                          .colorScheme
                                          .surfaceContainerHigh,
                                      onDeleted: () =>
                                          state.removeAttachment(i),
                                    ),
                                ],
                              ),
                            ),
                          CallbackShortcuts(
                            bindings: {
                              _pasteShortcut: () {
                                _handlePaste();
                              },
                              _macPasteShortcut: () {
                                _handlePaste();
                              },
                              _sendShortcut: () => _submit(state),
                              _cycleModeShortcut: () =>
                                  _cycleComposerMode(state),
                            },
                            child: TextField(
                              key: const Key('composer_input'),
                              controller: widget.controller,
                              focusNode: _focusNode,
                              minLines: 1,
                              maxLines: 6,
                              enabled: hasActiveThread && !isSending,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                isCollapsed: true,
                                hintText: l10n(context).composerHint,
                              ),
                              style: theme.textTheme.bodyLarge,
                              onChanged: _onTextChanged,
                              contextMenuBuilder: (context, editableTextState) {
                                final items = editableTextState
                                    .contextMenuButtonItems
                                    .map((item) {
                                      if (item.type ==
                                          ContextMenuButtonType.paste) {
                                        return ContextMenuButtonItem(
                                          type: item.type,
                                          label: item.label,
                                          onPressed: _handlePaste,
                                        );
                                      }
                                      return item;
                                    })
                                    .toList();
                                return AdaptiveTextSelectionToolbar.buttonItems(
                                  buttonItems: items,
                                  anchors: editableTextState.contextMenuAnchors,
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.attach_file, size: 20),
                                onPressed: hasActiveThread && !isSending
                                    ? () async {
                                        final dz = DropZone.of(context);
                                        if (dz == null) return;
                                        final files = await dz.pick(
                                          multiple: true,
                                        );
                                        if (files.isNotEmpty) {
                                          state.addAttachments(files);
                                        }
                                      }
                                    : null,
                              ),
                              Expanded(
                                child: LayoutBuilder(
                                  key: const Key('composer_dropdowns'),
                                  builder: (context, constraints) {
                                    final compact =
                                        constraints.maxWidth <
                                        _compactDropdownsBreakpoint;
                                    final dropdowns = [
                                      _ModelSelector(
                                        compact: compact,
                                        // Once a provider session exists it
                                        // cannot be resumed by another
                                        // provider, so the picker locks.
                                        providerLocked: model.providerLocked,
                                        enabled: hasActiveThread && !isSending,
                                      ),
                                      _ReasoningDropdown(
                                        models: model.models,
                                        selectedModel: model.selectedModel,
                                        value: model.selectedReasoning,
                                        compact: compact,
                                        enabled: hasActiveThread && !isSending,
                                        onChanged: (effort) {
                                          state.setSelectedReasoning(effort);
                                          state.saveThreadSettings();
                                        },
                                      ),
                                      _PermissionDropdown(
                                        value: model.selectedPermission,
                                        compact: compact,
                                        enabled: hasActiveThread && !isSending,
                                        onChanged: (mode) {
                                          state.setSelectedPermission(mode);
                                          state.saveThreadSettings();
                                        },
                                      ),
                                      _ModeDropdown(
                                        value: model.composerMode,
                                        compact: compact,
                                        enabled: hasActiveThread && !isSending,
                                        onChanged: state.setComposerMode,
                                      ),
                                    ];

                                    if (compact) {
                                      return SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            for (
                                              var i = 0;
                                              i < dropdowns.length;
                                              i++
                                            ) ...[
                                              if (i > 0)
                                                const SizedBox(width: 8),
                                              dropdowns[i],
                                            ],
                                          ],
                                        ),
                                      );
                                    }

                                    return Wrap(
                                      spacing: 8,
                                      runSpacing: 0,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: dropdowns,
                                    );
                                  },
                                ),
                              ),
                              IconButton.filled(
                                style: isSending
                                    ? IconButton.styleFrom(
                                        backgroundColor:
                                            theme.colorScheme.error,
                                        foregroundColor:
                                            theme.colorScheme.onError,
                                      )
                                    : null,
                                tooltip: isSending
                                    ? l10n(context).stopGenerating
                                    : l10n(context).send,
                                icon: isSending
                                    ? const Icon(Icons.stop, size: 18)
                                    : const Icon(Icons.send, size: 18),
                                onPressed: hasActiveThread
                                    ? () {
                                        if (isSending) {
                                          state.stopThread();
                                        } else if (_effectivePrompt(
                                              state,
                                            ).isNotEmpty ||
                                            model.pathRefs.isNotEmpty ||
                                            model
                                                .threadReferences.isNotEmpty) {
                                          widget.controller.clear();
                                          state.sendMessage();
                                        }
                                      }
                                    : null,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (showBadge)
                  Positioned(
                    top: -10,
                    left: 20,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _badgeBackground(mode, semantic),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: modeColor),
                      ),
                      child: Text(
                        mode.label(l10n(context)),
                        style: TextStyle(
                          color: _badgeForeground(mode, semantic),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Drop target around the composer for threads dragged out of the sidebar.
/// Dropping a thread adds it as a reference chip; its recent history is sent
/// along as context for the next message.
class _ThreadRefDropTarget extends StatelessWidget {
  final Widget child;

  const _ThreadRefDropTarget({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    return DragTarget<Thread>(
      onWillAcceptWithDetails: (details) =>
          state.activeThreadId != null &&
          !state.sending &&
          details.data.id != state.activeThreadId,
      onAcceptWithDetails: (details) {
        final thread = details.data;
        state.addThreadReference(
          ThreadReference(id: thread.id, title: thread.title),
        );
      },
      builder: (context, candidateData, rejectedData) {
        return Stack(
          children: [
            child,
            if (candidateData.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_outerRadius),
                      border: Border.all(
                        color: theme.colorScheme.primary,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Drop target around the composer for nodes dragged out of the files panel.
/// Dropping a file or folder adds it as a prompt reference (a path the agent
/// reads on the backend machine); nothing is uploaded.
class _PathRefDropTarget extends StatelessWidget {
  final Widget child;

  const _PathRefDropTarget({required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<AppState>();
    return DragTarget<FileTreeNode>(
      onWillAcceptWithDetails: (_) =>
          state.activeThreadId != null && !state.sending,
      onAcceptWithDetails: (details) {
        final node = details.data;
        state.addPathRef(node.fullPathString, isDir: node.entry.isDir);
      },
      builder: (context, candidateData, rejectedData) {
        return Stack(
          children: [
            child,
            if (candidateData.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_outerRadius),
                      border: Border.all(
                        color: theme.colorScheme.primary,
                        width: 2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
