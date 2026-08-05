import '../config/config.dart';
import 'mastery.dart';

/// 新固定数值三段扣分逻辑（替代旧 feedback.dart 的百分比扣分）
///
/// 规则：
/// ✅ 答对：正常加分（调用旧逻辑）
/// ❌ 只填主因：主因 -0.2，其余 -0.05
/// ❌ 填主因+辅因：主因 -0.2，辅因 -0.1，其余不变
/// ⏭️ 跳过评价：全部 -0.1
Map<String, dynamic> applyFeedbackV2({
  required Map<String, dynamic> state,
  required Map<String, dynamic> subject,
  required bool correct,
  String? mainCause,
  String? minorCause,
}) {
  final newState = Map<String, dynamic>.from(state);

  if (correct) {
    // 答对：复用旧逻辑的加分
    final raw = compositeMastery(newState, subject);
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
    newState['streak_correct'] = (newState['streak_correct'] as num).toInt() + 1;
    newState['streak_wrong'] = 0;
  } else {
    if (mainCause != null && minorCause == null) {
      // 只填了主因
      for (final dim in CauseDims.all) {
        final current = (newState[dim] as num).toDouble();
        if (dim == mainCause) {
          newState[dim] = (current - 0.2).clamp(0.01, 1.0);
        } else {
          newState[dim] = (current - 0.05).clamp(0.01, 1.0);
        }
      }
    } else if (mainCause != null && minorCause != null) {
      // 填了主因 + 辅因
      for (final dim in CauseDims.all) {
        final current = (newState[dim] as num).toDouble();
        if (dim == mainCause) {
          newState[dim] = (current - 0.2).clamp(0.01, 1.0);
        } else if (dim == minorCause) {
          newState[dim] = (current - 0.1).clamp(0.01, 1.0);
        }
        // 其余维度不变
      }
    } else {
      // 跳过评价：全部 -0.1
      for (final dim in CauseDims.all) {
        final current = (newState[dim] as num).toDouble();
        newState[dim] = (current - 0.1).clamp(0.01, 1.0);
      }
    }

    newState['streak_wrong'] = (newState['streak_wrong'] as num).toInt() + 1;
    newState['streak_correct'] = 0;
  }

  newState['review_count'] = (newState['review_count'] as num).toInt() + 1;
  newState['last_review_at'] = DateTime.now().toUtc().toIso8601String();
  return newState;
}

/// 匹配错因中文 label → 维度 key
String? mapCauseLabelToDim(String label) {
  switch (label) {
    case '步骤型':
    case '步骤型错误':
      return 'complexity';
    case '理解型':
    case '理解型错误':
      return 'understand';
    case '干扰型':
    case '干扰型错误':
      return 'redundancy';
    case '边界型':
    case '边界型错误':
      return 'coverage';
    default:
      return null;
  }
}

const Map<String, String> kCauseLabels = {
  '步骤型': '步骤遗漏/顺序错误/中间计算错',
  '理解型': '概念理解错/公式记错/原理不理解',
  '干扰型': '被无关信息干扰/漏关键条件',
  '边界型': '不知道用哪个知识点/边界不清',
};
