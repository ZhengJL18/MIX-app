import 'dart:convert';

import 'package:flutter/material.dart';

import '../repository/practice_repository.dart';
import '../theme/app_colors.dart';
import '../widgets/rich_content.dart';

/// 错题回顾 — 展示最近做错的题目、正确答案与解析。
class WrongQuestionsScreen extends StatefulWidget {
  const WrongQuestionsScreen({super.key});

  @override
  State<WrongQuestionsScreen> createState() => _WrongQuestionsScreenState();
}

class _WrongQuestionsScreenState extends State<WrongQuestionsScreen> {
  final _repo = PracticeRepository();
  List<Map<String, dynamic>> _questions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await _repo.getRecentWrongQuestions(1);
    if (!mounted) return;
    setState(() {
      _questions = rows;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: AppColors.lightBg,
        title: const Text('错题回顾'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _questions.isEmpty
              ? Center(
                  child: Text('还没有做错的题，继续加油！',
                      style: TextStyle(color: AppColors.lightTextMuted, fontSize: 15)),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _questions.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _WrongQuestionCard(q: _questions[i]),
                  ),
                ),
    );
  }
}

class _WrongQuestionCard extends StatelessWidget {
  final Map<String, dynamic> q;
  const _WrongQuestionCard({required this.q});

  List<String> _parseOptions(dynamic raw) {
    if (raw == null) return const [];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {}
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final options = _parseOptions(q['options']);
    final answer = q['answer'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.lightSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lightDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.wrong.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('错题',
                    style: TextStyle(color: AppColors.wrong, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${q['subject_name']} · ${q['kp_name']}',
                  style: TextStyle(color: AppColors.lightTextMuted, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          RichContent(
            content: q['content'] as String? ?? '',
            style: TextStyle(color: AppColors.lightText, fontSize: 15, height: 1.6),
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (var i = 0; i < options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: RichContent(
                  content: '${String.fromCharCode('A'.codeUnitAt(0) + i)}. ${options[i]}',
                  style: TextStyle(
                    color: options[i] == answer ? AppColors.correct : AppColors.lightTextMuted,
                    fontSize: 13,
                    fontWeight: options[i] == answer ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
          ],
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primaryLight,
              borderRadius: BorderRadius.circular(8),
            ),
            child: RichContent(
              content: '正确答案：$answer',
              style: TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if ((q['explanation'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            RichContent(
              content: '解析：${q['explanation']}',
              style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
