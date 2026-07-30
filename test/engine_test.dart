import 'package:flutter_test/flutter_test.dart';
import 'package:mix_app/config/config.dart';
import 'package:mix_app/engine/feedback.dart';
import 'package:mix_app/engine/mastery.dart';
import 'package:mix_app/engine/zones.dart';

void main() {
  final defaultSubject = <String, dynamic>{
    'w_complexity': 0.4,
    'w_understand': 0.3,
    'w_redundancy': 0.1,
    'w_coverage': 0.2,
    'ebbinghaus_base': 30.0,
    'ebbinghaus_power': 3.0,
    'mastery_initial': 0.3,
    'fb_correct_bonus': 0.3,
    'fb_main_penalty': 0.2,
    'fb_minor_penalty': 0.05,
    'target_mastery': 0.9,
  };

  group('compositeMastery', () {
    test('中等状态返回合理值', () {
      final state = <String, dynamic>{
        'complexity': 0.5, 'understand': 0.5,
        'redundancy': 0.5, 'coverage': 0.5,
      };
      final result = compositeMastery(state, defaultSubject);
      expect(result, closeTo(0.5, 0.01));
    });

    test('全满状态返回 1.0', () {
      final state = <String, dynamic>{
        'complexity': 1.0, 'understand': 1.0,
        'redundancy': 1.0, 'coverage': 1.0,
      };
      final result = compositeMastery(state, defaultSubject);
      expect(result, closeTo(1.0, 0.01));
    });

    test('短板惩罚生效（最弱维度 < 0.5 时 raw 被压制）', () {
      // 加权平均 = 0.4*0.5 + 0.3*0.5 + 0.1*0.5 + 0.2*0.3 = 0.46
      // 最弱 = 0.3 < 0.5 → 惩罚: 0.46 * (0.5 + 0.3) = 0.368
      final state = <String, dynamic>{
        'complexity': 0.5, 'understand': 0.5,
        'redundancy': 0.5, 'coverage': 0.3,
      };
      final result = compositeMastery(state, defaultSubject);
      expect(result, closeTo(0.368, 0.001));
      expect(result, lessThan(0.46)); // 确认被压制
    });

    test('弱点但不算短板时无惩罚', () {
      final state = <String, dynamic>{
        'complexity': 0.5, 'understand': 0.5,
        'redundancy': 0.5, 'coverage': 0.51,
      };
      final result = compositeMastery(state, defaultSubject);
      // 0.4*0.5 + 0.3*0.5 + 0.1*0.5 + 0.2*0.51 = 0.502
      expect(result, closeTo(0.502, 0.001));
    });

    test('缺失字段自动兜底 0.5', () {
      final state = <String, dynamic>{
        'complexity': 0.0, 'understand': 1.0,
        // redundancy 和 coverage 缺失
      };
      // 不会抛出异常
      final result = compositeMastery(state, defaultSubject);
      expect(result, greaterThanOrEqualTo(0.0));
      expect(result, lessThanOrEqualTo(1.0));
    });
  });

  group('effectiveMastery', () {
    test('刚复习完 (days=0) 返回 raw', () {
      final result = effectiveMastery(raw: 0.6, daysSinceReview: 0, reviewCount: 3);
      expect(result, closeTo(0.6, 0.001));
    });

    test('时间越长有效掌握度越低', () {
      final fresh = effectiveMastery(raw: 0.6, daysSinceReview: 1, reviewCount: 3);
      final old = effectiveMastery(raw: 0.6, daysSinceReview: 30, reviewCount: 3);
      expect(old, lessThan(fresh));
    });

    test('reviewCount 越大衰减越慢', () {
      final lowCount = effectiveMastery(raw: 0.5, daysSinceReview: 7, reviewCount: 1);
      final highCount = effectiveMastery(raw: 0.5, daysSinceReview: 7, reviewCount: 10);
      expect(highCount, greaterThan(lowCount));
    });

    test('reviewCount cap 有效（不会指数爆炸）', () {
      final result = effectiveMastery(raw: 0.5, daysSinceReview: 1, reviewCount: 999);
      expect(result, greaterThan(0.0));
      expect(result, lessThanOrEqualTo(1.0));
    });

    test('负数天数视为刚复习完', () {
      final result = effectiveMastery(raw: 0.6, daysSinceReview: -5, reviewCount: 3);
      expect(result, closeTo(0.6, 0.001));
    });
  });

  group('daysSince', () {
    test('null 返回 999', () {
      expect(daysSince(null), 999.0);
    });

    test('无效日期返回 999', () {
      expect(daysSince('not-a-date'), 999.0);
    });
  });

  group('zoneWeights', () {
    test('四个区权重和为 1.0', () {
      for (final m in [0.0, 0.3, 0.5, 0.7, 0.9, 1.0]) {
        final w = zoneWeights(m);
        final sum = w.values.fold(0.0, (a, b) => a + b);
        expect(sum, closeTo(1.0, 0.001), reason: 'mastery=$m 时权重和应为 1');
      }
    });

    test('低掌握度时攻坚区权重最高', () {
      final w = zoneWeights(0.3);
      final breakthrough = w[Zones.breakthrough]!;
      expect(breakthrough, greaterThan(0.5));
    });

    test('高掌握度时安全区权重最高', () {
      final w = zoneWeights(0.95);
      final safe = w[Zones.safe]!;
      expect(safe, greaterThan(0.5));
    });
  });

  group('pickZone', () {
    test('同 mastery + 同 questionIndex 结果确定', () {
      final a = pickZone(0.5, 10);
      final b = pickZone(0.5, 10);
      expect(a, equals(b));
    });

    test('同 mastery + 不同 questionIndex 可能不同', () {
      // 长期统计上，不同 questionIndex 应有分布差异
      final results = <String>{};
      for (var i = 0; i < 50; i++) {
        results.add(pickZone(0.5, i));
      }
      // 至少出现 2 种不同的区
      expect(results.length, greaterThanOrEqualTo(2));
    });
  });

  group('applyFeedback', () {
    Map<String, dynamic> defaultState() => <String, dynamic>{
      'complexity': 0.4, 'understand': 0.4,
      'redundancy': 0.4, 'coverage': 0.4,
      'streak_correct': 0, 'streak_wrong': 0,
      'review_count': 0, 'last_review_at': null,
    };

    test('答对时所有维度提升', () {
      final state = defaultState();
      final result = applyFeedback(state: state, subject: defaultSubject, correct: true);
      for (final dim in CauseDims.all) {
        expect((result[dim] as num).toDouble(), greaterThan((state[dim] as num).toDouble()));
      }
    });

    test('答对时 review_count 累加', () {
      final result = applyFeedback(state: defaultState(), subject: defaultSubject, correct: true);
      expect(result['review_count'], 1);
    });

    test('答错时 review_count 不累加', () {
      final state = defaultState();
      state['review_count'] = 5;
      final result = applyFeedback(
        state: state, subject: defaultSubject, correct: false,
        mainCause: 'complexity',
      );
      // review_count 保持不变
      expect(result['review_count'], 5);
    });

    test('答错时 streak_correct 归零、streak_wrong 递增', () {
      final result = applyFeedback(
        state: defaultState(), subject: defaultSubject, correct: false,
        mainCause: 'complexity',
      );
      expect(result['streak_correct'], 0);
      expect(result['streak_wrong'], 1);
    });

    test('连续答对 streak 加速生效', () {
      final state = defaultState();
      state['streak_correct'] = 4; // 满加速
      final result = applyFeedback(state: state, subject: defaultSubject, correct: true);
      for (final dim in CauseDims.all) {
        expect((result[dim] as num).toDouble(), greaterThan(0.4));
      }
    });

    test('主因扣分 > 辅因扣分', () {
      final state = defaultState();
      final resMain = applyFeedback(
        state: Map.from(state), subject: defaultSubject, correct: false,
        mainCause: 'complexity',
      );
      final resBoth = applyFeedback(
        state: Map.from(state), subject: defaultSubject, correct: false,
        mainCause: 'complexity', minorCause: 'understand',
      );
      final mainDimDrop = 0.4 - (resMain['complexity'] as num).toDouble();
      final minorDimDrop = 0.4 - (resBoth['understand'] as num).toDouble();
      expect(mainDimDrop, greaterThan(minorDimDrop)); // 主因 delta, 辅因 delta*0.25
    });

    test('差异化更新：题目系数 > 当前时取平均', () {
      final state = defaultState(); // 全 0.4
      final coefs = {'complexity': 0.8, 'understand': 0.6, 'redundancy': 0.2, 'coverage': 0.2};
      final result = applyFeedback(
        state: state, subject: defaultSubject, correct: true,
        questionCoefs: coefs,
      );
      // complexity: (0.4+0.8)/2 = 0.6
      expect((result['complexity'] as num).toDouble(), closeTo(0.6, 0.001));
      // redundancy: (0.4+0.2)/2 = 0.3 → 但系数 ≤ 当前就不更新, 所以还是 0.4
      expect((result['redundancy'] as num).toDouble(), closeTo(0.4, 0.001));
    });

    test('部分系数缺失时回退到等量 bonus', () {
      // 验证全有或全无策略：app_state 中已确保只传全满的 coefs 或 null
      // 这里只确认 null coefs 不抛异常
      final result = applyFeedback(
        state: defaultState(), subject: defaultSubject, correct: true,
        questionCoefs: null,
      );
      expect((result['complexity'] as num).toDouble(), greaterThan(0.4));
    });
  });
}
