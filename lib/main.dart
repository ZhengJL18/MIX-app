import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'providers/app_state.dart';
import 'screens/practice_screen.dart';
import 'widgets/onboarding_flow.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MixApp());
}

class MixApp extends StatelessWidget {
  const MixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Mix',
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.light,
        home: const AppEntry(),
      ),
    );
  }
}

/// 应用入口：检测冷启动是否完成
class AppEntry extends StatefulWidget {
  const AppEntry({super.key});

  @override
  State<AppEntry> createState() => _AppEntryState();
}

class _AppEntryState extends State<AppEntry> {
  bool? _onboardingComplete;

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
  }

  Future<void> _checkOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    final complete = prefs.getBool('onboarding_complete') ?? false;
    if (!mounted) return;
    setState(() => _onboardingComplete = complete);
  }

  @override
  Widget build(BuildContext context) {
    if (_onboardingComplete == null) {
      return Scaffold(
        backgroundColor: AppTheme.light.scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_onboardingComplete == true) {
      return const _MainShell();
    }
    return OnboardingFlow(onComplete: () {
      setState(() => _onboardingComplete = true);
    });
  }
}

/// 主界面框架（原 MixHome）
class _MainShell extends StatefulWidget {
  const _MainShell();

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
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
      backgroundColor: AppTheme.light.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildTabBar(),
            Expanded(
              child: PageView(
                controller: _pageController,
                children: const [
                  _ChatScreen(),
                  PracticeScreen(),
                  _FilesScreen(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    final isActive = (int page) => _currentPage == page;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: AppTheme.light.cardTheme.color,
      child: Row(
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Color(0xFFFF6B35), size: 22),
              const SizedBox(width: 8),
              Text('Mix',
                  style: TextStyle(
                      color: const Color(0xFF2D1810),
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const Spacer(),
          _tabButton('AI', 0, isActive),
          _tabButton('刷题', 1, isActive),
          _tabButton('文件', 2, isActive),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int page, bool Function(int) isActive) {
    final active = isActive(page);
    return GestureDetector(
      onTap: () => _pageController.animateToPage(page,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFFF6B35).withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: active ? const Color(0xFFFF6B35) : const Color(0xFF8B7355),
                fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

class _ChatScreen extends StatelessWidget {
  const _ChatScreen();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF8F0),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, color: Color(0xFF8B7355), size: 64),
            SizedBox(height: 16),
            Text('Hermes AI 对话',
                style: TextStyle(color: Color(0xFF8B7355), fontSize: 18)),
            SizedBox(height: 8),
            Text('连接 Hermes API Server 后开始对话',
                style: TextStyle(color: Color(0xFFA09080), fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _FilesScreen extends StatelessWidget {
  const _FilesScreen();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF8F0),
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_outlined, color: Color(0xFF8B7355), size: 64),
            SizedBox(height: 16),
            Text('文件管理',
                style: TextStyle(color: Color(0xFF8B7355), fontSize: 18)),
            SizedBox(height: 8),
            Text('管理学习资料和笔记',
                style: TextStyle(color: Color(0xFFA09080), fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
