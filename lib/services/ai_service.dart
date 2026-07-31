import 'dart:convert';
import 'package:http/http.dart' as http;

/// AI 生成题目的结构化结果，对应 questions 表里 AI 生成部分的字段。
class GeneratedQuestion {
  final String content;
  final String answer;
  final double? cplxCoef;
  final double? undCoef;
  final double? redCoef;
  final double? covCoef;

  GeneratedQuestion({
    required this.content,
    required this.answer,
    this.cplxCoef,
    this.undCoef,
    this.redCoef,
    this.covCoef,
  });
}

/// AI 出题服务的抽象接口，方便替换成任意厂商 API 或本地模型。
abstract class AiService {
  Future<GeneratedQuestion> generateQuestion(String prompt);
}

/// 通用 OpenAI 兼容客户端 — DeepSeek / OpenAI / 智谱 / Kimi / 通义千问
/// 全部使用 OpenAI chat completions 协议。
class OpenAiCompatibleAiService implements AiService {
  OpenAiCompatibleAiService({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  final String baseUrl;
  final String model;
  final String apiKey;

  /// 通用对话（Hermes 本地 Agent 不可用时的替代实现）
  Future<String> chat(String prompt) async {
    final response = await http.post(
      Uri.parse(baseUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'messages': [
          {'role': 'system', 'content': '你是 MIX 学习助手，一个 AI 学习教练。用中文简洁回答。'},
          {'role': 'user', 'content': prompt},
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('AI 对话失败: ${response.statusCode} ${response.body}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return data['choices']?[0]?['message']?['content'] as String? ?? '';
  }

  @override
  Future<GeneratedQuestion> generateQuestion(String prompt) async {
    final response = await http.post(
      Uri.parse(baseUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': model,
        'max_tokens': 2048,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('AI 出题请求失败: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final text = data['choices']?[0]?['message']?['content'] as String? ?? '';
    if (text.isEmpty) throw Exception('AI 返回为空，请检查 API Key 或模型名');

    return AnthropicAiService.parseMarkdownResponse(text);
  }
}

/// 默认实现：调用 Anthropic Messages API。
///
/// 使用前需要在客户端配置里填入 API Key 与（如需要）反向代理地址，
/// 因为 Anthropic API 目前对中国大陆 IP 有区域限制——具体接入方式
/// 请参考应用内"设置 > AI 接口配置"页面，而不是把密钥硬编码在代码里。
class AnthropicAiService implements AiService {
  AnthropicAiService({required this.apiKey, this.baseUrl = 'https://api.anthropic.com/v1/messages'});

  final String apiKey;
  final String baseUrl;

  @override
  Future<GeneratedQuestion> generateQuestion(String prompt) async {
    final response = await http.post(
      Uri.parse(baseUrl),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': 'claude-sonnet-4-6',
        'max_tokens': 1024,
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('AI 出题请求失败: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final blocks = data['content'] as List<dynamic>;
    final text = blocks
        .where((b) => b['type'] == 'text')
        .map((b) => b['text'] as String)
        .join('\n');

    return parseMarkdownResponse(text);
  }

  /// 解析 build_prompt 中约定的 Markdown 返回格式：
  /// ## 题目 / ## 答案 / ## 系数（复杂度/理解难度/冗余度/覆盖率）。
  static GeneratedQuestion parseMarkdownResponse(String text) {
    String extractSection(String header, String stopHeaderPattern) {
      final pattern = RegExp(
        '##\\s*$header\\s*\\n(.*?)(?=\\n##\\s*(?:$stopHeaderPattern)|\$)',
        dotAll: true,
      );
      final match = pattern.firstMatch(text);
      return match?.group(1)?.trim() ?? '';
    }

    final content = extractSection('题目', '答案|系数');
    final answer = extractSection('答案', '系数');
    final coefSection = extractSection('系数', r'.^');

    double? extractCoef(String label) {
      final m = RegExp('$label[：:]\\s*([0-9.]+)').firstMatch(coefSection);
      if (m == null) return null;
      return double.tryParse(m.group(1)!);
    }

    return GeneratedQuestion(
      content: content.isEmpty ? text : content,
      answer: answer,
      cplxCoef: extractCoef('复杂度'),
      undCoef: extractCoef('理解难度'),
      redCoef: extractCoef('冗余度'),
      covCoef: extractCoef('覆盖率'),
    );
  }
}

/// 离线/演示用的假实现：不联网，直接基于知识点生成占位题目。
/// 在没有配置 API Key 时用它兜底，保证 App 仍可运行、可演示流程。
class MockAiService implements AiService {
  @override
  Future<GeneratedQuestion> generateQuestion(String prompt) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return GeneratedQuestion(
      content: '（示例题目，尚未配置 AI 接口）\n\n$prompt',
      answer: '（示例答案，请在设置中配置 AI 接口以获取真实题目）',
      cplxCoef: 0.4,
      undCoef: 0.4,
      redCoef: 0.2,
      covCoef: 0.3,
    );
  }
}
