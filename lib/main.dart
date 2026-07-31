import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'providers/app_state.dart';
import 'screens/practice_screen.dart';
import 'services/agent_bridge.dart';
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

/// 主界面框架
class _MainShell extends StatefulWidget {
  const _MainShell();

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  final PageController _pageController = PageController(initialPage: 1);
  int _currentPage = 1;

  /// Hermes Agent 桥接层 — 主界面生命周期内持有
  final AgentBridge _agent = AgentBridge();

  @override
  void initState() {
    super.initState();
    _pageController.addListener(() {
      final page = _pageController.page?.round() ?? _currentPage;
      if (page != _currentPage) {
        setState(() => _currentPage = page);
      }
    });
    // 启动时拉起 Hermes Agent（异步，失败不阻塞主界面）
    _agent.start();
  }

  @override
  void dispose() {
    _agent.dispose();
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
                children: [
                  _ChatScreen(agent: _agent),
                  const PracticeScreen(),
                  _FilesScreen(agent: _agent),
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

/// AI 对话页 — 显示 Hermes Agent 启动状态
class _ChatScreen extends StatefulWidget {
  final AgentBridge agent;
  const _ChatScreen({required this.agent});

  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen> {
  StreamSubscription? _sub;
  String _status = '正在启动 Hermes...';
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.agent.events.listen((e) {
      if (!mounted) return;
      if (e is AgentBridgeStatus) {
        setState(() {
          _ready = true;
          _status = e.message;
          _error = null;
        });
      } else if (e is AgentBridgeError) {
        setState(() {
          _ready = false;
          _error = e.message;
        });
      }
    });
    // 若 Agent 已在事件前就绪，直接取状态
    if (widget.agent.isRunning) {
      _status = 'Hermes 已就绪 (端口 ${widget.agent.port})';
      _ready = true;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF8F0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _ready ? Icons.check_circle : Icons.chat_bubble_outline,
              color: _ready ? const Color(0xFF4ECDC4) : const Color(0xFF8B7355),
              size: 64,
            ),
            const SizedBox(height: 16),
            Text('Hermes AI 对话',
                style: const TextStyle(color: Color(0xFF8B7355), fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              _error ?? _status,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _error != null ? const Color(0xFFFF6B6B) : const Color(0xFFA09080),
                fontSize: 14,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _status = '正在重新启动 Hermes...';
                  });
                  widget.agent.start();
                },
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 文件管理页 — 显示 Hermes 运行状态 + bundle 信息
class _FilesScreen extends StatelessWidget {
  final AgentBridge agent;
  const _FilesScreen({required this.agent});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF8F0),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_outlined,
                color: agent.isInitialized ? const Color(0xFFFFB347) : const Color(0xFF8B7355),
                size: 64),
            const SizedBox(height: 16),
            Text('文件管理',
                style: const TextStyle(color: Color(0xFF8B7355), fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              agent.isInitialized
                  ? 'Hermes 环境已初始化'
                  : '管理学习资料和笔记',
              style: const TextStyle(color: Color(0xFFA09080), fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
