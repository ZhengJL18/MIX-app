/// 对应 `ref/hermes-agent/agent/skill_utils.py`（像素级复刻，核心）。
///
/// SKILL.md 解析：frontmatter（YAML）+ 正文。平台/环境匹配。
library;

import 'package:yaml/yaml.dart';

/// 解析 YAML frontmatter 从 markdown 字符串。
///
/// 返回 (frontmatter_dict, remaining_body)。单个前导 UTF-8 BOM 先剥离。
(Map<String, dynamic>, String) parseFrontmatter(String content) {
  final frontmatter = <String, dynamic>{};
  // 只剥前导 BOM；内容中间的 BOM 是数据。
  if (content.startsWith('﻿')) {
    content = content.substring(1);
  }
  final body = content;

  if (!content.startsWith('---')) {
    return (frontmatter, body);
  }
  // 找结束围栏。
  final endMatch = RegExp(r'\n---\s*\n').firstMatch(content.substring(3));
  if (endMatch == null) {
    return (frontmatter, body);
  }
  final yamlContent = content.substring(3, endMatch.start + 3);
  final remainingBody = content.substring(endMatch.end + 3);

  try {
    final parsed = loadYaml(yamlContent);
    if (parsed is YamlMap) {
      for (final e in parsed.entries) {
        frontmatter['${e.key}'] = _yamlToDart(e.value);
      }
    }
  } catch (_) {
    // Fallback：简单 key:value 解析（畸形 YAML）。
    for (final line in yamlContent.trim().split('\n')) {
      if (!line.contains(':')) {
        continue;
      }
      final idx = line.indexOf(':');
      frontmatter[line.substring(0, idx).trim()] = line.substring(idx + 1).trim();
    }
  }

  return (frontmatter, remainingBody);
}

/// YAML 值转 Dart（YamlMap/YamlList → Map/List）。
dynamic _yamlToDart(dynamic v) {
  if (v is YamlMap) {
    return {
      for (final e in v.entries) '${e.key}': _yamlToDart(e.value),
    };
  }
  if (v is YamlList) {
    return [for (final item in v) _yamlToDart(item)];
  }
  return v;
}

/// 平台匹配（当前 Android）。
bool skillMatchesPlatform(Map<String, dynamic> frontmatter) {
  final platforms = frontmatter['platforms'];
  if (platforms == null) {
    return true;
  }
  final list = platforms is List ? platforms : <dynamic>[platforms];
  if (list.isEmpty) {
    return true;
  }
  // Hermes platforms 是 macos/linux/windows；Android App 无对应平台。
  // 匹配 'linux'（Android 底层）或 'all'/'*'。
  for (final p in list) {
    final s = '$p'.toLowerCase();
    if (s == 'linux' || s == 'all' || s == '*' || s == 'android') {
      return true;
    }
  }
  return false;
}

/// 名称校验（Hermes: ^[a-z0-9][a-z0-9._-]*$，≤64）。
bool isValidSkillName(String name) {
  return RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(name) && name.length <= 64;
}

/// frontmatter 校验：必须以 --- 开头、有 name/description。
/// [requireShortDesc] 新建时要求 description ≤60。
String? validateFrontmatter(
  String content,
  Map<String, dynamic> frontmatter, {
  bool requireShortDesc = false,
}) {
  if (!content.trimLeft().startsWith('---')) {
    return 'Frontmatter must start with "---"';
  }
  final name = frontmatter['name'];
  if (name is! String || name.isEmpty) {
    return 'Frontmatter requires a "name" field';
  }
  if (!isValidSkillName(name)) {
    return "Invalid skill name '$name': must match ^[a-z0-9][a-z0-9._-]*\$ and be ≤64 chars";
  }
  final desc = frontmatter['description'];
  if (desc is! String || desc.isEmpty) {
    return 'Frontmatter requires a "description" field';
  }
  if (requireShortDesc && desc.length > 60) {
    return 'New skill description must be ≤60 characters (got ${desc.length})';
  }
  return null;
}
