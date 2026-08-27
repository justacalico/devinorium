class PermissionOption {
  final String id;
  final String kind;
  final String? label;

  PermissionOption({required this.id, required this.kind, this.label});

  factory PermissionOption.fromJson(Map<String, dynamic> j) => PermissionOption(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? '',
    label: j['label'] as String?,
  );
}

class PermissionRequest {
  final String requestId;
  final String scope;
  final String title;
  final String? input;
  final List<PermissionOption> options;

  PermissionRequest({
    required this.requestId,
    required this.scope,
    required this.title,
    this.input,
    required this.options,
  });

  factory PermissionRequest.fromJson(Map<String, dynamic> j) =>
      PermissionRequest(
        requestId: j['request_id'] as String,
        scope: j['scope'] as String? ?? '',
        title: j['title'] as String? ?? 'Unknown action',
        input: j['input'] as String?,
        options:
            (j['options'] as List<dynamic>?)
                ?.map(
                  (o) => PermissionOption.fromJson(o as Map<String, dynamic>),
                )
                .toList() ??
            [],
      );
}

class AskOption {
  final String value;
  final String label;

  AskOption({required this.value, required this.label});

  factory AskOption.fromJson(Map<String, dynamic> j) => AskOption(
    value: j['value'] as String? ?? '',
    label: j['label'] as String? ?? '',
  );
}

class AskQuestion {
  final String id;
  final String prompt;
  final String? description;
  final String fieldType;
  final List<AskOption> options;
  final bool required;

  AskQuestion({
    required this.id,
    required this.prompt,
    this.description,
    required this.fieldType,
    this.options = const [],
    this.required = false,
  });

  factory AskQuestion.fromJson(Map<String, dynamic> j) => AskQuestion(
    id: j['id'] as String? ?? '',
    prompt: j['prompt'] as String? ?? '',
    description: j['description'] as String?,
    fieldType: j['field_type'] as String? ?? 'text',
    options:
        (j['options'] as List<dynamic>?)
            ?.map((o) => AskOption.fromJson(o as Map<String, dynamic>))
            .toList() ??
        const [],
    required: j['required'] as bool? ?? false,
  );

  bool get isText => fieldType == 'text';
  bool get isNumber => fieldType == 'number';
  bool get isBoolean => fieldType == 'boolean';
  bool get isSingleSelect => fieldType == 'single_select';
  bool get isMultiSelect => fieldType == 'multi_select';
}

class AskRequest {
  final String requestId;
  final String message;
  final List<AskQuestion> questions;

  AskRequest({
    required this.requestId,
    required this.message,
    required this.questions,
  });

  factory AskRequest.fromJson(Map<String, dynamic> j) => AskRequest(
    requestId: j['request_id'] as String? ?? '',
    message: j['message'] as String? ?? '',
    questions:
        (j['questions'] as List<dynamic>?)
            ?.map((q) => AskQuestion.fromJson(q as Map<String, dynamic>))
            .toList() ??
        const [],
  );
}
