import 'dart:convert';

import '../db/database_helper.dart';

class QuestionRepository {
  Future<int> insertQuestion({
    required int kpId,
    required String content,
    required String answer,
    List<String>? options,
    String? explanation,
    double? cplxCoef,
    double? undCoef,
    double? redCoef,
    double? covCoef,
    bool isSeed = false,
  }) async {
    final db = await DatabaseHelper.instance.database;
    return db.insert('questions', {
      'kp_id': kpId,
      'content': content,
      'answer': answer,
      'options': options != null ? jsonEncode(options) : null,
      'explanation': explanation,
      'cplx_coef': cplxCoef,
      'und_coef': undCoef,
      'red_coef': redCoef,
      'cov_coef': covCoef,
      'is_seed': isSeed ? 1 : 0,
    });
  }

  Future<Map<String, dynamic>?> getById(int id) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('questions', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// 某题所属科目 id（questions → knowledge_points.subject_id）。
  /// 提交作答时用本题自己的科目，而不是"当前正在显示的科目"，
  /// 避免多题队列里游标移动后张冠李戴。
  Future<int?> getSubjectIdOfQuestion(int questionId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT kp.subject_id AS subject_id
      FROM questions q
      JOIN knowledge_points kp ON kp.id = q.kp_id
      WHERE q.id = ?
    ''', [questionId]);
    return rows.isEmpty ? null : (rows.first['subject_id'] as num).toInt();
  }

  /// 该知识点历史错因分布，喂给 AI 出题提示词（3.4 build_prompt 用）。
  Future<Map<String, int>> getErrorDistribution(int kpId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT pr.main_cause AS cause, COUNT(*) AS cnt
      FROM practice_records pr
      JOIN questions q ON q.id = pr.question_id
      WHERE q.kp_id = ? AND pr.correct = 0 AND pr.main_cause IS NOT NULL
      GROUP BY pr.main_cause
    ''', [kpId]);
    return {for (final r in rows) r['cause'] as String: r['cnt'] as int};
  }
}
