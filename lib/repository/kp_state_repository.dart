import 'package:sqflite/sqflite.dart';

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

    // 用事务把"查是否存在 + 不存在就插入"包成一个原子操作。
    // 后台预生成（PregenerationService）和前台提交答案完全可能并发调用
    // 同一个 (userId, kpId)，之前的 query→await→insert 写法中间有 await
    // 断点，两边都可能先查到"没有记录"再各自 insert，导致 UNIQUE 约束冲突。
    // 用 ConflictAlgorithm.ignore 兜底：即使真的撞上了并发插入，也不会抛异常，
    // 而是静默忽略，随后统一走查询拿到最终那一行。
    return db.transaction((txn) async {
      final rows = await txn.query(
        'kp_user_state',
        where: 'user_id = ? AND kp_id = ?',
        whereArgs: [userId, kpId],
      );
      if (rows.isNotEmpty) return rows.first;

      final initial = (subject['mastery_initial'] as num).toDouble();
      await txn.insert(
        'kp_user_state',
        {
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
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );

      final created = await txn.query(
        'kp_user_state',
        where: 'user_id = ? AND kp_id = ?',
        whereArgs: [userId, kpId],
      );
      return created.first;
    });
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
