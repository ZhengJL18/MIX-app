import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'theme/app_colors.dart';
import 'providers/app_state.dart';
import 'screens/practice_screen.dart';
import 'screens/subject_management_screen.dart';
import 'screens/stats_screen.dart';
import 'services/agent_bridge.dart';
import 'services/ai_service.dart';
import 'data/preset_data.dart';
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
          // 左上角 Logo = 二级菜单入口
          GestureDetector(
            onTap: _openMenu,
            child: Row(
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
          ),
          const Spacer(),
          _tabButton('AI', 0, isActive),
          _tabButton('刷题', 1, isActive),
          _tabButton('文件', 2, isActive),
        ],
      ),
    );
  }

  /// 二级菜单：点左上角 Logo 弹出
  void _openMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.lightDivider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
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
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFFFF6B35)),
      title: Text(label),
      onTap: onTap,
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

/// AI 对话页 — 优先用配置的外部 AI，Hermes 本地 Agent 作为补充状态显示
class _ChatScreen extends StatefulWidget {
  final AgentBridge agent;
  const _ChatScreen({required this.agent});

  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<Map<String, String>> _messages = [];
  bool _sending = false;

  OpenAiCompatibleAiService? _ai;

  @override
  void initState() {
    super.initState();
    _loadAi();
  }

  Future<void> _loadAi() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('api_key') ?? '';
    final model = prefs.getString('ai_model') ?? '';
    final vendor = prefs.getString('ai_vendor') ?? '';
    if (key.isEmpty || model.isEmpty || vendor.isEmpty) return;

    final preset = kAiVendors.where((v) => v.id == vendor).firstOrNull;
    final base = preset?.baseUrl ?? '';
    if (base.isEmpty) return;
    final url = base.endsWith('/chat/completions') ? base : '$base/chat/completions';
    setState(() => _ai = OpenAiCompatibleAiService(baseUrl: url, model: model, apiKey: key));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending || _ai == null) return;
    _input.clear();
    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _sending = true;
    });
    _scrollToBottom();
    try {
      final reply = await _ai!.chat(text);
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'assistant', 'content': reply});
        _sending = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add({'role': 'assistant', 'content': '⚠️ $e'});
        _sending = false;
      });
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFFF8F0),
      child: Column(
        children: [
          // 顶部 Hermes 状态条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.bolt, size: 14, color: widget.agent.isRunning ? const Color(0xFF4ECDC4) : const Color(0xFFA09080)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.agent.isRunning
                        ? 'Hermes 本地已就绪'
                        : '云端 AI 对话（本地 Hermes 尚未就绪）',
                    style: const TextStyle(color: Color(0xFFA09080), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 消息列表
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, color: Color(0xFF8B7355), size: 56),
                        SizedBox(height: 12),
                        Text('问我任何学习问题',
                            style: TextStyle(color: Color(0xFF8B7355), fontSize: 16)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      final isUser = m['role'] == 'user';
                      return Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          constraints: const BoxConstraints(maxWidth: 300),
                          decoration: BoxDecoration(
                            color: isUser ? const Color(0xFFFF6B35) : const Color(0xFFF0E0D0),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            m['content'] ?? '',
                            style: TextStyle(
                              color: isUser ? Colors.white : const Color(0xFF2D1810),
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // 输入区
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: _ai != null && !_sending,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: _ai == null ? '请先在设置中配置 AI' : '输入问题...',
                      hintStyle: const TextStyle(color: Color(0xFFA09080)),
                      filled: true,
                      fillColor: const Color(0xFFFFFFFF),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _ai != null ? _send : null,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _ai != null ? const Color(0xFFFF6B35) : const Color(0xFFE0D5C7),
                      shape: BoxShape.circle,
                    ),
                    child: _sending
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send, size: 18, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
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
