import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../db/database_helper.dart';

/// 文件管理 — 三个板块：讲义、笔记、题目&解析
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  Map<String, List<Map<String, dynamic>>> _subjectsWithKps = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await DatabaseHelper.instance.database;
    final subjects = await db.query('subjects', orderBy: 'id ASC');
    final result = <String, List<Map<String, dynamic>>>{};

    for (final subj in subjects) {
      final sid = subj['id'] as int;
      final name = subj['name'] as String;
      final kps = await db.query('knowledge_points',
        where: 'subject_id = ?', whereArgs: [sid]);
      result[name] = kps;
    }

    if (mounted) setState(() { _subjectsWithKps = result; _loaded = true; });
  }

  Future<List<File>> _quickNotes() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'MIX', '_quick_notes'));
    if (!await dir.exists()) return [];
    final all = await dir.list().toList();
    final files = all.whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!_loaded) return Scaffold(
      backgroundColor: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7),
      body: const Center(child: CircularProgressIndicator(color: Color(0xFFFF8C42))),
    );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7),
        appBar: AppBar(
          title: const Text('文件管理'),
          bottom: const TabBar(
            labelColor: Color(0xFFFF8C42),
            unselectedLabelColor: Colors.grey,
            indicatorColor: Color(0xFFFF8C42),
            tabs: [
              Tab(icon: Icon(Icons.menu_book), text: '讲义'),
              Tab(icon: Icon(Icons.note), text: '笔记'),
              Tab(icon: Icon(Icons.quiz), text: '题目'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildLessons(isDark),
            _buildNotes(isDark),
            _buildQuestions(isDark),
          ],
        ),
      ),
    );
  }

  /// 板块1：讲义 — 按科目列出知识点
  Widget _buildLessons(bool isDark) {
    if (_subjectsWithKps.isEmpty) {
      return _emptyHint(isDark, '还没有科目，先去科目管理创建');
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: _subjectsWithKps.entries.map((entry) {
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: ExpansionTile(
            leading: const Icon(Icons.folder, color: Color(0xFFFF8C42)),
            title: Text(entry.key,
                style: TextStyle(fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF3A3A3A))),
            subtitle: Text('${entry.value.length} 个知识点',
                style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : const Color(0xFF8A7A6A))),
            children: entry.value.isEmpty
                ? [Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('暂无知识点', style: TextStyle(color: isDark ? Colors.white24 : const Color(0xFFC0B8A8))),
                  )]
                : entry.value.map((kp) => ListTile(
                    dense: true,
                    leading: const Icon(Icons.check_circle_outline, size: 18, color: Color(0xFFFF8C42)),
                    title: Text(kp['name'] as String,
                        style: TextStyle(fontSize: 14, color: isDark ? Colors.white70 : const Color(0xFF3A3A3A))),
                  )).toList(),
          ),
        );
      }).toList(),
    );
  }

  /// 板块2：笔记 — 快速笔记列表
  Widget _buildNotes(bool isDark) {
    return FutureBuilder<List<File>>(
      future: _quickNotes(),
      builder: (context, snap) {
        final notes = snap.data ?? [];
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFFFF8C42)));
        if (notes.isEmpty) return _emptyHint(isDark, '还没有笔记，在"笔记"页面随手记');

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: notes.length,
          itemBuilder: (_, i) {
            final file = notes[i];
            final t = file.lastModifiedSync();
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: const Icon(Icons.description, color: Color(0xFFFF8C42)),
                title: Text('${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(fontSize: 14, color: isDark ? Colors.white : const Color(0xFF3A3A3A))),
                subtitle: Text('${(file.lengthSync() ~/ 100)} 字',
                    style: TextStyle(fontSize: 12, color: isDark ? Colors.white38 : const Color(0xFF8A7A6A))),
              ),
            );
          },
        );
      },
    );
  }

  /// 板块3：题目 — 按科目列出题目数 + 解析
  Widget _buildQuestions(bool isDark) {
    if (_subjectsWithKps.isEmpty) return _emptyHint(isDark, '还没有题目数据');

    return FutureBuilder<List<Widget>>(
      future: _buildQuestionCards(isDark),
      builder: (context, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: Color(0xFFFF8C42)));
        final cards = snap.data!;
        if (cards.isEmpty) return _emptyHint(isDark, '还没有题目');
        return ListView(padding: const EdgeInsets.all(16), children: cards);
      },
    );
  }

  Future<List<Widget>> _buildQuestionCards(bool isDark) async {
    final db = await DatabaseHelper.instance.database;
    final cards = <Widget>[];
    for (final entry in _subjectsWithKps.entries) {
      final sid = await db.query('subjects',
        where: 'name = ?', whereArgs: [entry.key]);
      if (sid.isEmpty) continue;
      final subjId = sid.first['id'] as int;
      final qCount = await db.rawQuery(
        'SELECT COUNT(*) as c FROM questions WHERE subject_id = ?', [subjId]);
      final count = qCount.first['c'] as int? ?? 0;
      final seedCount = await db.rawQuery(
        'SELECT COUNT(*) as c FROM questions WHERE subject_id = ? AND is_seed = 1', [subjId]);
      final seeds = seedCount.first['c'] as int? ?? 0;

      cards.add(Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(
          leading: const Icon(Icons.quiz, color: Color(0xFFFF8C42)),
          title: Text(entry.key,
              style: TextStyle(fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : const Color(0xFF3A3A3A))),
          subtitle: Text(
            '共 $count 题（种子题 $seeds 道）',
            style: TextStyle(fontSize: 13, color: isDark ? Colors.white38 : const Color(0xFF8A7A6A)),
          ),
        ),
      ));
    }
    return cards;
  }

  Widget _emptyHint(bool isDark, String msg) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.info_outline, size: 48, color: isDark ? Colors.white24 : const Color(0xFFB0A090)),
          const SizedBox(height: 12),
          Text(msg, style: TextStyle(color: isDark ? Colors.white38 : const Color(0xFF8A7A6A))),
        ],
      ),
    );
  }
}
