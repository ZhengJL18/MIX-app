/// 对应 `ref/hermes-agent/hermes_state.py`（像素级复刻，核心）。
///
/// SQLite 会话/消息库。手机用 sqflite；测试用 sqflite_common_ffi。
///
/// ## 表结构（对齐 hermes_state_common.py SCHEMA_SQL）
/// - sessions：id PK, source, model, system_prompt, parent_session_id,
///   started_at, ended_at, end_reason, message_count, tool_call_count,
///   title, archived, pinned, cwd
/// - messages：id PK AUTOINCREMENT, session_id FK, role, content, tool_call_id,
///   tool_calls(JSON), tool_name, timestamp, token_count, finish_reason,
///   observed, active(软删), compacted
/// - FTS5：messages_fts（external-content unicode61）+ 同步触发器
///
/// ## 砍掉（手机不需要）
/// session_model_usage / gateway_routing / async_delegations /
/// compression_locks / state_meta 计费列 / cjk-bigram 索引 / fts 后台重建
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// 数据库工厂（手机用 sqflite，测试用 ffi）。
/// 由外部设置：`sessionDbFactory = databaseFactoryFfi`（测试）或默认 sqflite。
DatabaseFactory? sessionDbFactory;

/// 会话库。
class SessionDB {
  Database? _db;
  final String dbPath;
  bool _closed = false;

  SessionDB({required this.dbPath});

  /// 打开数据库（建表 + FTS）。
  Future<void> init() async {
    final factory = sessionDbFactory ?? databaseFactory;
    final db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await _createSchema(db);
        },
      ),
    );
    _db = db;
    await _ensureSchema(db);
  }

  Database get db {
    if (_db == null) {
      throw StateError('SessionDB not initialized — call init() first');
    }
    return _db!;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        model TEXT,
        system_prompt TEXT,
        parent_session_id TEXT,
        started_at REAL NOT NULL,
        ended_at REAL,
        end_reason TEXT,
        message_count INTEGER NOT NULL DEFAULT 0,
        tool_call_count INTEGER NOT NULL DEFAULT 0,
        title TEXT,
        cwd TEXT,
        archived INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        role TEXT NOT NULL,
        content TEXT,
        tool_call_id TEXT,
        tool_calls TEXT,
        tool_name TEXT,
        timestamp REAL NOT NULL,
        token_count INTEGER,
        finish_reason TEXT,
        observed INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1,
        compacted INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(timestamp)');
  }

  /// FTS5 + 触发器（sqflite 建 FTS5 需要 SQLite 编译带 FTS5）。
  Future<void> _ensureSchema(Database db) async {
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
          content,
          tool_name,
          tool_calls,
          content='messages',
          content_rowid='id'
        )
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS messages_fts_insert AFTER INSERT ON messages
        BEGIN
          INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
          VALUES (new.id, new.content, new.tool_name, new.tool_calls);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS messages_fts_delete AFTER DELETE ON messages
        BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, tool_calls)
          VALUES ('delete', old.id, old.content, old.tool_name, old.tool_calls);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS messages_fts_update AFTER UPDATE ON messages
        WHEN (old.content IS NOT new.content
           OR old.tool_name IS NOT new.tool_name
           OR old.tool_calls IS NOT new.tool_calls)
        BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, content, tool_name, tool_calls)
          VALUES ('delete', old.id, old.content, old.tool_name, old.tool_calls);
          INSERT INTO messages_fts(rowid, content, tool_name, tool_calls)
          VALUES (new.id, new.content, new.tool_name, new.tool_calls);
        END
      ''');
    } catch (_) {
      // FTS5 不可用时降级（LIKE 搜索仍可用）。
    }
  }

  /// 建会话（upsert）。
  Future<String> createSession(
    String sessionId, {
    required String source,
    String? model,
    String? systemPrompt,
    String? parentSessionId,
    String? title,
    String? cwd,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    await db.insert(
      'sessions',
      {
        'id': sessionId,
        'source': source,
        'model': model,
        'system_prompt': systemPrompt,
        'parent_session_id': parentSessionId,
        'started_at': now,
        'title': title,
        'cwd': cwd,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return sessionId;
  }

  /// 追加消息。返回消息 id。
  Future<int> appendMessage(
    String sessionId, {
    required String role,
    String? content,
    String? toolCallId,
    String? toolCalls,
    String? toolName,
    String? finishReason,
    int? tokenCount,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    return await db.transaction((txn) async {
      final id = await txn.insert('messages', {
        'session_id': sessionId,
        'role': role,
        'content': content,
        'tool_call_id': toolCallId,
        'tool_calls': toolCalls,
        'tool_name': toolName,
        'timestamp': now,
        'token_count': tokenCount,
        'finish_reason': finishReason,
      });
      // 递增计数。
      await txn.rawUpdate(
        'UPDATE sessions SET message_count = message_count + 1, '
        'tool_call_count = tool_call_count + ?1 WHERE id = ?2',
        [role == 'tool' ? 1 : 0, sessionId],
      );
      return id;
    });
  }

  /// 读会话消息。默认 active=1 ORDER BY id（AUTOINCREMENT 真插入序）。
  Future<List<Map<String, dynamic>>> getMessages(
    String sessionId, {
    bool includeInactive = false,
    int? limit,
    int offset = 0,
  }) async {
    final where = includeInactive ? 'session_id = ?' : 'session_id = ? AND active = 1';
    final rows = await db.query(
      'messages',
      where: where,
      whereArgs: [sessionId],
      orderBy: 'id ASC',
      limit: limit,
      offset: offset,
    );
    return [for (final r in rows) _decodeMessage(r)];
  }

  Map<String, dynamic> _decodeMessage(Map<String, dynamic> row) {
    final out = Map<String, dynamic>.from(row);
    // tool_calls JSON 解析。
    if (out['tool_calls'] is String && (out['tool_calls'] as String).isNotEmpty) {
      try {
        out['tool_calls'] = jsonDecode(out['tool_calls'] as String);
      } catch (_) {}
    }
    return out;
  }

  /// 获取会话元数据。
  Future<Map<String, dynamic>?> getSession(String sessionId) async {
    final rows = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// 最近会话列表（browse 用）。
  Future<List<Map<String, dynamic>>> listSessions({
    int limit = 20,
  }) async {
    final rows = await db.query(
      'sessions',
      where: 'archived = 0', // 软删（archived=1）的会话不显示。
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  /// 结束会话（跨重启后不再恢复）。
  Future<void> endSession(String sessionId, {String? endReason}) async {
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    await db.update(
      'sessions',
      {'ended_at': now, 'end_reason': endReason ?? 'ended'},
      where: 'id = ? AND ended_at IS NULL',
      whereArgs: [sessionId],
    );
  }

  /// 重开会话（清 ended_at/end_reason，实现跨重启恢复）。
  Future<void> reopenSession(String sessionId) async {
    await db.update(
      'sessions',
      {'ended_at': null, 'end_reason': null},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// 删除会话（软删：archived=1，消息保留在库中）。
  Future<void> deleteSession(String sessionId) async {
    await db.update(
      'sessions',
      {'archived': 1},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  /// FTS5 全文搜索（含 LIKE 兜底）。
  ///
  /// [roleFilter] 如 'user,assistant'。返回匹配消息（带 session_id）。
  Future<List<Map<String, dynamic>>> searchMessages(
    String query, {
    String? roleFilter,
    String? sessionId,
    int limit = 20,
  }) async {
    // 尝试 FTS5。
    try {
      final sanitized = _sanitizeFtsQuery(query);
      if (sanitized.isNotEmpty) {
        var sql = '''
          SELECT m.* FROM messages m
          JOIN messages_fts f ON f.rowid = m.id
          WHERE messages_fts MATCH ?
        ''';
        final args = <Object?>[sanitized];
        if (roleFilter != null && roleFilter.isNotEmpty) {
          final roles = roleFilter.split(',').map((r) => "'${r.trim()}'").join(',');
          sql += ' AND m.role IN ($roles)';
        }
        if (sessionId != null && sessionId.isNotEmpty) {
          sql += ' AND m.session_id = ?';
          args.add(sessionId);
        }
        sql += ' AND m.active = 1 ORDER BY m.id DESC LIMIT ?';
        args.add(limit);
        final rows = await db.rawQuery(sql, args);
        if (rows.isNotEmpty) {
          return [for (final r in rows) _decodeMessage(r)];
        }
      }
    } catch (_) {
      // FTS5 不可用 → 降级 LIKE。
    }
    // LIKE 兜底（中文等）。
    final like = '%$query%';
    var sql = 'SELECT * FROM messages WHERE content LIKE ? AND active = 1';
    final args = <Object?>[like];
    if (roleFilter != null && roleFilter.isNotEmpty) {
      final roles = roleFilter.split(',').map((r) => "'${r.trim()}'").join(',');
      sql += ' AND role IN ($roles)';
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      sql += ' AND session_id = ?';
      args.add(sessionId);
    }
    sql += ' ORDER BY id DESC LIMIT ?';
    args.add(limit);
    final rows = await db.rawQuery(sql, args);
    return [for (final r in rows) _decodeMessage(r)];
  }

  /// 清洗 FTS5 查询（保留引号短语，剥特殊字符）。
  String _sanitizeFtsQuery(String query) {
    var q = query.trim();
    if (q.length > 2048) {
      q = q.substring(0, 2048);
    }
    // 简单清洗：去掉 FTS5 特殊操作符字符，保留字母数字/空格/引号短语/中文。
    // 用 \p{Script=Han} 匹配 CJK 汉字，避免手写区间的编码问题。
    // 双引号字符串 + 双反斜杠转义正则特殊字符。
    final cleaned = q.replaceAll(
      RegExp("[^a-zA-Z0-9\\s\"'\\p{Script=Han}]", unicode: true),
      ' ',
    );
    return cleaned.trim();
  }

  /// 关闭数据库。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}
