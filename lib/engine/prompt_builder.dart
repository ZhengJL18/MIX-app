import '../repository/kp_repository.dart';
import '../services/student_portrait_service.dart';

/// 对应设计文档 4.3 第三层：生成提示词。
///
/// v2（画像驱动）：不再把裸数字四维（复杂度/理解度/冗余度/覆盖度）塞给 AI，
/// 而是注入"学科画像(0号文件) + 近20题日志"。AI 看的是人话，不是数据。
class PromptBuilder {
  PromptBuilder({
    KpRepository? kpRepo,
    StudentPortraitService? portraitService,
  })  : _kpRepo = kpRepo ?? KpRepository(),
        _portraitService = portraitService ?? StudentPortraitService();

  final KpRepository _kpRepo;
  final StudentPortraitService _portraitService;

  Future<String> buildPrompt({
    required int kpId,
    required Map<String, dynamic> subject,
    required Map<String, dynamic> state,
  }) async {
    final kpName = await _kpRepo.getKpName(kpId) ?? '(未知知识点)';
    final userId = (state['user_id'] as num).toInt();
    final subjectId = (subject['id'] as num).toInt();

    final profile = await _portraitService.ensureProfile(
      userId: userId,
      subjectId: subjectId,
    );
    final recent = await _portraitService.recentLog(
      userId: userId,
      subjectId: subjectId,
    );

    return '''你是「${subject['name']}」老师，为学生生成一道单选题。

【学生学科画像】
$profile

【学生近况】
$recent

本次要考察的知识点：$kpName

要求：
1. 针对画像中的薄弱点与易错模式出题。
2. 难度匹配学生当前水平（参考画像中的推荐难度）。
3. 不要重复近况中已出现过的题型/考点。
4. 必须包含 4 个选项（A/B/C/D），且只有一个正确选项，干扰项合理。

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
