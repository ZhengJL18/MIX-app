import 'package:flutter/material.dart';

import '../engine/mastery.dart';
import '../providers/app_state.dart';
import '../repository/kp_repository.dart';
import '../repository/kp_state_repository.dart';
import '../repository/practice_repository.dart';
import '../repository/subject_repository.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  final _subjectRepo = SubjectRepository();
  final _kpRepo = KpRepository();
  final _kpStateRepo = KpStateRepository();
  final _practiceRepo = PracticeRepository();

  int _total = 0;
  int _correct = 0;
  List<_SubjectStat> _subjectStats = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final total = await _practiceRepo.countTotalByUser(kLocalUserId);
    final correct = await _practiceRepo.countCorrectByUser(kLocalUserId);

    final subjects = await _subjectRepo.getAllSubjects();
    final stats = <_SubjectStat>[];
    for (final subj in subjects) {
      final kps = await _kpRepo.getKpsBySubject(subj['id'] as int);
      double sum = 0;
      for (final kp in kps) {
        final state = await _kpStateRepo.getOrCreateState(
          userId: kLocalUserId,
          kpId: kp['id'] as int,
          subject: subj,
        );
        final raw = compositeMastery(state, subj);
        // 使用有效掌握度（计入艾宾浩斯时间衰减），与引擎选点一致
        final effective = effectiveMastery(
          raw: raw,
          daysSinceReview: daysSince(state['last_review_at'] as String?),
          reviewCount: (state['review_count'] as num).toInt(),
          base: (subj['ebbinghaus_base'] as num).toDouble(),
          power: (subj['ebbinghaus_power'] as num).toDouble(),
        );
        sum += effective;
      }
      final avg = kps.isEmpty ? 0.0 : sum / kps.length;
      stats.add(_SubjectStat(name: subj['name'] as String, avgMastery: avg, kpCount: kps.length));
    }

    setState(() {
      _total = total;
      _correct = correct;
      _subjectStats = stats;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accuracy = _total == 0 ? 0.0 : _correct / _total;
    return Scaffold(
      appBar: AppBar(title: const Text('学习统计')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('总览', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text('累计做题：$_total 道'),
                    Text('正确率：${(accuracy * 100).toStringAsFixed(1)}%'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text('各科目掌握度', style: Theme.of(context).textTheme.titleMedium),
            for (final s in _subjectStats)
              Card(
                child: ListTile(
                  title: Text(s.name),
                  subtitle: LinearProgressIndicator(value: s.avgMastery.clamp(0, 1)),
                  trailing: Text('${(s.avgMastery * 100).toStringAsFixed(0)}%'),
                ),
              ),
            if (_subjectStats.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('还没有科目数据')),
              ),
          ],
        ),
      ),
    );
  }
}

class _SubjectStat {
  final String name;
  final double avgMastery;
  final int kpCount;
  _SubjectStat({required this.name, required this.avgMastery, required this.kpCount});
}
