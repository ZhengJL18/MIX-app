import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// 本地文件仓库 — 每个科目一个文件夹，放在 App 文档目录下。
///
/// 结构：
///   documents/MIX/
///   ├── 科目名/
///   │   ├── 知识点名.md         ← 讲义/笔记
///   │   ├── 题目.md             ← 生成的题目归档
///   │   └── 素材/               ← 上传的资料
///   └── 笔记/                   ← 自由笔记
class VaultService {
  VaultService._();
  static final VaultService instance = VaultService._();

  Directory? _root;

  Future<Directory> get root async {
    if (_root != null) return _root!;
    final appDir = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(appDir.path, 'MIX'));
    if (!await _root!.exists()) await _root!.create(recursive: true);
    return _root!;
  }

  /// 创建科目文件夹（含子目录）
  Future<void> ensureSubject(String name) async {
    final r = await root;
    final dir = Directory(p.join(r.path, name));
    if (!await dir.exists()) await dir.create(recursive: true);
    final materials = Directory(p.join(dir.path, '素材'));
    if (!await materials.exists()) await materials.create();
  }

  /// 列出所有科目文件夹
  Future<List<FileSystemEntity>> listSubjects() async {
    final r = await root;
    return r.list().toList();
  }

  /// 读取一个科目文件夹内的内容
  Future<List<FileSystemEntity>> listSubjectFiles(String subjectName) async {
    final r = await root;
    final dir = Directory(p.join(r.path, subjectName));
    if (!await dir.exists()) return [];
    return dir.list().toList();
  }

  /// 写笔记 / 讲义文件
  Future<File> writeFile(String subjectName, String fileName, String content) async {
    final r = await root;
    final file = File(p.join(r.path, subjectName, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  /// 读文件内容
  Future<String?> readFile(String subjectName, String fileName) async {
    final r = await root;
    final file = File(p.join(r.path, subjectName, fileName));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// 删除科目文件夹
  Future<void> deleteSubject(String name) async {
    final r = await root;
    final dir = Directory(p.join(r.path, name));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// 获取文件大小（友好格式）
  Future<String> fileSize(String subjectName, String fileName) async {
    final r = await root;
    final file = File(p.join(r.path, subjectName, fileName));
    if (!await file.exists()) return '-';
    final bytes = await file.length();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
