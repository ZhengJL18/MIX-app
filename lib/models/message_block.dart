/// MIX Agent 事件驱动消息模型。
///
/// 不存 Markdown 字符串，存事件实体。
/// 每种实体类型对应一个 Flutter widget，在 ChatScreen 中通过工厂分发。
///
/// 设计原则：
/// 1. 消息列表 = List<MessageBlock>，不是 List<String>
/// 2. TextBlock 内容是 Markdown，渲染交给 flutter_markdown
/// 3. ToolCallBlock 三态驱动 UI 动画
/// 4. 所有 block 都有唯一 id 和时间戳，支持存档恢复

enum BlockType { text, toolCall, status, divider }

/// ── 基类 ──
abstract class MessageBlock {
  final String id;
  final DateTime createdAt;
  final BlockType type;

  MessageBlock({required this.id, required this.type, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  /// 转 Map 用于序列化到 SQLite
  Map<String, dynamic> toMap();

  /// 从 Map 反序列化
  factory MessageBlock.fromMap(Map<String, dynamic> map) {
    final type = BlockType.values[map['block_type'] as int? ?? 0];
    switch (type) {
      case BlockType.text:
        return TextBlock.fromMap(map);
      case BlockType.toolCall:
        return ToolCallBlock.fromMap(map);
      case BlockType.status:
        return StatusBlock.fromMap(map);
      case BlockType.divider:
        return DividerBlock();
    }
  }
}

/// ── 文本块（流式文字气泡） ──
class TextBlock extends MessageBlock {
  String content;
  bool isStreaming;
  bool isError;

  TextBlock({
    required super.id,
    this.content = '',
    this.isStreaming = false,
    this.isError = false,
  }) : super(type: BlockType.text);

  /// 追加流式内容（合并渲染周期）
  void append(String delta) {
    content += delta;
  }

  /// 标记流式结束
  void finish() => isStreaming = false;

  /// 标记错误
  void markError(String message) {
    content = message;
    isError = true;
    isStreaming = false;
  }

  @override
  Map<String, dynamic> toMap() => {
    'block_type': BlockType.text.index,
    'id': id,
    'content': content,
    'is_streaming': isStreaming ? 1 : 0,
    'is_error': isError ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory TextBlock.fromMap(Map<String, dynamic> map) => TextBlock(
    id: map['id'] as String,
    content: map['content'] as String? ?? '',
    isStreaming: (map['is_streaming'] as int? ?? 0) == 1,
    isError: (map['is_error'] as int? ?? 0) == 1,
  );
}

/// ── 工具调用块（可折叠三态卡片） ──
class ToolCallBlock extends MessageBlock {
  String toolName;
  String toolLabel;
  final Map<String, dynamic> args;
  String status;        // running / success / error
  String? resultSummary;
  String? errorMessage;
  DateTime? startedAt;
  bool _expanded = false;

  bool get expanded => _expanded;
  bool get isRunning => status == 'running';
  bool get isError => status == 'error';
  bool get isSuccess => status == 'success';

  ToolCallBlock({
    required super.id,
    required this.toolName,
    required this.toolLabel,
    this.args = const {},
    this.status = 'running',
    this.resultSummary,
    this.errorMessage,
    this.startedAt,
  }) : super(type: BlockType.toolCall);

  void markSuccess(String? summary) {
    status = 'success';
    resultSummary = summary;
  }

  void markError(String error) {
    status = 'error';
    errorMessage = error;
  }

  /// 工具调用完成（finish_reason=tool_calls）→ 记录参数摘要，供展示。
  void markToolCall(String argsJson) {
    if (argsJson.isNotEmpty) {
      // 参数摘要存到 resultSummary 用于展示（args 保持不可变默认）
      resultSummary = argsJson.length > 200
          ? '${argsJson.substring(0, 200)}…'
          : argsJson;
    }
  }

  void toggleExpanded() => _expanded = !_expanded;

  @override
  Map<String, dynamic> toMap() => {
    'block_type': BlockType.toolCall.index,
    'id': id,
    'tool_name': toolName,
    'tool_label': toolLabel,
    'status': status,
    'result_summary': resultSummary,
    'error_message': errorMessage,
    'started_at': startedAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
  };

  factory ToolCallBlock.fromMap(Map<String, dynamic> map) => ToolCallBlock(
    id: map['id'] as String,
    toolName: map['tool_name'] as String,
    toolLabel: map['tool_label'] as String? ?? map['tool_name'] as String,
    status: map['status'] as String? ?? 'success',
    resultSummary: map['result_summary'] as String?,
    errorMessage: map['error_message'] as String?,
  );
}

/// ── 状态信息条 ──
class StatusBlock extends MessageBlock {
  final String text;
  final bool isWarning;
  final bool autoDismiss;   // 是否几秒后消失

  StatusBlock({
    required super.id,
    required this.text,
    this.isWarning = false,
    this.autoDismiss = true,
  }) : super(type: BlockType.status);

  @override
  Map<String, dynamic> toMap() => {
    'block_type': BlockType.status.index,
    'id': id,
    'text': text,
    'is_warning': isWarning ? 1 : 0,
    'created_at': createdAt.toIso8601String(),
  };

  factory StatusBlock.fromMap(Map<String, dynamic> map) => StatusBlock(
    id: map['id'] as String,
    text: map['text'] as String? ?? '',
    isWarning: (map['is_warning'] as int? ?? 0) == 1,
  );
}

/// ── 分隔线 ──
class DividerBlock extends MessageBlock {
  DividerBlock({super.id = 'divider'})
    : super(type: BlockType.divider);

  @override
  Map<String, dynamic> toMap() => {
    'block_type': BlockType.divider.index,
    'id': id,
    'created_at': createdAt.toIso8601String(),
  };
}

/// ── ID 生成器 ──
String _nextId = 'msg_0';
String generateBlockId() {
  _nextId = 'msg_${int.parse(_nextId.split('_')[1]) + 1}';
  return _nextId;
}
