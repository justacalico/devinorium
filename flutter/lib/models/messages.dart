import 'package:flutter/foundation.dart' show listEquals;

import 'attachment.dart';

class FileDiff {
  final String path;
  final String? oldText;
  final String newText;

  const FileDiff({required this.path, this.oldText, required this.newText});

  factory FileDiff.fromJson(Map<String, dynamic> j) => FileDiff(
    path: j['path'] as String? ?? '',
    oldText: j['old_text'] as String?,
    newText: j['new_text'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    if (oldText != null) 'old_text': oldText,
    'new_text': newText,
  };

  FileDiff copyWith({String? path, String? oldText, String? newText}) =>
      FileDiff(
        path: path ?? this.path,
        oldText: oldText ?? this.oldText,
        newText: newText ?? this.newText,
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FileDiff) return false;
    return path == other.path &&
        oldText == other.oldText &&
        newText == other.newText;
  }

  @override
  int get hashCode => Object.hash(path, oldText, newText);
}

class ToolCallData {
  final String id;
  final String title;
  final String kind;
  final String status;
  final String? command;
  final String? output;
  final String? outputPreview;
  final List<String> changedFiles;
  final List<FileDiff> diffs;

  ToolCallData({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    this.command,
    this.output,
    this.outputPreview,
    this.changedFiles = const [],
    this.diffs = const [],
  });

  factory ToolCallData.fromJson(Map<String, dynamic> j) => ToolCallData(
    id: j['id'] as String,
    title: j['title'] as String,
    kind: j['kind'] as String,
    status: j['status'] as String,
    command: j['command'] as String?,
    output: j['output'] as String?,
    outputPreview: j['output_preview'] as String?,
    changedFiles:
        (j['changed_files'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        const [],
    diffs:
        (j['diffs'] as List<dynamic>?)
            ?.map((e) => FileDiff.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );

  ToolCallData copyWith({
    String? title,
    String? kind,
    String? status,
    String? command,
    String? output,
    String? outputPreview,
    List<String>? changedFiles,
    List<FileDiff>? diffs,
  }) => ToolCallData(
    id: id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    status: status ?? this.status,
    command: command ?? this.command,
    output: output ?? this.output,
    outputPreview: outputPreview ?? this.outputPreview,
    changedFiles: changedFiles ?? this.changedFiles,
    diffs: diffs ?? this.diffs,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ToolCallData) return false;
    return id == other.id &&
        title == other.title &&
        kind == other.kind &&
        status == other.status &&
        command == other.command &&
        output == other.output &&
        outputPreview == other.outputPreview &&
        listEquals(changedFiles, other.changedFiles) &&
        listEquals(diffs, other.diffs);
  }

  @override
  int get hashCode {
    var h = Object.hash(
      id,
      title,
      kind,
      status,
      command,
      output,
      outputPreview,
    );
    for (final f in changedFiles) {
      h = Object.hash(h, f);
    }
    for (final d in diffs) {
      h = Object.hash(h, d);
    }
    return h;
  }
}

class MessagePart {
  final String type;
  final String? id;
  final String? content;
  final ToolCallData? toolCall;

  MessagePart._({required this.type, this.id, this.content, this.toolCall});

  factory MessagePart.text({required String content}) =>
      MessagePart._(type: 'text', content: content);

  factory MessagePart.thinking({required String content}) =>
      MessagePart._(type: 'thinking', content: content);

  factory MessagePart.toolCall({required ToolCallData toolCall}) =>
      MessagePart._(type: 'tool_call', id: toolCall.id, toolCall: toolCall);

  factory MessagePart.fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String? ?? 'text';
    switch (type) {
      case 'text':
        return MessagePart.text(content: j['content'] as String? ?? '');
      case 'thinking':
        return MessagePart.thinking(content: j['content'] as String? ?? '');
      case 'tool_call':
        return MessagePart.toolCall(toolCall: ToolCallData.fromJson(j));
      default:
        return MessagePart.text(content: j['content'] as String? ?? '');
    }
  }

  @override
  String toString() =>
      'MessagePart(type: $type, id: $id, content: $content, toolCall: $toolCall)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MessagePart) return false;
    return type == other.type &&
        id == other.id &&
        content == other.content &&
        toolCall == other.toolCall;
  }

  @override
  int get hashCode => Object.hash(type, id, content, toolCall);
}

class Message {
  final int? id;
  final String role;
  final String content;
  final String? thinking;
  final List<Attachment>? attachments;
  final List<MessagePart>? parts;
  final String model;
  final int? turnId;
  final int? seq;
  final bool truncated;
  final int? totalChars;
  final int? truncatedAt;

  const Message({
    this.id,
    required this.role,
    required this.content,
    this.thinking,
    this.attachments,
    this.parts,
    this.model = '',
    this.turnId,
    this.seq,
    this.truncated = false,
    this.totalChars,
    this.truncatedAt,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: (j['id'] as num?)?.toInt(),
    role: j['role'] as String,
    content: j['content'] as String? ?? '',
    thinking: j['thinking'] as String?,
    attachments: (j['attachments'] as List<dynamic>?)
        ?.map((a) => Attachment.fromJson(a as Map<String, dynamic>))
        .toList(),
    parts: (j['parts'] as List<dynamic>?)
        ?.map((p) => MessagePart.fromJson(p as Map<String, dynamic>))
        .toList(),
    model: j['model'] as String? ?? '',
    turnId: (j['turn_id'] as num?)?.toInt(),
    seq: (j['seq'] as num?)?.toInt(),
    truncated: j['truncated'] as bool? ?? false,
    totalChars: (j['total_chars'] as num?)?.toInt(),
    truncatedAt: (j['truncated_at'] as num?)?.toInt(),
  );

  List<MessagePart> get allParts {
    if (parts != null && parts!.isNotEmpty) return parts!;
    final list = <MessagePart>[MessagePart.text(content: content)];
    if (thinking != null && thinking!.isNotEmpty) {
      list.add(MessagePart.thinking(content: thinking!));
    }
    return list;
  }

  Message copyWith({
    int? id,
    String? role,
    String? content,
    String? thinking,
    List<Attachment>? attachments,
    List<MessagePart>? parts,
    String? model,
    int? turnId,
    int? seq,
    bool? truncated,
    int? totalChars,
    int? truncatedAt,
  }) => Message(
    id: id ?? this.id,
    role: role ?? this.role,
    content: content ?? this.content,
    thinking: thinking ?? this.thinking,
    attachments: attachments ?? this.attachments,
    parts: parts ?? this.parts,
    model: model ?? this.model,
    turnId: turnId ?? this.turnId,
    seq: seq ?? this.seq,
    truncated: truncated ?? this.truncated,
    totalChars: totalChars ?? this.totalChars,
    truncatedAt: truncatedAt ?? this.truncatedAt,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Message) return false;
    return id == other.id &&
        role == other.role &&
        content == other.content &&
        thinking == other.thinking &&
        model == other.model &&
        turnId == other.turnId &&
        seq == other.seq &&
        truncated == other.truncated &&
        totalChars == other.totalChars &&
        truncatedAt == other.truncatedAt &&
        listEquals(attachments, other.attachments) &&
        listEquals(parts, other.parts);
  }

  @override
  int get hashCode {
    var h = Object.hash(
      id,
      role,
      content,
      thinking,
      model,
      turnId,
      seq,
      truncated,
      totalChars,
      truncatedAt,
    );
    for (final a in attachments ?? const <Attachment>[]) {
      h = Object.hash(h, a);
    }
    for (final p in parts ?? const <MessagePart>[]) {
      h = Object.hash(h, p);
    }
    return h;
  }
}

class MessagePage {
  final List<Message> messages;
  final int total;
  final int? turnLimit;
  final int? rawCount;
  final String? beforeCursor;
  final bool? hasMore;

  const MessagePage({
    this.messages = const [],
    this.total = 0,
    this.turnLimit,
    this.rawCount,
    this.beforeCursor,
    this.hasMore,
  });

  factory MessagePage.fromJson(Map<String, dynamic> j) => MessagePage(
    messages: ((j['messages'] as List<dynamic>?) ?? [])
        .map((m) => Message.fromJson(m as Map<String, dynamic>))
        .toList(),
    total: (j['total'] as num?)?.toInt() ?? 0,
    turnLimit: (j['turn_limit'] as num?)?.toInt(),
    rawCount: (j['raw_count'] as num?)?.toInt(),
    beforeCursor: j['before_cursor'] as String?,
    hasMore: j['has_more'] as bool?,
  );

  MessagePage copyWith({
    List<Message>? messages,
    int? total,
    int? turnLimit,
    int? rawCount,
    String? beforeCursor,
    bool? hasMore,
  }) => MessagePage(
    messages: messages ?? this.messages,
    total: total ?? this.total,
    turnLimit: turnLimit ?? this.turnLimit,
    rawCount: rawCount ?? this.rawCount,
    beforeCursor: beforeCursor ?? this.beforeCursor,
    hasMore: hasMore ?? this.hasMore,
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MessagePage) return false;
    return total == other.total &&
        turnLimit == other.turnLimit &&
        rawCount == other.rawCount &&
        beforeCursor == other.beforeCursor &&
        hasMore == other.hasMore &&
        listEquals(messages, other.messages);
  }

  @override
  int get hashCode {
    var h = Object.hash(
      total,
      turnLimit,
      rawCount,
      beforeCursor,
      hasMore,
      messages.length,
    );
    for (final m in messages) {
      h = Object.hash(h, m);
    }
    return h;
  }
}
