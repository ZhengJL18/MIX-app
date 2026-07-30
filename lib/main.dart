import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/app_state.dart';
import 'screens/practice_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subject_management_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/files_screen.dart';
import 'screens/quick_notes_screen.dart';
import 'screens/chat_screen.dart';

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
        title: 'MIX',
        themeMode: _themeMode,
        theme: ThemeData.light().copyWith(
          scaffoldBackgroundColor: const Color(0xFFF5ECD7),
          colorScheme: const ColorScheme.light(
            primary: Color(0xFFFF8C42),
            secondary: Color(0xFFFF8C42),
            surface: Color(0xFFFEF9EF),
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFFF5ECD7),
            foregroundColor: Color(0xFF3A3A3A),
            elevation: 0.5,
          ),
          cardTheme: CardThemeData(
            color: const Color(0xFFFEF9EF),
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

  void _openMenu() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            _menuItem(ctx, Icons.settings, '设置', () {
              Navigator.of(ctx).pop();
              Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => SettingsScreen(onThemeChanged: widget.onThemeChanged),
              ));
            }),
            _menuItem(ctx, Icons.menu_book, '科目管理', () {
              Navigator.of(ctx).pop();
              Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const SubjectManagementScreen(),
              ));
            }),
            _menuItem(ctx, Icons.insights, '学习统计', () {
              Navigator.of(ctx).pop();
              Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const StatsScreen(),
              ));
            }),
            _menuItem(ctx, Icons.folder_open, '文件管理', () {
              Navigator.of(ctx).pop();
              Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const FilesScreen(),
              ));
            }),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFFFF8C42)),
      title: Text(label),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7);
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
                  QuickNotesScreen(),
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
      color: isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF),
      child: Row(
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Color(0xFFFF8C42), size: 22),
              const SizedBox(width: 8),
              Text('MIX',
                  style: TextStyle(
                      color: isDark ? Colors.white : const Color(0xFF3A3A3A),
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const Spacer(),
          _tabButton('AI', 0, isDark),
          _tabButton('刷题', 1, isDark),
          _tabButton('笔记', 2, isDark),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: _openMenu,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.person_outline, color: isDark ? Colors.white54 : const Color(0xFF8A7A6A), size: 22),
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
                    : (isDark ? Colors.white54 : const Color(0xFF8A7A6A)),
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

