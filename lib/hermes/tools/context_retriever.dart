/// 上下文工程检索：发消息前用 FTS5 从历史消息召回相关片段，注入上下文。
///
/// 一期纯工程检索（SQLite FTS5 词法匹配），二期升级 BGE 语义向量。
/// 目的：不让全部历史塞进上下文（防污染），只注入和当前问题最相关的片段。
library;

import '../db/session_db.dart';

/// 检索结果片段。
class ContextHit {
  final String sessionId;
  final String role; // user / assistant / tool
  final String content;

  const ContextHit({
    required this.sessionId,
    required this.role,
    required this.content,
  });
}

/// 用 FTS5 从历史消息召回相关片段。
///
/// [query] 当前用户问题；[limit] 召回条数；[sessionId] 限定会话（默认全局）。
/// 优先 role=user/assistant（跳过 tool 噪声），按相关度取最近消息。
///
/// 范围控制：整句查 1 次 + 至多 2 个关键词（各取 limit/2），避免召回过宽
/// 引入无关历史。返回空列表 = 无匹配（调用方应正常继续，不中断）。
Future<List<ContextHit>> retrieveRelevantContext({
  required SessionDB db,
  required String query,
  String? sessionId,
  int limit = 6,
}) async {
  if (limit <= 0) {
    return [];
  }
  final queryWords = query.split(RegExp(r'[\s,，。！？!?]+'))
      .where((w) => w.trim().isNotEmpty && w.length >= 2)
      .toList();
  if (queryWords.isEmpty) {
    return [];
  }

  final hits = <ContextHit>[];
  // 整句 + 至多 2 个关键词，各查一半，合并去重。
  final seen = <String>{};
  final perQuery = (limit / 2).ceil().clamp(1, limit);
  final queries = [query, ...queryWords.take(2)];
  for (final q in queries) {
    try {
      final rows = await db.searchMessages(
        q,
        roleFilter: 'user,assistant',
        sessionId: sessionId,
        limit: perQuery,
      );
      for (final r in rows) {
        final content = r['content'] as String? ?? '';
        if (content.isEmpty) continue;
        final key = '${r['session_id']}:${r['id']}';
        if (seen.add(key)) {
          hits.add(ContextHit(
            sessionId: r['session_id'] as String? ?? '',
            role: r['role'] as String? ?? 'user',
            content: content,
          ));
        }
      }
    } catch (_) {}
  }
  // 截断超长内容（带标记），限制总条数。
  const maxLen = 200;
  final result = <ContextHit>[];
  for (final h in hits) {
    if (result.length >= limit) break;
    final trimmed = h.content.length > maxLen
        ? '${h.content.substring(0, maxLen)}…（截断）'
        : h.content;
    result.add(ContextHit(
      sessionId: h.sessionId,
      role: h.role,
      content: trimmed,
    ));
  }
  return result;
}

/// 把检索结果格式化成注入 system prompt 的文本块。
String formatContextBlock(List<ContextHit> hits) {
  if (hits.isEmpty) {
    return '';
  }
  final lines = <String>['以下是过往对话中与你当前问题相关的片段，供参考：'];
  for (var i = 0; i < hits.length; i++) {
    final h = hits[i];
    final who = h.role == 'user' ? '用户' : '助手';
    lines.add('[$i] ($who) ${h.content}');
  }
  return lines.join('\n');
}
