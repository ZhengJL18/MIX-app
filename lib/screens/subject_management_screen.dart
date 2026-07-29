import 'package:flutter/material.dart';

import '../repository/kp_repository.dart';
import '../repository/subject_repository.dart';

class SubjectManagementScreen extends StatefulWidget {
  const SubjectManagementScreen({super.key});

  @override
  State<SubjectManagementScreen> createState() => _SubjectManagementScreenState();
}

class _SubjectManagementScreenState extends State<SubjectManagementScreen> {
  final _subjectRepo = SubjectRepository();
  final _kpRepo = KpRepository();
  List<Map<String, dynamic>> _subjects = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final subjects = await _subjectRepo.getAllSubjects();
    setState(() => _subjects = subjects);
  }

  Future<void> _createSubject() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建科目'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '例如：药理学'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await _subjectRepo.insertSubject(name: name);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('科目管理')),
      floatingActionButton: FloatingActionButton(
        onPressed: _createSubject,
        child: const Icon(Icons.add),
      ),
      body: _subjects.isEmpty
          ? const Center(child: Text('还没有科目，点右下角 + 新建一个'))
          : ListView.builder(
              itemCount: _subjects.length,
              itemBuilder: (context, index) {
                final subj = _subjects[index];
                return ListTile(
                  title: Text(subj['name'] as String),
                  subtitle: Text(
                    '重要性 ${(subj['importance'] as num).toStringAsFixed(2)} · '
                    '目标掌握度 ${(subj['target_mastery'] as num).toStringAsFixed(2)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _SubjectDetailScreen(
                          subject: subj,
                          subjectRepo: _subjectRepo,
                          kpRepo: _kpRepo,
                        ),
                      ),
                    );
                    _reload();
                  },
                );
              },
            ),
    );
  }
}

class _SubjectDetailScreen extends StatefulWidget {
  const _SubjectDetailScreen({
    required this.subject,
    required this.subjectRepo,
    required this.kpRepo,
  });

  final Map<String, dynamic> subject;
  final SubjectRepository subjectRepo;
  final KpRepository kpRepo;

  @override
  State<_SubjectDetailScreen> createState() => _SubjectDetailScreenState();
}

class _SubjectDetailScreenState extends State<_SubjectDetailScreen> {
  late double _importance;
  late double _wComplexity;
  late double _wUnderstand;
  late double _wRedundancy;
  late double _wCoverage;
  List<Map<String, dynamic>> _kps = [];

  @override
  void initState() {
    super.initState();
    _importance = (widget.subject['importance'] as num).toDouble();
    _wComplexity = (widget.subject['w_complexity'] as num).toDouble();
    _wUnderstand = (widget.subject['w_understand'] as num).toDouble();
    _wRedundancy = (widget.subject['w_redundancy'] as num).toDouble();
    _wCoverage = (widget.subject['w_coverage'] as num).toDouble();
    _reloadKps();
  }

  Future<void> _reloadKps() async {
    final kps = await widget.kpRepo.getKpsBySubject(widget.subject['id'] as int);
    setState(() => _kps = kps);
  }

  Future<void> _saveWeights() async {
    final sum = _wComplexity + _wUnderstand + _wRedundancy + _wCoverage;
    if ((sum - 1.0).abs() > 0.01) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('四维权重之和为 $sum，应等于 1.0，请调整滑块'),
        ));
      }
      return;
    }
    await widget.subjectRepo.updateWeights(widget.subject['id'] as int, {
      'importance': _importance,
      'w_complexity': _wComplexity,
      'w_understand': _wUnderstand,
      'w_redundancy': _wRedundancy,
      'w_coverage': _wCoverage,
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('权重已保存')));
    }
  }

  Future<void> _addKp() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('新建知识点'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await widget.kpRepo.insertKp(subjectId: widget.subject['id'] as int, name: name);
    await _reloadKps();
  }

  Widget _weightSlider(String label, double value, ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label: ${value.toStringAsFixed(2)}'),
        Slider(value: value, min: 0, max: 1, divisions: 100, onChanged: onChanged),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.subject['name'] as String)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('四维权重（AI 微调预留接口，也可手动调整）',
              style: Theme.of(context).textTheme.titleMedium),
          _weightSlider('科目重要性', _importance, (v) => setState(() => _importance = v)),
          _weightSlider('复杂度权重', _wComplexity, (v) => setState(() => _wComplexity = v)),
          _weightSlider('理解难度权重', _wUnderstand, (v) => setState(() => _wUnderstand = v)),
          _weightSlider('冗余度权重', _wRedundancy, (v) => setState(() => _wRedundancy = v)),
          _weightSlider('覆盖率权重', _wCoverage, (v) => setState(() => _wCoverage = v)),
          FilledButton(onPressed: _saveWeights, child: const Text('保存权重')),
          const Divider(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('知识点', style: Theme.of(context).textTheme.titleMedium),
              IconButton(onPressed: _addKp, icon: const Icon(Icons.add)),
            ],
          ),
          for (final kp in _kps)
            ListTile(
              title: Text(kp['name'] as String),
              dense: true,
            ),
        ],
      ),
    );
  }
}
