import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;

import '../config/config.dart';

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
        'anthropic-version': EngineConstants.aiApiVersion,
      },
      body: jsonEncode({
        'model': EngineConstants.defaultAiModel,
        // 系数已经挪到答案前面，被截断的风险现在只会落在答案身上；
        // 这里仍然留出比之前更宽松的余量，减少长答案（如药理学机制解释）被截断的概率。
        'max_tokens': 1536,
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
  /// ## 题目 / ## 系数 / ## 答案（顺序与 prompt_builder.dart 的模板严格对应，
  /// 系数被放在答案之前，是为了让"回复被截断"这种情况只影响答案，不影响
  /// 用来更新掌握度模型的四维系数）。
  static GeneratedQuestion parseMarkdownResponse(String text) {
    String extractSection(String header, String stopHeaderPattern) {
      final pattern = RegExp(
        '##\\s*$header\\s*\\n(.*?)(?=\\n##\\s*(?:$stopHeaderPattern)|\$)',
        dotAll: true,
      );
      final match = pattern.firstMatch(text);
      return match?.group(1)?.trim() ?? '';
    }

    final content = extractSection('题目', '系数|答案');
    final coefSection = extractSection('系数', '答案');
    final answer = extractSection('答案', r'.^');

    double? extractCoef(String label) {
      final m = RegExp('$label[：:]\\s*([0-9.]+)').firstMatch(coefSection);
      if (m == null) return null;
      return double.tryParse(m.group(1)!);
    }

    final cplx = extractCoef('复杂度');
    final und = extractCoef('理解难度');
    final red = extractCoef('冗余度');
    final cov = extractCoef('覆盖率');

    // 四个系数要么全部解析成功，要么全部视为缺失——不允许"部分解析成功、
    // 部分用默认值顶上"的中间态，避免看起来像真实数据的噪声悄悄污染
    // kp_user_state（参见与用户的讨论：默认值和解析失败的缺失不是一回事）。
    final allPresent = cplx != null && und != null && red != null && cov != null;

    return GeneratedQuestion(
      content: content.isEmpty ? text : content,
      answer: answer.isEmpty ? '(AI 未返回答案，请重新生成本题)' : answer,
      cplxCoef: allPresent ? cplx : null,
      undCoef: allPresent ? und : null,
      redCoef: allPresent ? red : null,
      covCoef: allPresent ? cov : null,
    );
  }
}

/// 离线/演示用的假实现：不联网，直接基于知识点生成占位题目。
/// 在没有配置 API Key 时用它兜底，保证 App 仍可运行、可演示流程。
/// 注：Mock 随机返回 null 系数，以覆盖"系数缺失→等量 bonus 回退"路径，
/// 确保生产环境中 AI 返回截断/格式错误时不会静默吞异常。
class MockAiService implements AiService {
  final _rand = math.Random(42); // 固定种子保证演示可重现

  @override
  Future<GeneratedQuestion> generateQuestion(String prompt) async {
    await Future.delayed(const Duration(milliseconds: 300));

    // 约 30% 概率产生缺系数的题目，覆盖差异化更新回退到等量 bonus 的路径
    final hasCoefs = _rand.nextDouble() > 0.3;

    return GeneratedQuestion(
      content: '（示例题目，尚未配置 AI 接口）\n\n$prompt',
      answer: '（示例答案，请在设置中配置 AI 接口以获取真实题目）',
      cplxCoef: hasCoefs ? 0.4 : null,
      undCoef: hasCoefs ? 0.4 : null,
      redCoef: hasCoefs ? 0.2 : null,
      covCoef: hasCoefs ? 0.3 : null,
    );
  }
}
