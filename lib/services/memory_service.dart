import '../db/database_helper.dart';

/// 长期记忆系统 — 结构化存储 + 按相关性检索。
///
/// 与三一的 JSON append 不同，这里用 SQLite：
/// - 按 type 分类（fact/insight/preference/concept）
/// - 按 weight 排序（重要程度）
/// - 按 content LIKE 搜索
/// - 自动记录访问时间用于新鲜度排序
class MemoryService {
  /// 保存一条记忆
  static Future<void> save({
    required String content,
    String type = 'fact',
    double weight = 1.0,
    String? tags,
    String source = 'agent',
  }) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('memories', {
      'type': type,
      'content': content,
      'weight': weight,
      'tags': tags,
      'source': source,
    });
  }

  /// 搜索记忆（按关键词 + 权重排序）
  static Future<List<Map<String, dynamic>>> search(String query, {int limit = 5}) async {
    final db = await DatabaseHelper.instance.database;
    final results = await db.rawQuery('''
      SELECT * FROM memories
      WHERE content LIKE ?
      ORDER BY weight DESC, last_accessed_at DESC
      LIMIT ?
    ''', ['%$query%', limit]);
    // 更新访问时间
    for (final r in results) {
      await db.update('memories', {'last_accessed_at': DateTime.now().toUtc().toIso8601String()},
        where: 'id = ?', whereArgs: [r['id']]);
    }
    return results;
  }

  /// 获取高权重记忆（供 agent 上下文使用）
  static Future<List<Map<String, dynamic>>> getTop({int limit = 10}) async {
    final db = await DatabaseHelper.instance.database;
    return db.rawQuery('''
      SELECT * FROM memories
      ORDER BY weight DESC, last_accessed_at DESC
      LIMIT ?
    ''', [limit]);
  }

  /// 获取最近的记忆
  static Future<List<Map<String, dynamic>>> getRecent({int limit = 10}) async {
    final db = await DatabaseHelper.instance.database;
    return db.query('memories', orderBy: 'created_at DESC', limit: limit);
  }

  /// 自动从对话中提取并保存记忆
  static Future<void> extractFromConversation(String userMsg, String assistantMsg) async {
    // 简单启发式：如果回答中包含重要的知识点信息，存为记忆
    final keyPhrases = ['重点是', '关键是', '记住', '公式是', '定义是', '原理是', '特点是'];
    for (final phrase in keyPhrases) {
      final idx = assistantMsg.indexOf(phrase);
      if (idx != -1) {
        final snippet = assistantMsg.substring(idx, (idx + 80).clamp(0, assistantMsg.length)).trim();
        if (snippet.length > 10) {
          await save(
            content: snippet,
            type: 'insight',
            weight: 1.5,
            source: 'chat_extract',
          );
        }
        break;
      }
    }
  }

  /// 构建记忆上下文块（供 system prompt 使用）
  static Future<String> buildContext() async {
    final top = await getTop(limit: 8);
    if (top.isEmpty) return '';
    return '## 长期记忆\n\n${top.map((m) => '- [${m['type']}] ${m['content']}').join('\n')}';
  }
}
