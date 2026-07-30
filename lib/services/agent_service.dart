import 'dart:async';
import 'ai_client.dart';
import 'tool_registry.dart';
import 'memory_service.dart';

/// Agent 循环事件 — UI 层通过 Stream 监听
sealed class AgentEvent {}
class AgentText extends AgentEvent { final String text; AgentText(this.text); }
class AgentToolStart extends AgentEvent { final String name; final Map<String, dynamic> input; AgentToolStart(this.name, this.input); }
class AgentToolEnd extends AgentEvent { final String name; final String result; AgentToolEnd(this.name, this.result); }
class AgentDone extends AgentEvent { final String text; AgentDone(this.text); }
class AgentError extends AgentEvent { final String message; AgentError(this.message); }
class AgentToolError extends AgentEvent { final String name; final String error; AgentToolError(this.name, this.error); }

/// Agent 服务 — 多轮 Think→Act→Observe 循环，带上下文压缩。
class AgentService {
  AgentService({required this.apiKey, this.baseUrl});

  final String apiKey;
  final String? baseUrl;
  static const int _maxIterations = 8;

  /// 触发上下文压缩的消息对数阈值（超过则压缩早期历史）
  static const int _compactTurnThreshold = 7;

  /// 压缩后保留的最近完整轮次（每轮含 user + assistant 两条）
  static const int _keepRecentTurns = 3;

  late final AiClient _client = AiClient.create(apiKey, baseUrl);

  /// 执行一次对话，返回事件流。
  Stream<AgentEvent> converse({
    required List<Map<String, dynamic>> messages,
    required String newMessage,
  }) async* {
    List<Map<String, dynamic>> fullMessages = [...messages, {'role': 'user', 'content': newMessage}];

    // ── 上下文压缩：历史消息太多时，压缩早期内容 ──
    String? compactedSummary;
    if (messages.length > _compactTurnThreshold * 2) {
      try {
        final result = await _compactContext(messages);
        compactedSummary = result;
        // 重建 fullMessages：概要 → 最近 N 轮完整消息 → 当前输入
        final recentStart = messages.length - (_keepRecentTurns * 2);
        final recent = messages.sublist(recentStart < 0 ? 0 : recentStart);
        fullMessages = [
          {'role': 'user', 'content': '[历史对话概要] $result'},
          {'role': 'assistant', 'content': '好的，我记下了之前的对话概要。'},
          ...recent,
          {'role': 'user', 'content': newMessage},
        ];
      } catch (_) {
        // 压缩失败不影响主流程，保持原样
      }
    }

    // 注入系统提示词
    final memoryCtx = await MemoryService.buildContext();
    final subjectList = await ToolRegistry.execute('list_subjects', {});
    final stats = await ToolRegistry.execute('get_stats', {});

    final systemPrompt = '''
你是 MIX 学习助手，运行在用户的手机上。
你是一个 AI 学习教练，不是通用助手。

## 当前状态
$stats

## 科目概况
$subjectList

## 长期记忆
$memoryCtx
${compactedSummary != null ? '\n## 之前讨论过\n$compactedSummary' : ''}

## 你的能力
你可以读/写学习文件、管理科目、搜索记忆、获取学习统计、浏览网页。
需要操作时直接调用工具，不额外解释工具调用过程。

## 格式
- 用 Markdown 回复
- 公式用 \$...\$ 包裹
- 友好但不啰嗦
- 回答完可以提议下一步做什么''';

    List<Map<String, dynamic>> apiMessages = [
      {'role': 'user', 'content': systemPrompt},
      {'role': 'assistant', 'content': '好的，我了解你的状态了。有什么可以帮你？'},
      ...fullMessages,
    ];

    for (var iteration = 0; iteration < _maxIterations; iteration++) {
      final response = await _client.generate(
        messages: apiMessages,
        tools: ToolRegistry.definitions,
      );

      if (response.text.isNotEmpty) {
        apiMessages.add({'role': 'assistant', 'content': response.text});
      }

      if (!response.hasToolUse) {
        yield AgentDone(response.text);
        try { await MemoryService.extractFromConversation(newMessage, response.text); } catch (_) {}
        return;
      }

      for (final tool in response.toolUses) {
        yield AgentToolStart(tool.name, tool.input);
        String result;
        try {
          result = await ToolRegistry.execute(tool.name, tool.input);
        } catch (e) {
          result = '执行失败：$e';
          yield AgentToolError(tool.name, e.toString());
        }
        yield AgentToolEnd(tool.name, result);

        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': tool.id, 'content': result},
          ],
        });
      }
    }

    final lastMsg = apiMessages.last['content'] as String? ?? '（已达最大思考轮次）';
    yield AgentDone(lastMsg);
  }

  /// 用 AI 自己把早期历史压缩成一段概要。
  /// 核心思路：不额外花钱调模型，而是构造一个精简版 prompt
  /// 让当前请求的第一个工具调用（如果发生）顺便完成压缩。
  /// 但更可靠的做法是独立请求——费用约 0.1% 正常对话成本。
  Future<String> _compactContext(List<Map<String, dynamic>> messages) async {
    // 只取需要压缩的部分：去掉最近的 N 轮
    final toCompact = messages.take(messages.length - _keepRecentTurns * 2).toList();

    // 提取纯文本，去掉工具调用细节
    final texts = toCompact.map((m) {
      final role = m['role'] == 'user' ? '用户' : '助手';
      final content = m['content'];
      if (content is String) return '$role: $content';
      // tool_result 消息跳过
      return null;
    }).whereType<String>().take(20).join('\n');

    if (texts.length < 50) return '';

    // 用一次轻量 AI 调用做压缩（设定极低的 max_tokens 控制成本）
    final response = await _client.generate(
      messages: [
        {'role': 'user', 'content': '把以下对话压缩成一段 50 字以内的中文概要，只保留关键事实和决定：\n\n$texts'},
      ],
      maxTokens: 200,
    );
    return response.text.trim();
  }
}
