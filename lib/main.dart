import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/practice_screen.dart';

/// Mix App — 主入口
///
/// 三页面：AI聊天 | 刷题 | 文件管理
/// 手势：左右滑切换页面，刷题页内上下滑切题
void main() {
  runApp(const MixApp());
}

class MixApp extends StatefulWidget {
  const MixApp({super.key});

  @override
  State<MixApp> createState() => _MixAppState();
}

class _MixAppState extends State<MixApp> {
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _appState = AppState();
    _appState.init(); // 启动时恢复持久化状态
  }

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _appState,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Mix',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF1A1A2E),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF8C42),
            secondary: Color(0xFFFF8C42),
            surface: Color(0xFF16213E),
          ),
        ),
        home: const MixHome(),
      ),
    );
  }
}

class MixHome extends StatefulWidget {
  const MixHome({super.key});

  @override
  State<MixHome> createState() => _MixHomeState();
}

class _MixHomeState extends State<MixHome> {
  final PageController _pageController = PageController(initialPage: 1);
  int _currentPage = 1;

  @override
  void initState() {
    super.initState();
    _pageController.addListener(() {
      final page = _pageController.page?.round() ?? _currentPage;
      if (page != _currentPage) {
        setState(() => _currentPage = page);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: SafeArea(
        child: Column(
          children: [
            _buildTabBar(),
            Expanded(
              child: PageView(
                controller: _pageController,
                children: const [
                  ChatScreen(),
                  PracticeScreen(),
                  FilesScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: const Color(0xFF16213E),
      child: Row(
        children: [
          const Row(
            children: [
              Icon(Icons.auto_awesome, color: Color(0xFFFF8C42), size: 22),
              SizedBox(width: 8),
              Text('Mix',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const Spacer(),
          _tabButton('AI', 0),
          _tabButton('刷题', 1),
          _tabButton('文件', 2),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int page) {
    final isActive = _currentPage == page;
    return GestureDetector(
      onTap: () => _pageController.animateToPage(page,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isActive
              ? const Color(0xFFFF8C42).withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: isActive ? const Color(0xFFFF8C42) : Colors.white54,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

/// AI 聊天页（Hermes 预留）
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text('Hermes AI 对话',
                style: TextStyle(color: Colors.white38, fontSize: 18)),
            SizedBox(height: 8),
            Text('连接 Hermes API Server 后开始对话',
                style: TextStyle(color: Colors.white24, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

/// 文件管理页（占位）
class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_outlined, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text('文件管理',
                style: TextStyle(color: Colors.white38, fontSize: 18)),
            SizedBox(height: 8),
            Text('管理学习资料和笔记',
                style: TextStyle(color: Colors.white24, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
