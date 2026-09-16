part of '../thread_page.dart';

typedef _ComposerModel = ({
  String? activeThreadId,
  bool sending,
  bool hasStore,
  ComposerMode composerMode,
  List<({String filename, String mime, Uint8List bytes})> attachments,
  List<PathRef> pathRefs,
  List<ThreadReference> threadReferences,
  List<MachineReference> machineReferences,
  List<Machine> machines,
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

  // `@` machine picker: the text after the active `@` token, or null when
  // the picker is closed.
  String? _machineQuery;
  int _machineHighlight = 0;
  // The `@` token the user dismissed with Escape, tracked by position and
  // content: extending the same token keeps the picker closed, but a new or
  // retyped token opens it again.
  int? _machineDismissedAt;
  String _machineDismissedQuery = '';

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
      if (!state.hasActiveThreadStore) return;
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

    final result = state.hasActiveThreadStore
        ? await maybeAttachPath(text)
        : const PathFallback();
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
    // Write the text before touching the mode: setComposerMode notifies
    // listeners, and the state->controller sync must already see the fresh
    // text or it would push the stale draft back into the field.
    state.setComposerText(text);
    _applySlashCommandMode(text, state);
    _updateMachinePicker(text, state);
  }

  /// Index of the `@` starting the token the caret sits in, or null. The
  /// trigger must start a word (beginning of text or after whitespace) and
  /// whitespace ends the query, so `@x and more` is plain text, not a search.
  static int? _machineTriggerAt(String text, int caret) {
    if (caret <= 0 || caret > text.length) return null;
    final at = text.lastIndexOf('@', caret - 1);
    if (at < 0) return null;
    if (at > 0) {
      final prev = text.codeUnitAt(at - 1);
      // space, tab, newline
      if (prev != 0x20 && prev != 0x09 && prev != 0x0A) return null;
    }
    if (text.substring(at + 1, caret).contains(RegExp(r'\s'))) return null;
    return at;
  }

  void _updateMachinePicker(String text, AppState state) {
    final sel = widget.controller.selection;
    final caret = sel.isValid ? sel.baseOffset : text.length;
    final at = _machineTriggerAt(text, caret);
    String? next;
    if (at != null) {
      final query = text.substring(at + 1, caret);
      final dismissed =
          at == _machineDismissedAt && query.startsWith(_machineDismissedQuery);
      if (!dismissed) next = query;
    }
    if (next == _machineQuery) return;
    final opened = next != null && _machineQuery == null;
    setState(() {
      _machineQuery = next;
      _machineHighlight = 0;
      if (next != null) {
        _machineDismissedAt = null;
        _machineDismissedQuery = '';
      }
    });
    // One load per open; a per-keystroke refresh would spam a server that
    // does not have the endpoint.
    if (opened && state.machines.isEmpty) {
      unawaited(state.loadMachines());
    }
  }

  List<Machine> _filteredMachines(AppState state) {
    final referenced = {for (final r in state.machineReferences) r.id};
    final q = (_machineQuery ?? '').toLowerCase();
    return [
      for (final m in state.machines)
        if (!referenced.contains(m.id) &&
            (q.isEmpty ||
                m.name.toLowerCase().contains(q) ||
                m.host.toLowerCase().contains(q)))
          m,
    ];
  }

  void _acceptMachine(Machine machine) {
    final state = context.read<AppState>();
    if (state.machineReferences.length >= maxMachineReferences) {
      // At the cap the pick silently no-ops in the store; keep the typed
      // token instead of deleting text for a chip that never appears.
      _dismissMachinePicker();
      return;
    }
    final value = widget.controller.value;
    final caret = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final at = _machineTriggerAt(value.text, caret);
    if (at == null) {
      // The caret left the `@` token (mouse click, arrow keys); close the
      // picker without touching the text or the reference list.
      setState(() => _machineQuery = null);
      return;
    }
    // Replace the `@query` token with nothing: the picked machine shows
    // up as a chip instead of text, like a Discord mention.
    final newText = value.text.replaceRange(at, caret, '');
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: at),
    );
    _updateComposerFromText(newText, state);
    state.addMachineReference(
      MachineReference(id: machine.id, name: machine.name),
    );
    setState(() {
      _machineQuery = null;
      _machineDismissedAt = null;
      _machineDismissedQuery = '';
    });
    _focusNode.requestFocus();
  }

  void _acceptHighlightedMachine(AppState state) {
    final machines = _filteredMachines(state);
    if (machines.isEmpty) {
      // Enter on an empty result list dismisses the token outright; closing
      // without recording the dismissal would reopen on the next keystroke.
      _dismissMachinePicker();
      return;
    }
    _acceptMachine(machines[_machineHighlight.clamp(0, machines.length - 1)]);
  }

  void _moveMachineHighlight(int delta, AppState state) {
    final count = _filteredMachines(state).length;
    if (count == 0) return;
    setState(() {
      _machineHighlight = (_machineHighlight + delta) % count;
      if (_machineHighlight < 0) _machineHighlight += count;
    });
  }

  void _dismissMachinePicker() {
    final value = widget.controller.value;
    final caret = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final at = _machineTriggerAt(value.text, caret);
    setState(() {
      _machineDismissedAt = at;
      _machineDismissedQuery = at != null
          ? value.text.substring(at + 1, caret)
          : '';
      _machineQuery = null;
    });
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
    widget.controller.removeListener(_onControllerChanged);
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
            state.threadReferences.isNotEmpty ||
            state.machineReferences.isNotEmpty) &&
        state.hasActiveThreadStore &&
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
    if (!state.hasActiveThreadStore) return;
    state.setComposerMode(state.composerMode.next);
  }

  /// Keep the shared text controller in step with the active thread's draft.
  /// Typing already wrote through to state so this is a no-op then; it only
  /// applies text when the draft changed underneath the input — a thread
  /// switch, a draft restored from disk, or a prompt restored after a failed
  /// send.
  void _syncControllerText(AppState state) {
    final text = state.composerText;
    if (widget.controller.text == text) return;
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Re-evaluate the slash-command bookkeeping when the active thread or its
  /// draft changes underneath us. Text edits go through
  /// [_updateComposerFromText] instead; re-deriving the ask bookkeeping on
  /// every notify would read a half-applied mode/text pair.
  void _syncComposerContext(AppState state) {
    final threadId = state.activeThreadId;
    if (threadId != _lastThreadId) {
      _lastThreadId = threadId;
      _preAskMode = null;
      _promptDrivenAsk = false;
      _wasSending = state.sending;
      // The `@` picker belongs to the old thread's text; never carry it
      // across a switch or keys keep getting hijacked.
      _machineQuery = null;
      _machineDismissedAt = null;
      _machineDismissedQuery = '';
      _applySlashCommandMode(state.composerText, state);
      if (state.composerMode == ComposerMode.ask &&
          hasAskPrefix(state.composerText)) {
        _promptDrivenAsk = true;
        _preAskMode = state.defaultComposerMode;
      }
    }
  }

  /// Selection-only changes never fire `onChanged`, so the picker is
  /// recomputed here too: clicking out of an `@` token closes it and moving
  /// the caret into one opens it.
  void _onControllerChanged() {
    final state = _appState;
    if (state == null) return;
    _updateMachinePicker(widget.controller.text, state);
  }

  void _onAppStateChanged() {
    if (!mounted) return;
    final state = _appState!;
    _syncComposerContext(state);
    _syncControllerText(state);
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
      widget.controller.addListener(_onControllerChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _appState != null) _syncControllerText(_appState!);
      });
    }
    _syncComposerContext(state);
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
        hasStore: s.hasActiveThreadStore,
        composerMode: s.composerMode,
        attachments: s.attachments,
        pathRefs: s.pathRefs,
        threadReferences: s.threadReferences,
        machineReferences: s.machineReferences,
        machines: s.machines,
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
        final hasStore = model.hasStore;
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
                          if (_machineQuery != null)
                            _MachinePicker(
                              key: const Key('machine_picker'),
                              machines: _filteredMachines(state),
                              highlight: _machineHighlight,
                              noneConfigured: model.machines.isEmpty,
                              onPick: _acceptMachine,
                            ),
                          if (model.machineReferences.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (
                                    var i = 0;
                                    i < model.machineReferences.length;
                                    i++
                                  )
                                    Chip(
                                      key: Key(
                                        'machine_ref_${model.machineReferences[i].id}',
                                      ),
                                      avatar: const Icon(
                                        Icons.computer,
                                        size: 14,
                                      ),
                                      label: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 280,
                                        ),
                                        child: Text(
                                          model.machineReferences[i].name,
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
                                          state.removeMachineReference(i),
                                    ),
                                ],
                              ),
                            ),
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
                                    if (isImageMime(
                                          model.attachments[i].mime,
                                        ) &&
                                        model.attachments[i].bytes.isNotEmpty)
                                      AttachmentThumb(
                                        key: Key('composer_attachment_$i'),
                                        bytes: model.attachments[i].bytes,
                                        filename: model.attachments[i].filename,
                                        onDelete: () =>
                                            state.removeAttachment(i),
                                        onTap: () => showAttachmentPreview(
                                          context,
                                          bytes: model.attachments[i].bytes,
                                          filename:
                                              model.attachments[i].filename,
                                        ),
                                      )
                                    else
                                      Chip(
                                        avatar: const Icon(
                                          Icons.attach_file,
                                          size: 14,
                                        ),
                                        label: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            maxWidth: 280,
                                          ),
                                          child: Text(
                                            model.attachments[i].filename,
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
                              _sendShortcut: () {
                                if (_machineQuery != null) {
                                  _acceptHighlightedMachine(state);
                                } else {
                                  _submit(state);
                                }
                              },
                              _cycleModeShortcut: () =>
                                  _cycleComposerMode(state),
                              // The `@` picker owns navigation and dismiss
                              // keys while it is open; otherwise the field
                              // keeps its normal caret behavior.
                              if (_machineQuery != null) ...{
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowDown,
                                ): () =>
                                    _moveMachineHighlight(1, state),
                                const SingleActivator(
                                  LogicalKeyboardKey.arrowUp,
                                ): () =>
                                    _moveMachineHighlight(-1, state),
                                const SingleActivator(
                                  LogicalKeyboardKey.tab,
                                ): () =>
                                    _acceptHighlightedMachine(state),
                                const SingleActivator(
                                  LogicalKeyboardKey.escape,
                                ): _dismissMachinePicker,
                              },
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
                                onPressed: hasStore && !isSending
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
                                        enabled: hasStore && !isSending,
                                      ),
                                      _ReasoningDropdown(
                                        models: model.models,
                                        selectedModel: model.selectedModel,
                                        value: model.selectedReasoning,
                                        compact: compact,
                                        enabled: hasStore && !isSending,
                                        onChanged: (effort) {
                                          state.setSelectedReasoning(effort);
                                          state.saveThreadSettings();
                                        },
                                      ),
                                      _PermissionDropdown(
                                        value: model.selectedPermission,
                                        compact: compact,
                                        enabled: hasStore && !isSending,
                                        onChanged: (mode) {
                                          state.setSelectedPermission(mode);
                                          state.saveThreadSettings();
                                        },
                                      ),
                                      _ModeDropdown(
                                        value: model.composerMode,
                                        compact: compact,
                                        enabled: hasStore && !isSending,
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
                                onPressed: hasStore
                                    ? () {
                                        if (isSending) {
                                          state.stopThread();
                                        } else if (_effectivePrompt(
                                              state,
                                            ).isNotEmpty ||
                                            model.pathRefs.isNotEmpty ||
                                            model.threadReferences.isNotEmpty ||
                                            model
                                                .machineReferences
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

/// Mention-style picker shown while the caret sits in an `@` token. Rows
/// list each machine's name and `host:port`; picking one removes the token
/// and adds a machine reference chip.
class _MachinePicker extends StatelessWidget {
  final List<Machine> machines;
  final int highlight;
  final bool noneConfigured;
  final ValueChanged<Machine> onPick;

  const _MachinePicker({
    super.key,
    required this.machines,
    required this.highlight,
    required this.noneConfigured,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = l10n(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 232),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.computer,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    l.machinePickerHint,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (machines.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Text(
                  noneConfigured ? l.machinesEmpty : l.machinePickerEmpty,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: machines.length,
                  itemExtent: 40,
                  itemBuilder: (context, i) {
                    final m = machines[i];
                    final active = i == highlight;
                    return InkWell(
                      key: Key('machine_option_${m.id}'),
                      onTap: () => onPick(m),
                      child: Container(
                        color: active
                            ? theme.colorScheme.primaryContainer
                            : null,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                m.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${m.host}:${m.port}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
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
          state.hasActiveThreadStore &&
          !state.sending &&
          details.data.id != state.activeThreadId,
      onAcceptWithDetails: (details) {
        if (!state.hasActiveThreadStore || state.sending) return;
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
          state.hasActiveThreadStore && !state.sending,
      onAcceptWithDetails: (details) {
        if (!state.hasActiveThreadStore || state.sending) return;
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
