import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 随手记 — PageView 第三页，快速记录灵感/想法
class QuickNotesScreen extends StatefulWidget {
  const QuickNotesScreen({super.key});

  @override
  State<QuickNotesScreen> createState() => _QuickNotesScreenState();
}

class _QuickNotesScreenState extends State<QuickNotesScreen> {
  List<File> _notes = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Directory> _notesDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, 'MIX', '_quick_notes'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<void> _load() async {
    final dir = await _notesDir();
    final files = dir.list().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (mounted) setState(() { _notes = files; _loaded = true; });
  }

  Future<void> _createNote() async {
    final controller = TextEditingController();
    final content = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建笔记'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '写点什么...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (content == null || content.isEmpty) return;
    final dir = await _notesDir();
    final now = DateTime.now();
    final file = File(p.join(dir.path, '${now.millisecondsSinceEpoch}.md'));
    await file.writeAsString('## ${now.month}月${now.day}日 ${now.hour}:${now.minute.toString().padLeft(2, '0')}\n\n$content');
    await _load();
  }

  Future<void> _deleteNote(File file) async {
    await file.delete();
    await _load();
  }

  Future<void> _viewNote(File file) async {
    final content = await file.readAsString();
    if (!mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7),
        appBar: AppBar(title: Text(p.basenameWithoutExtension(file.path))),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: SelectableText(content, style: TextStyle(
            fontSize: 15, height: 1.6,
            color: isDark ? Colors.white70 : const Color(0xFF3A3A3A),
          )),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7);
    final muted = isDark ? Colors.white38 : const Color(0xFFB0A090);
    final dim = isDark ? Colors.white24 : const Color(0xFFC0B8A8);

    return Container(
      color: bg,
      child: !_loaded
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF8C42)))
          : Column(
              children: [
                // 头部
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Text('随手记', style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : const Color(0xFF3A3A3A),
                      )),
                      const Spacer(),
                      GestureDetector(
                        onTap: _createNote,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF8C42),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, size: 16, color: Colors.white),
                              SizedBox(width: 4),
                              Text('新建', style: TextStyle(color: Colors.white, fontSize: 14)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_notes.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_note, size: 64, color: muted),
                          const SizedBox(height: 12),
                          Text('还没有笔记', style: TextStyle(color: muted)),
                          const SizedBox(height: 4),
                          Text('点"新建"开始记录', style: TextStyle(color: dim, fontSize: 13)),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _notes.length,
                      itemBuilder: (_, i) {
                        final file = _notes[i];
                        final time = file.lastModifiedSync();
                        final label = '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: const Icon(Icons.description, color: Color(0xFFFF8C42)),
                            title: Text(label, style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600,
                              color: isDark ? Colors.white : const Color(0xFF3A3A3A),
                            )),
                            subtitle: Text('${(file.lengthSync() ~/ 100)} 字',
                                style: TextStyle(fontSize: 12, color: muted)),
                            trailing: IconButton(
                              icon: Icon(Icons.delete_outline, size: 18, color: Colors.red[300]),
                              onPressed: () => _deleteNote(file),
                            ),
                            onTap: () => _viewNote(file),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}
