import 'dart:convert';
import 'package:http/http.dart' as http;

/// AI 客户端抽象接口 — 支持 Anthropic 和 OpenAI/DeepSeek 两种协议。
abstract class AiClient {
  Future<AiResponse> generate({
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
    int maxTokens = 4096,
  });

  Stream<String> generateStream({
    required List<Map<String, dynamic>> messages,
    int maxTokens = 4096,
  });

  static AiClient create(String apiKey, [String? baseUrl]) {
    final url = (baseUrl ?? '').toLowerCase();
    // 从 URL 自动判断 provider：deepseek 域名 → DeepSeek，其余默认 Anthropic
    if (url.contains('deepseek')) {
      return _OpenAiClient(
        apiKey: apiKey,
        baseUrl: baseUrl ?? 'https://api.deepseek.com/v1/chat/completions',
        model: 'deepseek-chat',
      );
    }
    // OpenAI 兼容协议
    if (url.contains('openai') || url.contains('v1/chat')) {
      return _OpenAiClient(
        apiKey: apiKey,
        baseUrl: baseUrl ?? 'https://api.openai.com/v1/chat/completions',
        model: 'gpt-4o',
      );
    }
    // 默认 Anthropic
    return _AnthropicClient(
      apiKey: apiKey,
      baseUrl: baseUrl ?? 'https://api.anthropic.com/v1/messages',
      model: 'claude-sonnet-4-20250514',
    );
  }
}

// ── AI 响应 ──

class AiResponse {
  final String text;
  final List<ToolUse> toolUses;
  final bool hasToolUse;
  AiResponse({required this.text, required this.toolUses}) : hasToolUse = toolUses.isNotEmpty;
}

class ToolUse {
  final String id;
  final String name;
  final Map<String, dynamic> input;
  ToolUse({required this.id, required this.name, required this.input});
}

// ── Anthropic 实现 ──

class _AnthropicClient extends AiClient {
  _AnthropicClient({required this.apiKey, required this.baseUrl, required this.model});
  final String apiKey;
  final String baseUrl;
  final String model;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2023-06-01',
  };

  @override
  Future<AiResponse> generate({required List<Map<String, dynamic>> messages, List<Map<String, dynamic>> tools = const [], int maxTokens = 4096}) async {
    final body = <String, dynamic>{'model': model, 'max_tokens': maxTokens, 'messages': messages};
    if (tools.isNotEmpty) body['tools'] = tools;

    final resp = await http.post(Uri.parse(baseUrl), headers: _headers, body: jsonEncode(body));
    if (resp.statusCode != 200) throw Exception('API 错误 ${resp.statusCode}: ${resp.body}');

    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    final contents = data['content'] as List<dynamic>? ?? [];
    String text = '';
    final tools = <ToolUse>[];
    for (final block in contents) {
      final t = block['type'] as String?;
      if (t == 'text') text += block['text'] as String? ?? '';
      if (t == 'tool_use') tools.add(ToolUse(id: block['id'], name: block['name'], input: block['input'] as Map<String, dynamic>? ?? {}));
    }
    return AiResponse(text: text, toolUses: tools);
  }

  @override
  Stream<String> generateStream({required List<Map<String, dynamic>> messages, int maxTokens = 4096}) async* {
    final body = {'model': model, 'max_tokens': maxTokens, 'stream': true, 'messages': messages};
    final req = http.Request('POST', Uri.parse(baseUrl))..headers.addAll(_headers)..body = jsonEncode(body);
    final resp = await http.Client().send(req);
    await for (final line in utf8.decoder.bind(resp.stream).transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6);
      if (data == '[DONE]') break;
      try {
        final json = jsonDecode(data);
        if (json['type'] == 'content_block_delta') {
          final delta = json['delta'];
          if (delta?['type'] == 'text_delta') yield delta['text'] as String? ?? '';
        }
      } catch (_) {}
    }
  }
}

// ── OpenAI/DeepSeek 实现 ──

class _OpenAiClient extends AiClient {
  _OpenAiClient({required this.apiKey, required this.baseUrl, required this.model});
  final String apiKey;
  final String baseUrl;
  final String model;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $apiKey',
  };

  /// 将 Anthropic 格式的 tools 转为 OpenAI 格式
  List<Map<String, dynamic>> _toOpenAiTools(List<Map<String, dynamic>> tools) {
    return tools.map((t) => {
      'type': 'function',
      'function': {
        'name': t['name'],
        'description': t['description'] ?? '',
        'parameters': t['input_schema'] ?? {'type': 'object', 'properties': <String, dynamic>{}},
      },
    }).toList();
  }

  /// 将 Anthropic 格式的 messages 转为 OpenAI 格式
  List<Map<String, dynamic>> _toOpenAiMessages(List<Map<String, dynamic>> msgs) {
    final result = <Map<String, dynamic>>[];
    for (final m in msgs) {
      final role = m['role'] as String? ?? 'user';
      final content = m['content'];

      // tool_result → OpenAI tool 角色
      if (role == 'user' && content is List) {
        for (final block in content) {
          if (block is Map<String, dynamic> && block['type'] == 'tool_result') {
            result.add({
              'role': 'tool',
              'tool_call_id': block['tool_use_id'],
              'content': block['content'] as String? ?? '',
            });
            continue;
          }
        }
        continue;
      }

      result.add({'role': role == 'assistant' ? 'assistant' : 'user', 'content': content is String ? content : jsonEncode(content)});
    }
    return result;
  }

  @override
  Future<AiResponse> generate({required List<Map<String, dynamic>> messages, List<Map<String, dynamic>> tools = const [], int maxTokens = 4096}) async {
    final body = <String, dynamic>{
      'model': model, 'max_tokens': maxTokens,
      'messages': _toOpenAiMessages(messages),
    };
    if (tools.isNotEmpty) body['tools'] = _toOpenAiTools(tools);

    final resp = await http.post(Uri.parse(baseUrl), headers: _headers, body: jsonEncode(body));
    if (resp.statusCode != 200) throw Exception('API 错误 ${resp.statusCode}: ${resp.body}');

    final data = jsonDecode(utf8.decode(resp.bodyBytes));
    final choice = data['choices']?[0]?['message'] as Map<String, dynamic>? ?? {};
    final text = choice['content'] as String? ?? '';
    final toolCalls = choice['tool_calls'] as List<dynamic>?;
    final toolsResult = <ToolUse>[];
    if (toolCalls != null) {
      for (final tc in toolCalls) {
        final func = tc['function'];
        toolsResult.add(ToolUse(
          id: tc['id'] as String? ?? '',
          name: func['name'] as String? ?? '',
          input: jsonDecode(func['arguments'] as String? ?? '{}') as Map<String, dynamic>,
        ));
      }
    }
    return AiResponse(text: text, toolUses: toolsResult);
  }

  @override
  Stream<String> generateStream({required List<Map<String, dynamic>> messages, int maxTokens = 4096}) async* {
    final body = {'model': model, 'max_tokens': maxTokens, 'stream': true, 'messages': _toOpenAiMessages(messages)};
    final req = http.Request('POST', Uri.parse(baseUrl))..headers.addAll(_headers)..body = jsonEncode(body);
    final resp = await http.Client().send(req);
    await for (final line in utf8.decoder.bind(resp.stream).transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6);
      if (data == '[DONE]') break;
      try {
        final json = jsonDecode(data);
        final delta = json['choices']?[0]?['delta'];
        final content = delta?['content'] as String?;
        if (content != null && content.isNotEmpty) yield content;
      } catch (_) {}
    }
  }
}
