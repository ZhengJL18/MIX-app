import 'dart:convert';

import '../repository/kp_repository.dart';
import '../repository/question_repository.dart';
import '../repository/subject_repository.dart';

/// 对应设计文档 5.1 种子题 + 文件结构里的 seed_data.py：
/// 批量导入"科目 -> 知识点 -> 种子题"的 JSON 数据。
///
/// JSON 结构示例：
/// ```json
/// [
///   {
///     "subject": "药理学",
///     "knowledge_points": [
///       {
///         "name": "药物代谢动力学",
///         "seed_questions": [
///           {"content": "...", "answer": "..."}
///         ]
///       }
///     ]
///   }
/// ]
/// ```
class SeedDataService {
  SeedDataService({
    SubjectRepository? subjectRepo,
    KpRepository? kpRepo,
    QuestionRepository? questionRepo,
  })  : _subjectRepo = subjectRepo ?? SubjectRepository(),
        _kpRepo = kpRepo ?? KpRepository(),
        _questionRepo = questionRepo ?? QuestionRepository();

  final SubjectRepository _subjectRepo;
  final KpRepository _kpRepo;
  final QuestionRepository _questionRepo;

  /// 从 JSON 字符串导入。已存在同名科目则复用，不会重复创建。
  Future<void> importFromJson(String jsonStr) async {
    final data = jsonDecode(jsonStr) as List<dynamic>;
    final existingSubjects = await _subjectRepo.getAllSubjects();
    final subjectByName = {for (final s in existingSubjects) s['name'] as String: s['id'] as int};

    for (final subjectEntry in data) {
      final subjectName = subjectEntry['subject'] as String;
      int subjectId;
      if (subjectByName.containsKey(subjectName)) {
        subjectId = subjectByName[subjectName]!;
      } else {
        subjectId = await _subjectRepo.insertSubject(name: subjectName);
        subjectByName[subjectName] = subjectId;
      }

      final kps = subjectEntry['knowledge_points'] as List<dynamic>? ?? [];
      final existingKps = await _kpRepo.getKpsBySubject(subjectId);
      final kpByName = {for (final k in existingKps) k['name'] as String: k['id'] as int};

      for (final kpEntry in kps) {
        final kpName = kpEntry['name'] as String;
        int kpId;
        if (kpByName.containsKey(kpName)) {
          kpId = kpByName[kpName]!;
        } else {
          kpId = await _kpRepo.insertKp(subjectId: subjectId, name: kpName);
        }

        final seedQuestions = kpEntry['seed_questions'] as List<dynamic>? ?? [];
        for (final q in seedQuestions) {
          await _questionRepo.insertQuestion(
            kpId: kpId,
            content: q['content'] as String,
            answer: q['answer'] as String,
            isSeed: true,
          );
        }
      }
    }
  }
}
