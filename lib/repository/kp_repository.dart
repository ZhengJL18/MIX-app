import '../db/database_helper.dart';

class KpRepository {
  Future<int> insertKp({required int subjectId, required String name}) async {
    final db = await DatabaseHelper.instance.database;
    return db.insert('knowledge_points', {'subject_id': subjectId, 'name': name});
  }

  Future<List<Map<String, dynamic>>> getKpsBySubject(int subjectId) async {
    final db = await DatabaseHelper.instance.database;
    return db.query('knowledge_points', where: 'subject_id = ?', whereArgs: [subjectId]);
  }

  Future<Map<String, dynamic>?> getKpById(int id) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('knowledge_points', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> getKpName(int id) async {
    final row = await getKpById(id);
    return row?['name'] as String?;
  }

  Future<int> deleteKp(int id) async {
    final db = await DatabaseHelper.instance.database;
    return db.delete('knowledge_points', where: 'id = ?', whereArgs: [id]);
  }
}
