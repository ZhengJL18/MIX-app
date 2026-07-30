import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// 纯 sqlite3，无 ORM。所有查询都是显式 SQL / Map，
/// 对应设计文档 db.py 的定位："建表 + CRUD + 事务管理"。
class DatabaseHelper {
  DatabaseHelper._internal();
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static Database? _db;

  Future<Database> get database async {
    // 检查已有的 _db 是否仍然打开（hot restart 可能导致旧连接失效）
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'mix.db');
    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        // WAL 模式可大幅提升并发读性能，但部分 Android 系统的 SQLite
        // 实现中 PRAGMA 可能因底层文件系统/路径问题报错。
        // 这里捕获异常静默忽略——没有 WAL 只是写入稍慢，不影响功能。
        try {
          await db.execute('PRAGMA journal_mode = WAL');
        } catch (_) {
          // ignore: WAL not supported on this device
        }
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );
  }

  Future<void> _createSchema(Database db) async {
    final batch = db.batch();

    // 1.1 subjects
    batch.execute('''
      CREATE TABLE subjects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        importance REAL NOT NULL DEFAULT 0.4,
        w_complexity REAL NOT NULL DEFAULT 0.4,
        w_understand REAL NOT NULL DEFAULT 0.3,
        w_redundancy REAL NOT NULL DEFAULT 0.1,
        w_coverage REAL NOT NULL DEFAULT 0.2,
        target_mastery REAL NOT NULL DEFAULT 0.9,
        mastery_initial REAL NOT NULL DEFAULT 0.3,
        ebbinghaus_base REAL NOT NULL DEFAULT 30,
        ebbinghaus_power REAL NOT NULL DEFAULT 3,
        fb_correct_bonus REAL NOT NULL DEFAULT 0.3,
        fb_main_penalty REAL NOT NULL DEFAULT 0.2,
        fb_minor_penalty REAL NOT NULL DEFAULT 0.05
      )
    ''');

    // 1.2 knowledge_points
    batch.execute('''
      CREATE TABLE knowledge_points (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        subject_id INTEGER NOT NULL REFERENCES subjects(id),
        name TEXT NOT NULL
      )
    ''');
    batch.execute('CREATE INDEX idx_kp_subject ON knowledge_points(subject_id)');

    // 1.3 kp_user_state
    batch.execute('''
      CREATE TABLE kp_user_state (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        kp_id INTEGER NOT NULL REFERENCES knowledge_points(id),
        complexity REAL NOT NULL DEFAULT 0.3,
        understand REAL NOT NULL DEFAULT 0.3,
        redundancy REAL NOT NULL DEFAULT 0.3,
        coverage REAL NOT NULL DEFAULT 0.3,
        streak_correct INTEGER NOT NULL DEFAULT 0,
        streak_wrong INTEGER NOT NULL DEFAULT 0,
        review_count INTEGER NOT NULL DEFAULT 0,
        last_review_at TEXT,
        review_interval REAL NOT NULL DEFAULT 1.0,
        UNIQUE(user_id, kp_id)
      )
    ''');
    batch.execute('CREATE INDEX idx_kpu_user ON kp_user_state(user_id)');
    batch.execute('CREATE INDEX idx_kpu_kp ON kp_user_state(kp_id)');

    // 1.4 questions
    batch.execute('''
      CREATE TABLE questions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kp_id INTEGER NOT NULL REFERENCES knowledge_points(id),
        content TEXT NOT NULL,
        answer TEXT NOT NULL,
        cplx_coef REAL,
        und_coef REAL,
        red_coef REAL,
        cov_coef REAL,
        is_seed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT DEFAULT (datetime('now'))
      )
    ''');
    batch.execute('CREATE INDEX idx_q_kp ON questions(kp_id)');

    // 1.5 practice_records
    batch.execute('''
      CREATE TABLE practice_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        question_id INTEGER NOT NULL REFERENCES questions(id),
        correct INTEGER NOT NULL,
        main_cause TEXT,
        minor_cause TEXT,
        created_at TEXT DEFAULT (datetime('now'))
      )
    ''');
    batch.execute('CREATE INDEX idx_pr_user_correct ON practice_records(user_id, correct)');
    batch.execute('CREATE INDEX idx_pr_question ON practice_records(question_id)');

    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
