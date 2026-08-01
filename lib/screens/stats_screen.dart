import 'package:flutter/material.dart';

import '../engine/mastery.dart';
import '../providers/app_state.dart';
import '../repository/kp_repository.dart';
import '../repository/kp_state_repository.dart';
import '../repository/practice_repository.dart';
import '../repository/subject_repository.dart';
import '../theme/app_colors.dart';

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
      // 该科目是否有做题记录（决定显示真实掌握度还是"未开始"）
      final hasRecords = await _practiceRepo.hasRecordsForSubject(
        kLocalUserId,
        subj['id'] as int,
      );

      if (!hasRecords) {
        stats.add(_SubjectStat(
          name: subj['name'] as String,
          avgMastery: 0,
          kpCount: 0,
          reviewed: false,
        ));
        continue;
      }

      final kps = await _kpRepo.getKpsBySubject(subj['id'] as int);
      double sum = 0;
      for (final kp in kps) {
        final state = await _kpStateRepo.getOrCreateState(
          userId: kLocalUserId,
          kpId: kp['id'] as int,
          subject: subj,
        );
        sum += compositeMastery(state, subj);
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
                  subtitle: s.reviewed
                      ? LinearProgressIndicator(value: s.avgMastery.clamp(0, 1))
                      : const LinearProgressIndicator(value: 0),
                  trailing: Text(
                    s.reviewed
                        ? '${(s.avgMastery * 100).toStringAsFixed(0)}%'
                        : '未开始',
                    style: TextStyle(color: AppColors.lightTextMuted),
                  ),
                ),
              ),
            if (_total == 0)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('还没有做题记录，去刷题吧')),
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
  final bool reviewed;
  _SubjectStat({
    required this.name,
    required this.avgMastery,
    required this.kpCount,
    this.reviewed = true,
  });
}
