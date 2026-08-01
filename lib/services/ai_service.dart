import 'dart:convert';
import 'package:http/http.dart' as http;

/// AI 生成题目的结构化结果，对应 questions 表里 AI 生成部分的字段。
class GeneratedQuestion {
  final String content;
  final String answer;

  /// 选择题选项（A/B/C/D 顺序）。非选择题为空列表。
  final List<String> options;

  /// 正确选项文本（选择题）；非选择题为答案原文。
  final String correctAnswer;

  /// 解析（可选，存库后在答案页展示）。
  final String? explanation;

  final double? cplxCoef;
  final double? undCoef;
  final double? redCoef;
  final double? covCoef;

  GeneratedQuestion({
    required this.content,
    required this.answer,
    this.options = const [],
    String? correctAnswer,
    this.explanation,
    this.cplxCoef,
    this.undCoef,
    this.redCoef,
    this.covCoef,
  }) : correctAnswer = correctAnswer ?? answer;
}

/// AI 出题服务的抽象接口，方便替换成任意厂商 API 或本地模型。
abstract class AiService {
  Future<GeneratedQuestion> generateQuestion(String prompt);

  /// 流式生成：每次回调产出累积的原始文本，供 UI 实时渲染
  Future<GeneratedQuestion> generateQuestionStream(
    String prompt,
    void Function(String accumulated) onDelta,
  );
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
    final body = jsonEncode({
      'model': model,
      'max_tokens': 2048,
      'messages': [
        {'role': 'system', 'content': '你是 MIX 学习助手，一个 AI 学习教练。用中文简洁回答。'},
        {'role': 'user', 'content': prompt},
      ],
    });

    final response = await _postWithRetry(body);
    if (response.statusCode != 200) {
      throw Exception('AI 对话失败: ${response.statusCode} ${response.body}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return data['choices']?[0]?['message']?['content'] as String? ?? '';
  }

  @override
  Future<GeneratedQuestion> generateQuestion(String prompt) async {
    final body = jsonEncode({
      'model': model,
      'max_tokens': 2048,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
    });

    final response = await _postWithRetry(body);
    if (response.statusCode != 200) {
      throw Exception('AI 出题请求失败: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final text = data['choices']?[0]?['message']?['content'] as String? ?? '';
    if (text.isEmpty) throw Exception('AI 返回为空，请检查 API Key 或模型名');

    return AnthropicAiService.parseMarkdownResponse(text);
  }

  /// 发起一次 POST，非 200 或网络异常时自动重试一次。
  ///
  /// 解决首次请求偶发的瞬时 401/网络抖动（第二次即正常）问题。
  Future<http.Response> _postWithRetry(String body) async {
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    };

    Future<http.Response> doPost() {
      return http.post(Uri.parse(baseUrl), headers: headers, body: body);
    }

    try {
      final resp = await doPost();
      // 首次失败（401/5xx/限流）时短暂等待后重试一次
      if (resp.statusCode != 200) {
        await Future.delayed(const Duration(milliseconds: 600));
        return await doPost();
      }
      return resp;
    } catch (_) {
      // 网络异常 → 重试一次
      await Future.delayed(const Duration(milliseconds: 600));
      return doPost();
    }
  }

  @override
  Future<GeneratedQuestion> generateQuestionStream(
    String prompt,
    void Function(String accumulated) onDelta,
  ) async {
    http.StreamedResponse? response;
    // 建连失败重试一次
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final request = http.Request('POST', Uri.parse(baseUrl))
          ..headers.addAll({
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          })
          ..body = jsonEncode({
            'model': model,
            'max_tokens': 2048,
            'stream': true,
            'messages': [
              {'role': 'user', 'content': prompt},
            ],
          });

        response = await http.Client().send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 600));
            continue;
          }
          throw Exception('AI 出题失败: ${response.statusCode} $body');
        }
        break;
      } catch (e) {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        rethrow;
      }
    }
    if (response == null) throw Exception('AI 出题失败：无法连接');

    var buffer = '';
    var accumulated = '';
    await for (final chunk in utf8.decoder.bind(response.stream)) {
      buffer += chunk;
      // 按行切分 SSE
      while (buffer.contains('\n')) {
        final lineEnd = buffer.indexOf('\n');
        final line = buffer.substring(0, lineEnd).trim();
        buffer = buffer.substring(lineEnd + 1);

        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final delta = json['choices']?[0]?['delta']?['content'] as String?;
          if (delta != null && delta.isNotEmpty) {
            accumulated += delta;
            onDelta(accumulated);
          }
        } catch (_) {
          // 跳过格式异常的行
        }
      }
    }

    if (accumulated.isEmpty) {
      throw Exception('AI 返回为空，请检查 API Key 或模型名');
    }
    return AnthropicAiService.parseMarkdownResponse(accumulated);
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

  @override
  Future<GeneratedQuestion> generateQuestionStream(
    String prompt,
    void Function(String accumulated) onDelta,
  ) async {
    // Anthropic 暂退化为非流式
    return generateQuestion(prompt);
  }

  /// 解析 build_prompt 中约定的 Markdown 返回格式：
  /// ## 题目 / ## 选项 / ## 答案 / ## 解析 / ## 系数。
  static GeneratedQuestion parseMarkdownResponse(String text) {
    String extractSection(String header, String stopHeaderPattern) {
      final pattern = RegExp(
        '##\\s*$header\\s*\\n(.*?)(?=\\n##\\s*(?:$stopHeaderPattern)|\$)',
        dotAll: true,
      );
      final match = pattern.firstMatch(text);
      return match?.group(1)?.trim() ?? '';
    }

    final content = extractSection('题目', '选项|答案|解析|系数');
    final optionsSection = extractSection('选项', '答案|解析|系数');
    final answerSection = extractSection('答案', '解析|系数');
    final explanation = extractSection('解析', '系数');
    final coefSection = extractSection('系数', r'.^');

    double? extractCoef(String label) {
      final m = RegExp('$label[：:]\\s*([0-9.]+)').firstMatch(coefSection);
      if (m == null) return null;
      return double.tryParse(m.group(1)!);
    }

    // 解析选项行：A. xxx / A.xxx / A、xxx
    final options = <String>[];
    for (final line in optionsSection.split('\n')) {
      final m = RegExp(r'^\s*[A-D][.、)．]\s*(.+)$').firstMatch(line.trim());
      if (m != null) options.add(m.group(1)!.trim());
    }

    // 答案可能是单个大写字母（A-D）或选项文本 → 统一成选项文本
    String? correctText;
    final letter = answerSection.trim().toUpperCase();
    if (RegExp(r'^[A-D]$').hasMatch(letter) && letter.isNotEmpty) {
      final idx = letter.codeUnitAt(0) - 'A'.codeUnitAt(0);
      if (idx < options.length) correctText = options[idx];
    }
    if (correctText == null && answerSection.isNotEmpty) {
      correctText = answerSection.trim();
    }

    return GeneratedQuestion(
      content: content.isEmpty ? text : content,
      answer: correctText ?? answerSection,
      options: options,
      correctAnswer: correctText ?? answerSection,
      explanation: explanation.isEmpty ? null : explanation,
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
  /// 未配置 AI 时的兜底单选题。
  static const List<String> _mockOptions = [
    '选项 A（示例）',
    '选项 B（示例）',
    '选项 C（示例）',
    '选项 D（示例）',
  ];

  @override
  Future<GeneratedQuestion> generateQuestion(String prompt) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return GeneratedQuestion(
      content: '（示例题目，尚未配置 AI 接口，请先在设置中配置）\n\n$prompt',
      answer: _mockOptions.first,
      options: _mockOptions,
      correctAnswer: _mockOptions.first,
      explanation: '这是占位示例题目。配置真实的 AI 接口后，会为你生成对应知识点的单选题。',
      cplxCoef: 0.4,
      undCoef: 0.4,
      redCoef: 0.2,
      covCoef: 0.3,
    );
  }

  @override
  Future<GeneratedQuestion> generateQuestionStream(
    String prompt,
    void Function(String accumulated) onDelta,
  ) async {
    final text = '（示例题目，尚未配置 AI 接口，请先在设置中配置）\n\n$prompt';
    for (var i = 1; i <= text.length; i += 20) {
      onDelta(text.substring(0, i));
      await Future.delayed(const Duration(milliseconds: 30));
    }
    return GeneratedQuestion(
      content: text,
      answer: _mockOptions.first,
      options: _mockOptions,
      correctAnswer: _mockOptions.first,
      explanation: '这是占位示例题目。配置真实的 AI 接口后，会为你生成对应知识点的单选题。',
      cplxCoef: 0.4,
      undCoef: 0.4,
      redCoef: 0.2,
      covCoef: 0.3,
    );
  }
}
