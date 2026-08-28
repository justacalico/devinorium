part of '../thread_page.dart';

class _Composer extends StatefulWidget {
  final TextEditingController controller;
  const _Composer({required this.controller});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _focusNode = FocusNode();
  final _keyFocusNode = FocusNode();
  bool _wasSending = false;

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final state = context.read<AppState>();
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.enter && !shift) {
      _submit(state);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab && shift) {
      _cycleComposerMode(state);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _handlePaste();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handlePaste() async {
    final state = context.read<AppState>();
    final l = l10n(context);
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

  void _insertText(String text) {
    final state = context.read<AppState>();
    final value = widget.controller.value;
    final selection = value.selection;
    late final String newText;
    late final TextSelection newSelection;

    if (selection.isValid && selection.isCollapsed) {
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
    state.setComposerText(newText);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _keyFocusNode.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    if (state.composerText.trim().isNotEmpty &&
        state.activeThreadId != null &&
        !state.sending) {
      widget.controller.clear();
      state.sendMessage();
    }
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
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final isSending = state.sending;
    final hasActiveThread = state.activeThreadId != null;
    final mode = state.composerMode;
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
                    if (state.attachments.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (var i = 0; i < state.attachments.length; i++)
                              Chip(
                                avatar: const Icon(Icons.attach_file, size: 14),
                                label: Text(state.attachments[i].filename),
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
                    Focus(
                      focusNode: _keyFocusNode,
                      onKeyEvent: _handleKeyEvent,
                      child: TextField(
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
                        onChanged: state.setComposerText,
                        contextMenuBuilder: (context, editableTextState) {
                          final items = editableTextState.contextMenuButtonItems
                              .map((item) {
                                if (item.type == ContextMenuButtonType.paste) {
                                  return ContextMenuButtonItem(
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
                                  final files = await dz.pick(multiple: true);
                                  if (files.isNotEmpty) {
                                    state.addAttachments(files);
                                  }
                                }
                              : null,
                        ),
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 0,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ModelPicker(
                                value: state.selectedModel,
                                models: state.models,
                                enabled: hasActiveThread && !isSending,
                                onChanged: (model) {
                                  state.setSelectedModel(model);
                                  state.saveThreadSettings();
                                },
                              ),
                              _PermissionDropdown(
                                value: state.selectedPermission,
                                enabled: hasActiveThread && !isSending,
                                onChanged: (mode) {
                                  state.setSelectedPermission(mode);
                                  state.saveThreadSettings();
                                },
                              ),
                              _ModeDropdown(
                                value: state.composerMode,
                                enabled: hasActiveThread && !isSending,
                                onChanged: state.setComposerMode,
                              ),
                            ],
                          ),
                        ),
                        IconButton.filled(
                          style: isSending
                              ? IconButton.styleFrom(
                                  backgroundColor: theme.colorScheme.error,
                                  foregroundColor: theme.colorScheme.onError,
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
                                  } else if (state.composerText
                                      .trim()
                                      .isNotEmpty) {
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
  }
}
