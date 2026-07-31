import '../repository/kp_repository.dart';
import '../repository/question_repository.dart';
import 'mastery.dart';

/// 对应设计文档 4.3 第三层：生成提示词。
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
    String errorDistStr = errorDist.entries
        .map((e) => '${e.key}(${e.value}次)')
        .join('，');
    if (errorDistStr.isNotEmpty) {
      errorDistStr = '\n历史错因分布：$errorDistStr';
    }
    final kpName = await _kpRepo.getKpName(kpId) ?? '(未知知识点)';
    final composite = compositeMastery(state, subject);

    final complexity = (state['complexity'] as num).toDouble();
    final understand = (state['understand'] as num).toDouble();
    final redundancy = (state['redundancy'] as num).toDouble();
    final coverage = (state['coverage'] as num).toDouble();

    return '''请为以下知识点生成一道单选题：

科目：${subject['name']}
知识点：$kpName

学生当前状态：
- 处理步骤复杂度：${complexity.toStringAsFixed(2)}
- 理解难度：${understand.toStringAsFixed(2)}
- 信息冗余度：${redundancy.toStringAsFixed(2)}
- 知识覆盖率：${coverage.toStringAsFixed(2)}
- 综合掌握度：${composite.toStringAsFixed(2)}
$errorDistStr

要求：生成一道单选题，必须包含 4 个选项（A/B/C/D），且只有一个正确选项。难度与知识点匹配，干扰项合理。

请严格按以下 Markdown 格式返回：
## 题目
[题干]

## 选项
A. [选项A]
B. [选项B]
C. [选项C]
D. [选项D]

## 答案
[A/B/C/D 单个大写字母]

## 解析
[简要解析，说明为什么选它]

## 系数
- 复杂度：X.XX
- 理解难度：X.XX
- 冗余度：X.XX
- 覆盖率：X.XX
''';
  }
}
