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

  /// 取某知识点尚未被该用户做过的种子题（冷启动用），没有则返回 null。
  Future<Map<String, dynamic>?> getUnusedSeedQuestion(int kpId, int userId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT q.* FROM questions q
      WHERE q.kp_id = ? AND q.is_seed = 1
      AND q.id NOT IN (
        SELECT question_id FROM practice_records WHERE user_id = ?
      )
      LIMIT 1
    ''', [kpId, userId]);
    return rows.isEmpty ? null : rows.first;
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
