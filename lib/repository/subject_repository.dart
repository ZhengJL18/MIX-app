import '../db/database_helper.dart';

/// 科目表 CRUD。返回 `Map` 而非强类型对象——
/// 与设计文档"权重属科目字段，数据全在 SQLite"的原则一致，
/// 上层算法直接按列名取值，避免维护一份重复的强类型 Subject 大类。
class SubjectRepository {
  Future<int> insertSubject({
    required String name,
    double importance = 0.4,
    double wComplexity = 0.4,
    double wUnderstand = 0.3,
    double wRedundancy = 0.1,
    double wCoverage = 0.2,
    double targetMastery = 0.9,
    double masteryInitial = 0.3,
    double ebbinghausBase = 30,
    double ebbinghausPower = 3,
    double fbCorrectBonus = 0.3,
    double fbMainPenalty = 0.2,
    double fbMinorPenalty = 0.05,
  }) async {
    final db = await DatabaseHelper.instance.database;
    return db.insert('subjects', {
      'name': name,
      'importance': importance,
      'w_complexity': wComplexity,
      'w_understand': wUnderstand,
      'w_redundancy': wRedundancy,
      'w_coverage': wCoverage,
      'target_mastery': targetMastery,
      'mastery_initial': masteryInitial,
      'ebbinghaus_base': ebbinghausBase,
      'ebbinghaus_power': ebbinghausPower,
      'fb_correct_bonus': fbCorrectBonus,
      'fb_main_penalty': fbMainPenalty,
      'fb_minor_penalty': fbMinorPenalty,
    });
  }

  Future<List<Map<String, dynamic>>> getAllSubjects() async {
    final db = await DatabaseHelper.instance.database;
    return db.query('subjects', orderBy: 'id ASC');
  }

  Future<Map<String, dynamic>?> getSubjectById(int id) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('subjects', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// AI 微调预留接口：一键调整某科目权重，对应设计文档第九节。
  Future<int> updateWeights(int subjectId, Map<String, double> weightUpdates) async {
    final db = await DatabaseHelper.instance.database;
    return db.update('subjects', weightUpdates, where: 'id = ?', whereArgs: [subjectId]);
  }

  Future<int> deleteSubject(int id) async {
    final db = await DatabaseHelper.instance.database;
    return db.delete('subjects', where: 'id = ?', whereArgs: [id]);
  }
}
