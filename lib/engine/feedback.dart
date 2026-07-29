import '../config/config.dart';
import 'mastery.dart';

/// 对应设计文档 3.4 自适应反馈。
///
/// [state] 需包含 complexity/understand/redundancy/coverage/streak_correct/
/// streak_wrong/review_count，[subject] 需包含四个 w_* 与 fb_* 字段。
/// 返回一份新的 state Map（不修改传入的 Map），调用方负责写回 SQLite。
///
/// [questionCoefs] 可选：从 questions 表取出的四维系数（cplx_coef/und_coef/red_coef/cov_coef）。
/// 传入时，答对使用差异化更新（题目系数 > 用户值时取平均）；不传时回退到等量 bonus 模式。
Map<String, dynamic> applyFeedback({
  required Map<String, dynamic> state,
  required Map<String, dynamic> subject,
  required bool correct,
  String? mainCause,
  String? minorCause,
  Map<String, double>? questionCoefs,
}) {
  final newState = Map<String, dynamic>.from(state);
  final raw = compositeMastery(newState, subject);

  if (correct) {
    // review_count 只在答对时累加，与设计文档 3.4 一致。它会喂进艾宾浩斯
    // 公式的 1.3^review_count（越大衰减越慢）：如果答错也计数，会导致一个
    // 反复答错的知识点因为"接触次数多"而衰减变慢、显得没那么需要复习，
    // 这跟"只有真正掌握住了，才应该降低复习频率"的间隔重复本意是矛盾的。
    newState['review_count'] = (newState['review_count'] as num).toInt() + 1;

    if (questionCoefs != null) {
      // 差异化更新：题目系数 > 用户当前值 → 取平均（渐进式提升，带自然天花板）
      final dimMap = {
        'complexity': questionCoefs['complexity'],
        'understand': questionCoefs['understand'],
        'redundancy': questionCoefs['redundancy'],
        'coverage': questionCoefs['coverage'],
      };
      for (final dim in CauseDims.all) {
        final qCoef = dimMap[dim];
        final current = (newState[dim] as num).toDouble();
        if (qCoef != null && qCoef > current) {
          newState[dim] = ((current + qCoef) / 2).clamp(0.0, 1.0);
        }
        // else: 题目帮不上忙（系数 ≤ 当前），保持不变
      }
    } else {
      // 回退：等量 bonus 模式（旧行为，用于没有系数的种子题）
      final streak = (newState['streak_correct'] as num).toInt();
      final bonus = 1.0 +
          EngineConstants.streakBonusPerStep *
              [streak, EngineConstants.streakCorrectCap]
                  .reduce((a, b) => a < b ? a : b);
      final delta =
          (1 - raw) * (subject['fb_correct_bonus'] as num).toDouble() * bonus;
      for (final dim in CauseDims.all) {
        final current = (newState[dim] as num).toDouble();
        newState[dim] = (current + delta).clamp(0.0, 1.0);
      }
    }

    newState['streak_correct'] = (newState['streak_correct'] as num).toInt() + 1;
    newState['streak_wrong'] = 0;
  } else {
    final delta = raw * (subject['fb_main_penalty'] as num).toDouble();

    if (mainCause != null && CauseDims.all.contains(mainCause)) {
      final current = (newState[mainCause] as num).toDouble();
      newState[mainCause] = (current - delta).clamp(0.01, 1.0);
    }
    if (minorCause != null && CauseDims.all.contains(minorCause)) {
      final current = (newState[minorCause] as num).toDouble();
      newState[minorCause] = (current - delta * 0.25).clamp(0.01, 1.0);
    }

    newState['streak_wrong'] = (newState['streak_wrong'] as num).toInt() + 1;
    newState['streak_correct'] = 0;
  }

  newState['last_review_at'] = DateTime.now().toUtc().toIso8601String();
  return newState;
}
