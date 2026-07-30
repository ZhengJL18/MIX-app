/// ⚠️ 此文件在当前版本中未被使用（main.dart 直接内联了页面切换逻辑）。
/// 保留以供参考——如果需要恢复"经典首页"导航模式，可以在此之上重建。
import 'package:flutter/material.dart';

import 'practice_screen.dart';
import 'stats_screen.dart';
import 'subject_management_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mix 算法引擎')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HomeCard(
            icon: Icons.edit_note,
            title: '开始刷题',
            subtitle: '三层筛选自动出题，做对做错都会更新掌握度模型',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PracticeScreen()),
            ),
          ),
          _HomeCard(
            icon: Icons.menu_book,
            title: '科目管理',
            subtitle: '管理科目、知识点，以及四维权重（AI 微调预留接口）',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SubjectManagementScreen()),
            ),
          ),
          _HomeCard(
            icon: Icons.insights,
            title: '学习统计',
            subtitle: '查看正确率与各科目掌握度概览',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const StatsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
