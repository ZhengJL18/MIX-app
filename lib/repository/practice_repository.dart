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
}
