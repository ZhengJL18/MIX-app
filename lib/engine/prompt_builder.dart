import '../repository/kp_repository.dart';
import '../repository/question_repository.dart';
import 'mastery.dart';
import 'prompt_translator.dart';

/// 对应设计文档 4.3 第三层：生成提示词。
///
/// 胶水层职责：
/// 1. 把四维系数从 0~1 数字翻译成 AI 能理解的具象描述（PromptTranslator）
/// 2. 注入格式铁律（参照三一网站：LaTeX 包裹、Markdown 结构、不寒暄）
/// 3. 强制输出顺序（系数在答案前，截断只影响答案不影响掌握度模型）
class PromptBuilder {
  PromptBuilder({KpRepository? kpRepo, QuestionRepository? questionRepo})
      : _kpRepo = kpRepo ?? KpRepository(),
        _questionRepo = questionRepo ?? QuestionRepository();

  final KpRepository _kpRepo;
  final QuestionRepository _questionRepo;

  Future<String> buildPrompt({
    required int kpId,
    required Map<String, dynamic> subject,
    required Map<String, dynamic> state,
  }) async {
    final errorDist = await _questionRepo.getErrorDistribution(kpId);
    final kpName = await _kpRepo.getKpName(kpId) ?? '(未知知识点)';
    final composite = compositeMastery(state, subject);

    // ── 把数字翻译成 AI 看得懂的自然语言 ──
    final translator = PromptTranslator(
      complexity: (state['complexity'] as num).toDouble(),
      understand: (state['understand'] as num).toDouble(),
      redundancy: (state['redundancy'] as num).toDouble(),
      coverage: (state['coverage'] as num).toDouble(),
    );
    final dimensionDescriptions = translator.describeAll();

    // ── 错因分布翻译 ──
    final errorHint = _translateErrorDistribution(errorDist);

    return '''你是一位经验丰富的大学出题教师。请为以下知识点生成一道练习题。

## 学生当前状态

${dimensionDescriptions}

## 综合掌握度

综合掌握度：${(composite * 100).toStringAsFixed(0)}分（满分100）

## 历史错因
${errorHint}

## 格式铁律（严格遵循）

1. **所有数学公式必须用 \$...\$ 包裹**，块级公式用 \$\$...\$\$。**绝对禁止**裸写公式。
2. 用 **加粗** 标核心概念，用 - 列表组织要点。
3. 不寒暄，不写"同学你好"，直接出题。
4. 题干简洁清晰，接近真实考试风格。
5. 答案可以详细展开（含解题步骤、易错提醒）。

## 输出格式（严格按此顺序）

请以 Markdown 格式返回，且严格按以下顺序：

## 题目
[题目内容，公式用 \$...\$ 包裹]

## 系数
- 复杂度：X.XX
- 理解难度：X.XX
- 冗余度：X.XX
- 覆盖率：X.XX

## 答案
[标准答案，可以详细展开，含解题步骤]

---
科目：${subject['name']}
知识点：$kpName
出题依据：当前掌握度 ${(composite * 100).toStringAsFixed(0)}分，重点考察 ${_weakestDim(translator)}''';
  }

  /// 错因分布 → 一句话提示
  String _translateErrorDistribution(Map<String, int> errorDist) {
    if (errorDist.isEmpty) return '暂无历史错题数据。';
    final total = errorDist.values.fold(0, (a, b) => a + b);
    final lines = errorDist.entries
        .map((e) => '- ${_causeLabel(e.key)}：${e.value}次（${(e.value / total * 100).toStringAsFixed(0)}%）')
        .join('\n');
    return '学生过去做错的主要类型：\n$lines';
  }

  String _causeLabel(String cause) {
    switch (cause) {
      case 'complexity': return '步骤型错误（复杂度）';
      case 'understand': return '理解型错误';
      case 'redundancy': return '干扰型错误（冗余度）';
      case 'coverage': return '边界型错误（覆盖率）';
      default: return cause;
    }
  }

  String _weakestDim(PromptTranslator t) {
    final dims = {
      'complexity': t.complexity,
      'understand': t.understand,
      'redundancy': t.redundancy,
      'coverage': t.coverage,
    };
    final weakest = dims.entries.reduce((a, b) => a.value <= b.value ? a : b);
    switch (weakest.key) {
      case 'complexity': return '步骤复杂度方向';
      case 'understand': return '概念理解方向';
      case 'redundancy': return '抗干扰方向';
      case 'coverage': return '知识边界扩展方向';
      default: return '综合方向';
    }
  }
}
