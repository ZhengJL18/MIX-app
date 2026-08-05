import 'package:sqflite/sqflite.dart';

import '../db/database_helper.dart';

/// 知识点 5 阶段螺旋进度。
///
/// 不是直线"爬完就不碰"，而是螺旋上升：每个阶段达标后进入下一阶段，
/// 且后续会按复习队列回访早期知识点（用更高难度，非重复基础题）。
///
/// 阶段与达标条件（数量 + 正确率双门槛）：
///   S0 未接触  — 做过 ≥1 题
///   S1 入门    — 本阶段 ≥3 题对 ≥50%
///   S2 巩固    — 本阶段 ≥5 题对 ≥70% 且无连错 2
///   S3 熟练    — 本阶段 ≥8 题对 ≥80%
///   S4 精通    — 本阶段 ≥10 题对 ≥90%
/// 每阶段达标 → stage+1，stage_total/correct 清零重计（螺旋下一圈）。
///
/// 复习节奏：练 4 新回 1 旧（[SpiralRules.reviewEvery]），由选点层控制。
class SpiralRules {
  /// 每练 N 题新知识点，回访 1 题旧知识点（螺旋回顾）。
  static const int reviewEvery = 4;

  /// 各阶段的达标条件：(本阶段题数门槛, 正确率门槛)。
  static const List<(int, double)> stageGoals = [
    (1, 0.0),    // S0 → S1：做过 1 题即进入入门
    (3, 0.5),    // S1 → S2
    (5, 0.7),    // S2 → S3
    (8, 0.8),    // S3 → S4
    (10, 0.9),   // S4 → 精通（封顶）
  ];

  /// 阶段中文名。
  static const List<String> stageNames = ['未接触', '入门', '巩固', '熟练', '精通'];

  /// 阶段 → 出题难度描述（generator 用）。
  static const Map<int, String> stageDifficulty = {
    0: '基础概念入门题',
    1: '基础计算题',
    2: '综合应用题（含变式）',
    3: '易错陷阱题',
    4: '跨知识点综合题',
  };
}

/// 知识点进度行。
class KpProgress {
  final int kpId;
  int stage;          // 0-4
  int stageCorrect;   // 本阶段做对数
  int stageTotal;     // 本阶段做题数
  int totalCorrect;   // 累计做对数
  int totalDone;      // 累计做题数
  String? lastReviewAt;
  String? nextReviewAt;

  KpProgress({
    required this.kpId,
    this.stage = 0,
    this.stageCorrect = 0,
    this.stageTotal = 0,
    this.totalCorrect = 0,
    this.totalDone = 0,
    this.lastReviewAt,
    this.nextReviewAt,
  });

  factory KpProgress.fromRow(Map<String, dynamic> row) => KpProgress(
        kpId: row['kp_id'] as int,
        stage: row['stage'] as int? ?? 0,
        stageCorrect: row['stage_correct'] as int? ?? 0,
        stageTotal: row['stage_total'] as int? ?? 0,
        totalCorrect: row['total_correct'] as int? ?? 0,
        totalDone: row['total_done'] as int? ?? 0,
        lastReviewAt: row['last_review_at'] as String?,
        nextReviewAt: row['next_review_at'] as String?,
      );

  /// 当前阶段达标了没有（达到 stageGoals[stage] 条件）。
  bool get reached {
    if (stage >= 4) return true; // S4 封顶，视为完成
    final (need, acc) = SpiralRules.stageGoals[stage];
    if (stageTotal < need) return false;
    return stageCorrect / stageTotal >= acc;
  }

  /// 距达标还差多少题（选点层判断"接近达标"用）。
  /// 返回：还需做几题才可能达标（负/0 = 已达标）。
  int get remainingToReach {
    if (reached) return 0;
    final (need, acc) = SpiralRules.stageGoals[stage];
    if (stageTotal >= need) return 0; // 题数够但正确率不够 → 再练即可
    return need - stageTotal;
  }

  /// 距离达标进度 0~1（planner 描述用）。
  double get progress {
    if (reached) return 1.0;
    final (need, acc) = SpiralRules.stageGoals[stage];
    final byCount = (stageTotal / need).clamp(0.0, 1.0);
    final byAcc = acc == 0 ? 1.0 : (stageCorrect / stageTotal.clamp(1, 999999) / acc).clamp(0.0, 1.0);
    return (byCount * 0.6 + byAcc * 0.4).clamp(0.0, 1.0);
  }
}

/// 进度引擎：读写 kp_progress，纯代码规则，零 token。
class ProgressEngine {
  static const int kLocalUserId = 1;

  /// 取某知识点进度（无则初始化）。
  Future<KpProgress> getProgress(int userId, int kpId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'kp_progress',
      where: 'user_id = ? AND kp_id = ?',
      whereArgs: [userId, kpId],
    );
    if (rows.isNotEmpty) return KpProgress.fromRow(rows.first);
    return KpProgress(kpId: kpId);
  }

  /// 记录一次作答，更新阶段进度。做题后调用。
  /// 返回更新后的进度（含是否晋级）。
  Future<KpProgress> recordAnswer({
    required int userId,
    required int kpId,
    required bool correct,
  }) async {
    final db = await DatabaseHelper.instance.database;
    final p = await getProgress(userId, kpId);

    // 累计
    p.totalDone++;
    if (correct) p.totalCorrect++;
    p.stageTotal++;
    if (correct) p.stageCorrect++;
    p.lastReviewAt = DateTime.now().toUtc().toIso8601String();

    // 达标晋级：每阶段达到条件 → stage+1，本阶段计数清零（螺旋下一圈）
    while (p.stage < 4 && p.reached) {
      p.stage++;
      p.stageCorrect = 0;
      p.stageTotal = 0;
    }

    await db.insert(
      'kp_progress',
      {
        'user_id': userId,
        'kp_id': kpId,
        'stage': p.stage,
        'stage_correct': p.stageCorrect,
        'stage_total': p.stageTotal,
        'total_correct': p.totalCorrect,
        'total_done': p.totalDone,
        'last_review_at': p.lastReviewAt,
        'next_review_at': p.nextReviewAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return p;
  }

  /// 某科目所有知识点进度（排除占位符）。
  Future<List<(int, String, KpProgress)>> subjectProgresses(
    int userId,
    int subjectId,
  ) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('''
      SELECT kp.id AS kp_id, kp.name AS kp_name, kp_progress.*
      FROM knowledge_points kp
      LEFT JOIN kp_progress ON kp_progress.kp_id = kp.id AND kp_progress.user_id = ?
      WHERE kp.subject_id = ?
    ''', [userId, subjectId]);
    final result = <(int, String, KpProgress)>[];
    for (final r in rows) {
      final name = r['kp_name'] as String? ?? '';
      if (name == '还没开始' || name == '已经学完') continue;
      final p = r['kp_id'] == null
          ? KpProgress(kpId: r['kp_id'] as int)
          : KpProgress.fromRow(r);
      result.add((r['kp_id'] as int, name, p));
    }
    return result;
  }
}
