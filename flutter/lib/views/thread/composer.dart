part of '../thread_page.dart';

typedef _ComposerModel = ({
  String? activeThreadId,
  bool sending,
  ComposerMode composerMode,
  List<({String filename, String mime, Uint8List bytes})> attachments,
  String selectedModel,
  String selectedPermission,
  List<ModelInfo> models,
});

/// The available width for the composer dropdowns below which they switch to
/// compact labels and a horizontally scrolling row.
const _compactDropdownsBreakpoint = 360.0;

class _Composer extends StatefulWidget {
  final TextEditingController controller;
  const _Composer({required this.controller});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _focusNode = FocusNode();
  bool _wasSending = false;
  ComposerMode? _preAskMode;
  bool _promptDrivenAsk = false;
  String? _lastThreadId;

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
    _focusNode.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    if (_effectivePrompt(state).isNotEmpty &&
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    if (_wasSending && !state.sending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    _wasSending = state.sending;

    final threadId = state.activeThreadId;
    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _preAskMode = null;
      _promptDrivenAsk = false;
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

  static Color _modeColor(ComposerMode mode) => switch (mode) {
    ComposerMode.code => Colors.transparent,
    ComposerMode.plan => const Color(0xFFFFC107),
    ComposerMode.ask => const Color(0xFF4CAF50),
  };

  static Color? _badgeBackground(ComposerMode mode) => switch (mode) {
    ComposerMode.code => null,
    ComposerMode.plan => const Color(0xFFFFECB3),
    ComposerMode.ask => const Color(0xFFC8E6C9),
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
        selectedModel: s.selectedModel,
        selectedPermission: s.selectedPermission,
        models: s.models,
      ),
      builder: (context, model, _) {
        final isSending = model.sending;
        final hasActiveThread = model.activeThreadId != null;
        final mode = model.composerMode;
        final modeColor = _modeColor(mode);
        final showBadge = mode != ComposerMode.code;

        final borderSide = mode == ComposerMode.code
            ? BorderSide.none
            : BorderSide(color: modeColor, width: 2);

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Material(
                  color: theme.colorScheme.surfaceContainer,
                  elevation: 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                    side: borderSide,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                                    label: Text(model.attachments[i].filename),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 0,
                                    ),
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor:
                                        theme.colorScheme.surfaceContainerHigh,
                                    onDeleted: () => state.removeAttachment(i),
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
                            _cycleModeShortcut: () => _cycleComposerMode(state),
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
                                    ModelPicker(
                                      value: model.selectedModel,
                                      models: model.models,
                                      compact: compact,
                                      enabled: hasActiveThread && !isSending,
                                      onChanged: (selected) {
                                        state.setSelectedModel(selected);
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
                                          dropdowns[0],
                                          const SizedBox(width: 8),
                                          dropdowns[1],
                                          const SizedBox(width: 8),
                                          dropdowns[2],
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
                                      backgroundColor: theme.colorScheme.error,
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
                                      ).isNotEmpty) {
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
                        color: _badgeBackground(mode),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: modeColor),
                      ),
                      child: Text(
                        mode.label,
                        style: const TextStyle(
                          color: Colors.black87,
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
