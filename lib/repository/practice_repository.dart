import '../db/database_helper.dart';

class PracticeRepository {
  Future<int> insertRecord({
    required int userId,
    required int questionId,
    required bool correct,
    String? mainCause,
    String? minorCause,
  }) async {
    final db = await DatabaseHelper.instance.database;
    return db.insert('practice_records', {
      'user_id': userId,
      'question_id': questionId,
      'correct': correct ? 1 : 0,
      'main_cause': mainCause,
      'minor_cause': minorCause,
    });
  }

  Future<List<Map<String, dynamic>>> getRecentByUser(int userId, {int limit = 50}) async {
    final db = await DatabaseHelper.instance.database;
    return db.query(
      'practice_records',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'id DESC',
      limit: limit,
    );
  }

  Future<int> countTotalByUser(int userId) async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM practice_records WHERE user_id = ?',
      [userId],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  Future<int> countCorrectByUser(int userId) async {
    final db = await DatabaseHelper.instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM practice_records WHERE user_id = ? AND correct = 1',
      [userId],
    );
    return (result.first['c'] as int?) ?? 0;
  }

  /// 最近 [limit] 道题涉及的科目 id，按时间倒序（最新的在前）。
  /// 用于第一层选科目的"新鲜度"计算（4.1 recent_subjects）。
  Future<List<int>> getRecentSubjectIds(int userId, {required int limit}) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT kp.subject_id AS subject_id
      FROM practice_records pr
      JOIN questions q ON q.id = pr.question_id
      JOIN knowledge_points kp ON kp.id = q.kp_id
      WHERE pr.user_id = ?
      ORDER BY pr.id DESC
      LIMIT ?
    ''', [userId, limit]);
    return rows.map((r) => r['subject_id'] as int).toList();
  }

  /// 某科目下是否有做题记录。用于统计页区分"未开始"与真实掌握度。
  Future<bool> hasRecordsForSubject(int userId, int subjectId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) as c FROM practice_records pr
      JOIN questions q ON q.id = pr.question_id
      JOIN knowledge_points kp ON kp.id = q.kp_id
      WHERE pr.user_id = ? AND kp.subject_id = ?
    ''', [userId, subjectId]);
    return (rows.first['c'] as int? ?? 0) > 0;
  }

  /// 最近做错的题（含题目、答案、解析、科目/知识点），按时间倒序去重。
  /// 用于「错题回顾」。
  Future<List<Map<String, dynamic>>> getRecentWrongQuestions(int userId, {int limit = 50}) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT q.id, q.content, q.answer, q.options, q.explanation,
             kp.name AS kp_name, s.name AS subject_name,
             MAX(pr.id) AS last_wrong_id
      FROM practice_records pr
      JOIN questions q ON q.id = pr.question_id
      JOIN knowledge_points kp ON kp.id = q.kp_id
      JOIN subjects s ON s.id = kp.subject_id
      WHERE pr.user_id = ? AND pr.correct = 0
      GROUP BY q.id
      ORDER BY last_wrong_id DESC
      LIMIT ?
    ''', [userId, limit]);
    return rows;
  }
}
