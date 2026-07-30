import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/practice_screen.dart';
import 'screens/settings_screen.dart';

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
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _appState = AppState();
    // 延迟初始化：等下一帧 widget 树挂好后再操作数据库，
    // 避免 initState 期间数据库未就绪导致静默失败
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _appState.init();
      _loadTheme();
    });
  }

  Future<void> _loadTheme() async {
    final mode = await _appState.getConfig('theme_mode');
    if (mode != null && mounted) {
      setState(() {
        _themeMode = mode == 'light'
            ? ThemeMode.light
            : mode == 'system'
                ? ThemeMode.system
                : ThemeMode.dark;
      });
    }
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
        themeMode: _themeMode,
        theme: ThemeData.light().copyWith(
          scaffoldBackgroundColor: const Color(0xFFF5F5F5),
          colorScheme: const ColorScheme.light(
            primary: Color(0xFFFF8C42),
            secondary: Color(0xFFFF8C42),
            surface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            elevation: 0.5,
          ),
          cardTheme: CardThemeData(
            color: Colors.white,
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        darkTheme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF1A1A2E),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF8C42),
            secondary: Color(0xFFFF8C42),
            surface: Color(0xFF16213E),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF16213E),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          cardTheme: CardThemeData(
            color: Color(0xFF16213E),
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        home: MixHome(
          onThemeChanged: (mode) {
            if (mounted) setState(() => _themeMode = mode);
          },
        ),
      ),
    );
  }
}

class MixHome extends StatefulWidget {
  const MixHome({super.key, required this.onThemeChanged});

  final ValueChanged<ThemeMode> onThemeChanged;

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5F5F5);
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            _buildTabBar(isDark),
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

  Widget _buildTabBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: isDark ? const Color(0xFF16213E) : Colors.white,
      child: Row(
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Color(0xFFFF8C42), size: 22),
              const SizedBox(width: 8),
              Text('Mix',
                  style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const Spacer(),
          _tabButton('AI', 0, isDark),
          _tabButton('刷题', 1, isDark),
          _tabButton('文件', 2, isDark),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(onThemeChanged: widget.onThemeChanged),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.settings, color: isDark ? Colors.white38 : Colors.black45, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int page, bool isDark) {
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
                color: isActive
                    ? const Color(0xFFFF8C42)
                    : (isDark ? Colors.white54 : Colors.black45),
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text('AI 对话',
                style: TextStyle(color: Colors.white38, fontSize: 18)),
            SizedBox(height: 8),
            Text('在设置中配置 API Key 后开始对话',
                style: TextStyle(color: Colors.white24, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class FilesScreen extends StatelessWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
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
