/// 对应 `ref/hermes-agent/tools/skills_tool.py`（像素级复刻，核心）。
///
/// skill 发现：扫描 `skills/` 目录树，解析 frontmatter，过滤，缓存元数据。
/// skill_view 查找三策略（直接路径/目录名递归/旧式 .md）+ 路径穿越校验。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'skill_parser.dart';

/// 需排除的目录名。
const Set<String> excludedSkillDirs = {
  '.git',
  'venv',
  '.venv',
  'node_modules',
  '__pycache__',
  '.dart_tool',
  'build',
};

/// 渐进式披露支持目录（不是独立 skill）。
const Set<String> skillSupportDirs = {
  'references',
  'templates',
  'assets',
  'scripts',
};

/// 单个 skill 元数据。
class SkillMeta {
  final String name;
  final String description;
  final String category;
  final String dir; // skill 目录绝对路径
  final String path; // SKILL.md 绝对路径

  SkillMeta({
    required this.name,
    required this.description,
    required this.category,
    required this.dir,
    required this.path,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'category': category,
      };
}

/// skill 发现器。
class SkillDiscovery {
  final String skillsRoot;

  /// 元数据缓存（mtime 签名校验）。
  List<SkillMeta>? _cache;
  int _cacheMtimeSig = 0;

  SkillDiscovery({required this.skillsRoot});

  /// 扫描签名：所有 SKILL.md 的 mtime+size 组合。
  int _scanSignature() {
    var sig = 0;
    try {
      final root = Directory(skillsRoot);
      if (!root.existsSync()) {
        return sig;
      }
      final walk = root.listSync(recursive: true, followLinks: false);
      for (final e in walk) {
        if (e is File && p.basename(e.path) == 'SKILL.md') {
          try {
            final st = e.statSync();
            sig = sig * 31 + st.modified.millisecondsSinceEpoch + st.size;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return sig;
  }

  /// 是否排除（VCS/依赖/缓存目录）。
  bool _isExcluded(String path) {
    final parts = p.split(path);
    for (final part in parts) {
      if (excludedSkillDirs.contains(part)) {
        return true;
      }
    }
    return _isSupportPath(path);
  }

  /// 是否在 skill 的支持目录下（references/templates/assets/scripts）。
  bool _isSupportPath(String path) {
    final parts = p.split(path);
    for (var i = 0; i < parts.length - 1; i++) {
      if (!skillSupportDirs.contains(parts[i]) || i == 0) {
        continue;
      }
      final skillRoot = p.joinAll(parts.sublist(0, i));
      if (File(p.join(skillRoot, 'SKILL.md')).existsSync()) {
        return true;
      }
    }
    return false;
  }

  /// 查找所有 skill 元数据（带缓存）。
  List<SkillMeta> findAllSkills() {
    final sig = _scanSignature();
    if (_cache != null && _cacheMtimeSig == sig) {
      return _cache!;
    }
    final skills = <SkillMeta>[];
    final seenNames = <String>{};
    try {
      final root = Directory(skillsRoot);
      if (!root.existsSync()) {
        _cache = skills;
        _cacheMtimeSig = sig;
        return skills;
      }
      final walk = root.listSync(recursive: true, followLinks: false);
      for (final e in walk) {
        if (e is! File || p.basename(e.path) != 'SKILL.md') {
          continue;
        }
        if (_isExcluded(e.path)) {
          continue;
        }
        final content = _readHead(e.path);
        final (frontmatter, _) = parseFrontmatter(content);
        if (!skillMatchesPlatform(frontmatter)) {
          continue;
        }
        final rawName = frontmatter['name'] as String? ?? p.basename(p.dirname(e.path));
        final name = rawName.length > 64 ? rawName.substring(0, 64) : rawName;
        if (seenNames.contains(name)) {
          continue;
        }
        seenNames.add(name);
        final description = frontmatter['description'] as String? ?? '';
        final skillDir = p.dirname(e.path);
        // category = skills/ 下的第一级目录。
        final rel = p.relative(skillDir, from: skillsRoot);
        final category = p.split(rel).length > 1 ? p.split(rel).first : '';
        skills.add(SkillMeta(
          name: name,
          description: description,
          category: category,
          dir: skillDir,
          path: e.path,
        ));
      }
    } catch (_) {}
    _cache = skills;
    _cacheMtimeSig = sig;
    return skills;
  }

  String _readHead(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) {
        return '';
      }
      final raf = f.openSync();
      final bytes = raf.readSync(4000);
      raf.closeSync();
      return String.fromCharCodes(bytes);
    } catch (_) {
      return '';
    }
  }

  /// 查找 skill（三策略：直接路径/目录名/旧式 .md）。
  ///
  /// [name] 可以是 "category/name"、"name"、或文件路径。
  SkillMeta? findSkill(String name, {String? filePath}) {
    // 1. file_path 优先：先找 skill 所在目录，再在 skill_dir 下解析文件。
    if (filePath != null) {
      if (_hasTraversal(filePath)) {
        return null;
      }
      // name 可能是 "category/name" 或 "name" 或绝对路径的 skill 目录。
      final skill = _findByAnyName(name);
      if (skill == null) {
        return null;
      }
      final abs = p.join(skill.dir, filePath);
      if (File(abs).existsSync()) {
        return SkillMeta(
          name: skill.name,
          description: skill.description,
          category: skill.category,
          dir: skill.dir,
          path: abs, // 指向 file_path 对应的文件。
        );
      }
      return null;
    }
    return _findByAnyName(name);
  }

  /// 按 name 找 skill（直接路径 + 目录名递归）。
  SkillMeta? _findByAnyName(String name) {
    final direct = p.join(skillsRoot, name, 'SKILL.md');
    if (File(direct).existsSync()) {
      return _metaFromDir(p.dirname(direct), direct);
    }
    for (final s in findAllSkills()) {
      if (s.name == name || p.basename(s.dir) == name) {
        return s;
      }
    }
    return null;
  }

  SkillMeta? _metaFromDir(String dir, String path) {
    final content = _readHead(path);
    final (frontmatter, _) = parseFrontmatter(content);
    final name = frontmatter['name'] as String? ?? p.basename(dir);
    final description = frontmatter['description'] as String? ?? '';
    final rel = p.relative(dir, from: skillsRoot);
    final parts = p.split(rel);
    final category = parts.length > 1 ? parts.first : '';
    return SkillMeta(
      name: name,
      description: description,
      category: category,
      dir: dir,
      path: path,
    );
  }

  bool _hasTraversal(String path) {
    return p.split(path).contains('..') || p.isAbsolute(path);
  }

  /// 读 skill 完整正文。
  String readContent(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.readAsStringSync() : '';
    } catch (_) {
      return '';
    }
  }
}
