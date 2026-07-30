import 'dart:convert';
import 'package:http/http.dart' as http;
import '../db/database_helper.dart';
import '../services/vault_service.dart';

/// 工具注册表 — 定义 + 执行所有 Agent 可用工具。
/// 每个工具包含 name, description, input_schema（JSON Schema 格式）。
class ToolRegistry {
  /// 返回所有工具定义（供 Anthropic tools 参数使用）
  static List<Map<String, dynamic>> get definitions => [
    _tool('read_file', '读取 vault 中的一个文件（讲义/笔记/素材）', {
      'path': {'type': 'string', 'description': '文件路径，如 "药理学/知识点.md"'},
    }),
    _tool('write_file', '写入/创建文件到 vault', {
      'path': {'type': 'string', 'description': '文件路径'},
      'content': {'type': 'string', 'description': '文件内容'},
    }),
    _tool('list_dir', '列出 vault 目录下的文件和子目录', {
      'path': {'type': 'string', 'description': '目录路径，空字符串表示根目录'},
    }),
    _tool('list_subjects', '列出所有科目及其知识点数量', {}, false),
    _tool('get_subject_detail', '查看某科目的详细数据（知识点数、题目数、掌握度）', {
      'name': {'type': 'string', 'description': '科目名'},
    }),
    _tool('search_memories', '搜索长期记忆', {
      'query': {'type': 'string', 'description': '搜索关键词'},
      'limit': {'type': 'integer', 'description': '返回条数，默认 5'},
    }),
    _tool('remember', '保存一条长期记忆', {
      'content': {'type': 'string', 'description': '记忆内容'},
      'type': {'type': 'string', 'description': '记忆类型：fact/insight/preference/concept'},
      'weight': {'type': 'number', 'description': '重要程度 0~5，默认 1'},
      'tags': {'type': 'string', 'description': '逗号分隔的标签，如 "药理学,难点"'},
    }),
    _tool('fetch_url', '获取一个网页的文本内容（静默，不给用户看到浏览器）', {
      'url': {'type': 'string', 'description': '完整的网页 URL'},
    }),
    _tool('get_stats', '查看学习统计数据（总题数、正确率、各科掌握度）', {}, false),
  ];

  /// 执行工具，返回结果文本
  static Future<String> execute(String name, Map<String, dynamic> input) async {
    switch (name) {
      case 'read_file': return _readFile(input);
      case 'write_file': return _writeFile(input);
      case 'list_dir': return _listDir(input);
      case 'list_subjects': return _listSubjects();
      case 'get_subject_detail': return _getSubjectDetail(input);
      case 'search_memories': return _searchMemories(input);
      case 'remember': return _remember(input);
      case 'fetch_url': return _fetchUrl(input);
      case 'get_stats': return _getStats();
      default: return '未知工具: $name';
    }
  }

  static Map<String, dynamic> _tool(String name, String desc, Map<String, dynamic> props, [bool hasRequired = true]) {
    return {
      'name': name,
      'description': desc,
      'input_schema': {
        'type': 'object',
        'properties': props,
        if (hasRequired) 'required': props.keys.toList(),
      },
    };
  }

  // ── 工具实现 ──

  static Future<String> _readFile(Map<String, dynamic> input) async {
    final path = input['path'] as String?;
    if (path == null || path.isEmpty) return '错误：需要 path 参数';
    final parts = path.split('/');
    if (parts.length < 2) return '错误：路径格式应为 "科目名/文件名"';
    final content = await VaultService.instance.readFile(parts[0], parts.sublist(1).join('/'));
    if (content == null) return '文件不存在: $path';
    return content;
  }

  static Future<String> _writeFile(Map<String, dynamic> input) async {
    final path = input['path'] as String?;
    final content = input['content'] as String?;
    if (path == null || content == null) return '错误：需要 path 和 content 参数';
    final parts = path.split('/');
    if (parts.length < 2) return '错误：路径格式应为 "科目名/文件名"';
    await VaultService.instance.writeFile(parts[0], parts.sublist(1).join('/'), content);
    return '文件已保存: $path';
  }

  static Future<String> _listDir(Map<String, dynamic> input) async {
    final path = input['path'] as String? ?? '';
    final root = await VaultService.instance.root;
    if (path.isEmpty) {
      final entries = await VaultService.instance.listSubjects();
      if (entries.isEmpty) return '（空目录）';
      return entries.map((e) => '- ${e.path.split('\\').last}').join('\n');
    }
    final files = await VaultService.instance.listSubjectFiles(path);
    if (files.isEmpty) return '（空目录）';
    return files.map((e) => '- ${e.path.split('\\').last}').join('\n');
  }

  static Future<String> _listSubjects() async {
    final db = await DatabaseHelper.instance.database;
    final subjects = await db.query('subjects', orderBy: 'id ASC');
    if (subjects.isEmpty) return '还没有科目。';
    final lines = <String>[];
    for (final s in subjects) {
      final kps = await db.query('knowledge_points',
        where: 'subject_id = ?', whereArgs: [s['id']]);
      final qs = await db.rawQuery(
        'SELECT COUNT(*) as c FROM questions WHERE subject_id = ?', [s['id']]);
      lines.add('- ${s['name']}（${kps.length} 知识点, ${qs.first['c']} 题）');
    }
    return lines.join('\n');
  }

  static Future<String> _getSubjectDetail(Map<String, dynamic> input) async {
    final name = input['name'] as String?;
    if (name == null) return '错误：需要 name 参数';
    final db = await DatabaseHelper.instance.database;
    final subj = await db.query('subjects', where: 'name = ?', whereArgs: [name]);
    if (subj.isEmpty) return '科目 "$name" 不存在';
    final sid = subj.first['id'] as int;
    final kps = await db.query('knowledge_points', where: 'subject_id = ?', whereArgs: [sid]);
    final qs = await db.rawQuery('SELECT COUNT(*) as c FROM questions WHERE subject_id = ?', [sid]);
    final seeds = await db.rawQuery('SELECT COUNT(*) as c FROM questions WHERE subject_id = ? AND is_seed = 1', [sid]);
    final records = await db.rawQuery('''
      SELECT COUNT(*) as total, SUM(correct) as correct FROM practice_records pr
      JOIN questions q ON q.id = pr.question_id WHERE q.subject_id = ?
    ''', [sid]);
    final total = records.first['total'] as int? ?? 0;
    final correct = records.first['correct'] as int? ?? 0;
    return '''科目：$name
知识点：${kps.length} 个
题目：${qs.first['c']} 题（种子题 ${seeds.first['c']} 道）
练习记录：$total 次（正确率 ${total > 0 ? (correct / total * 100).toStringAsFixed(0) : 'N/A'}%）

知识点列表：
${kps.map((k) => '- ${k['name']}').join('\n')}''';
  }

  static Future<String> _searchMemories(Map<String, dynamic> input) async {
    final query = input['query'] as String? ?? '';
    final limit = (input['limit'] as num?)?.toInt() ?? 5;
    final db = await DatabaseHelper.instance.database;
    final results = await db.rawQuery('''
      SELECT * FROM memories WHERE content LIKE ? ORDER BY weight DESC, last_accessed_at DESC LIMIT ?
    ''', ['%$query%', limit]);
    if (results.isEmpty) return '未找到相关记忆。';
    return results.map((r) {
      final tags = r['tags'] as String?;
      return '- [${r['type']}] ${r['content']}${tags != null && tags.isNotEmpty ? ' ($tags)' : ''}（权重 ${(r['weight'] as num).toStringAsFixed(1)}）';
    }).join('\n');
  }

  static Future<String> _remember(Map<String, dynamic> input) async {
    final content = input['content'] as String?;
    if (content == null || content.isEmpty) return '错误：需要 content 参数';
    final db = await DatabaseHelper.instance.database;
    await db.insert('memories', {
      'type': input['type'] as String? ?? 'fact',
      'content': content,
      'weight': (input['weight'] as num?)?.toDouble() ?? 1.0,
      'tags': input['tags'] as String?,
      'source': 'agent',
    });
    return '已记住：$content';
  }

  static Future<String> _fetchUrl(Map<String, dynamic> input) async {
    final url = input['url'] as String?;
    if (url == null || url.isEmpty) return '错误：需要 url 参数';
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return 'HTTP ${resp.statusCode}';
      final text = utf8.decode(resp.bodyBytes);
      // 简单清洗：只保留可见文本，去 HTML 标签
      final clean = text.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      return clean.length > 3000 ? '${clean.substring(0, 3000)}...（截断，共${clean.length}字）' : clean;
    } catch (e) {
      return '抓取失败：$e';
    }
  }

  static Future<String> _getStats() async {
    final db = await DatabaseHelper.instance.database;
    final subjects = await db.query('subjects', orderBy: 'id ASC');
    if (subjects.isEmpty) return '还没有数据。';
    final totalQ = await db.rawQuery('SELECT COUNT(*) as c FROM questions');
    final totalP = await db.rawQuery('SELECT COUNT(*) as c FROM practice_records');
    final correctP = await db.rawQuery('SELECT COUNT(*) as c FROM practice_records WHERE correct = 1');
    final total = totalP.first['c'] as int? ?? 0;
    final correct = correctP.first['c'] as int? ?? 0;
    return '''总题目数：${totalQ.first['c']}
总练习次数：$total
正确率：${total > 0 ? (correct / total * 100).toStringAsFixed(1) : 'N/A'}%
科目数：${subjects.length}''';
  }
}
