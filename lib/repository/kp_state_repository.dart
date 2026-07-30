import '../db/database_helper.dart';
import '../engine/mastery.dart';

class KpStateRepository {
  /// 若该用户-知识点尚无状态行，用科目的 mastery_initial 初始化四维，然后插入。
  Future<Map<String, dynamic>> getOrCreateState({
    required int userId,
    required int kpId,
    required Map<String, dynamic> subject,
  }) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'kp_user_state',
      where: 'user_id = ? AND kp_id = ?',
      whereArgs: [userId, kpId],
    );
    if (rows.isNotEmpty) return rows.first;

    final initial = (subject['mastery_initial'] as num).toDouble();
    final id = await db.insert('kp_user_state', {
      'user_id': userId,
      'kp_id': kpId,
      'complexity': initial,
      'understand': initial,
      'redundancy': initial,
      'coverage': initial,
      'streak_correct': 0,
      'streak_wrong': 0,
      'review_count': 0,
      'last_review_at': null,
      'review_interval': 1.0,
    });
    final created = await db.query('kp_user_state', where: 'id = ?', whereArgs: [id]);
    return created.first;
  }

  Future<Map<String, dynamic>?> getStateByKp(int userId, int kpId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'kp_user_state',
      where: 'user_id = ? AND kp_id = ?',
      whereArgs: [userId, kpId],
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 某科目下所有知识点的用户状态（用 JOIN 一次取出，避免 N+1 查询）。
  Future<List<Map<String, dynamic>>> getStatesForSubject(int userId, int subjectId) async {
    final db = await DatabaseHelper.instance.database;
    return db.rawQuery('''
      SELECT kp_user_state.*, knowledge_points.name AS kp_name
      FROM kp_user_state
      JOIN knowledge_points ON knowledge_points.id = kp_user_state.kp_id
      WHERE kp_user_state.user_id = ? AND knowledge_points.subject_id = ?
    ''', [userId, subjectId]);
  }

  Future<int> updateState(int id, Map<String, dynamic> fields) async {
    final db = await DatabaseHelper.instance.database;
    return db.update('kp_user_state', fields, where: 'id = ?', whereArgs: [id]);
  }

  /// 便捷方法：给一个状态行补上 effective_mastery 字段，供选点逻辑排序/过滤使用。
  Map<String, dynamic> withEffectiveMastery(
    Map<String, dynamic> stateRow,
    Map<String, dynamic> subject,
    double raw,
  ) {
    final eff = effectiveMastery(
      raw: raw,
      daysSinceReview: daysSince(stateRow['last_review_at'] as String?),
      reviewCount: (stateRow['review_count'] as num).toInt(),
      base: (subject['ebbinghaus_base'] as num).toDouble(),
      power: (subject['ebbinghaus_power'] as num).toDouble(),
    );
    return {...stateRow, 'effective_mastery': eff, 'raw_mastery': raw};
  }
}
