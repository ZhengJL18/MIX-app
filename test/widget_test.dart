import 'package:flutter_test/flutter_test.dart';
import 'package:mix_app/config/config.dart';
import 'package:mix_app/engine/mastery.dart';
import 'package:mix_app/engine/feedback.dart';
import 'package:mix_app/engine/zones.dart';

/// smoke test：确认核心模块可正常加载
void main() {
  test('核心常量定义完整', () {
    expect(EngineConstants.sMin, 0.3);
    expect(Zones.all.length, 4);
    expect(CauseDims.all.length, 4);
  });

  test('掌握度计算不抛异常', () {
    final result = compositeMastery(
      {'complexity': 0.5, 'understand': 0.5, 'redundancy': 0.5, 'coverage': 0.5},
      {'w_complexity': 0.4, 'w_understand': 0.3, 'w_redundancy': 0.1, 'w_coverage': 0.2},
    );
    expect(result, closeTo(0.5, 0.01));
  });

  test('applyFeedback 不抛异常', () {
    final result = applyFeedback(
      state: {'complexity': 0.5, 'understand': 0.5, 'redundancy': 0.5, 'coverage': 0.5,
              'streak_correct': 0, 'streak_wrong': 0, 'review_count': 0, 'last_review_at': null},
      subject: {'w_complexity': 0.4, 'w_understand': 0.3, 'w_redundancy': 0.1, 'w_coverage': 0.2,
                'fb_correct_bonus': 0.3, 'fb_main_penalty': 0.2},
      correct: true,
    );
    expect(result['review_count'], 1);
  });

  test('zoneWeights 和为 1', () {
    final w = zoneWeights(0.5);
    expect(w.values.fold(0.0, (a, b) => a + b), closeTo(1.0, 0.001));
  });
}
