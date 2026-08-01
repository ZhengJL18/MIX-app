import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'theme/app_palette.dart';
import 'theme/app_colors.dart';
import 'providers/app_state.dart';
import 'providers/theme_provider.dart';
import 'screens/practice_screen.dart';
import 'screens/subject_management_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/ai_settings_screen.dart';
import 'screens/wrong_questions_screen.dart';
import 'services/agent_bridge.dart';
import 'services/ai_service.dart';
import 'models/message_block.dart';
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
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const _ThemedApp(),
    );
  }
}

/// 根据 ThemeProvider 选择主题构建 MaterialApp。
class _ThemedApp extends StatefulWidget {
  const _ThemedApp();

  @override
  State<_ThemedApp> createState() => _ThemedAppState();
}

class _ThemedAppState extends State<_ThemedApp> {
  @override
  void initState() {
    super.initState();
    // 加载已保存的主题偏好
    Future.microtask(() => context.read<ThemeProvider>().load());
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        final id = themeProvider.themeId;
        // key 随主题/明暗变化 → 强制整棵 MaterialApp 重建，
        // 让所有用 AppColors.xxx（全局 getter）的组件重新读新色板，
        // 否则主题切换后页面颜色不刷新。
        return MaterialApp(
          key: ValueKey('${id.id}-${themeProvider.mode.name}'),
          debugShowCheckedModeBanner: false,
          title: 'Mix',
          theme: AppTheme.build(id, brightness: Brightness.light),
          darkTheme: AppTheme.build(id, brightness: Brightness.dark),
          themeMode: themeProvider.mode,
          home: const AppEntry(),
        );
      },
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

  /// Hermes Agent 桥接层 — App 入口持有，onboarding 期间即后台解压预热
  final AgentBridge _agent = AgentBridge();

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    // 首次启动就提前拉起 Hermes（后台解压/启动），
    // 避免用户完成引导后才开始等 80MB 解压
    _agent.start();
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
      return _MainShell(agent: _agent);
    }
    return OnboardingFlow(
      agent: _agent,
      onComplete: () async {
        // onboarding 刚写入 AI 配置，重新同步给 Hermes（预热时可能用了空配置）
        await _agent.applySavedSettings();
        if (mounted) setState(() => _onboardingComplete = true);
      },
    );
  }
}

/// 主界面框架
class _MainShell extends StatefulWidget {
  final AgentBridge agent;
  const _MainShell({required this.agent});

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  final PageController _pageController = PageController(initialPage: 1);
  int _currentPage = 1;

  /// Hermes Agent 桥接层 — 由 App 入口传入（onboarding 期间已预热）
  late final AgentBridge _agent = widget.agent;

  /// AI 配置版本号 — 设置页保存后递增，通知 ChatScreen 重新加载模型
  int _aiConfigVersion = 0;

  /// Hermes 解压/启动进度（null = 未在解压，100 = 就绪）
  int? _agentProgress;
  String _agentStatus = '';
  StreamSubscription? _agentSub;

  @override
  void initState() {
    super.initState();
    _pageController.addListener(() {
      final page = _pageController.page?.round() ?? _currentPage;
      if (page != _currentPage) {
        setState(() => _currentPage = page);
      }
    });
    // 订阅 Hermes 进度事件（首次启动解压时全屏显示进度条）
    _agentSub = _agent.events.listen((e) {
      if (!mounted) return;
      if (e is AgentBridgeProgress) {
        setState(() {
          _agentProgress = e.percent;
          _agentStatus = e.status;
        });
        if (e.percent >= 100) {
          // 解压完成，短暂展示后消失
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) setState(() => _agentProgress = null);
          });
        }
      } else if (e is AgentBridgeError) {
        if (mounted) setState(() => _agentProgress = null);
      }
    });
    // 启动时拉起 Hermes Agent（异步，失败不阻塞主界面）
    _agent.start();
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    // agent 由 App 入口持有，此处只解绑订阅，不 dispose
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.light.scaffoldBackgroundColor,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildTabBar(),
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    children: [
                      _ChatScreen(agent: _agent, aiConfigVersion: _aiConfigVersion),
                      const PracticeScreen(),
                      _FilesScreen(agent: _agent),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Hermes 解压进度覆盖层（首次启动时显示）
          if (_agentProgress != null)
            _AgentProgressOverlay(percent: _agentProgress!, status: _agentStatus),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    final isActive = (int page) => _currentPage == page;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.light.cardTheme.color,
      child: Row(
        children: [
          // 左上角 Logo = 二级菜单入口
          GestureDetector(
            onTap: _openMenu,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, color: AppColors.primary, size: 22),
                SizedBox(width: 6),
                Text('Mix',
                    style: TextStyle(
                        color: AppColors.lightText,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const Spacer(),
          _tabButton('AI', 0, isActive, Icons.chat_bubble_outline),
          _tabButton('刷题', 1, isActive, Icons.edit_note),
          _tabButton('文件', 2, isActive, Icons.folder_outlined),
        ],
      ),
    );
  }

  /// 打开 AI 设置页（设置保存后通知 ChatScreen 刷新）
  Future<void> _openAiSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AiSettingsScreen(agent: _agent)),
    );
    if (changed == true && mounted) {
      setState(() => _aiConfigVersion++);
    }
  }

  /// 打开主题切换对话框。
  void _openThemePicker(BuildContext rootContext) {
    showDialog<void>(
      context: rootContext,
      builder: (ctx) => AlertDialog(
        title: const Text('选择主题'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final theme in AppThemeId.values)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.palettes[theme]!.primary,
                  child: const Icon(Icons.check, color: Colors.white, size: 16),
                ),
                title: Text(theme.label),
                trailing: Consumer<ThemeProvider>(
                  builder: (_, tp, __) =>
                      Icon(tp.themeId == theme ? Icons.radio_button_checked : Icons.radio_button_off,
                          color: AppTheme.palettes[theme]!.primary),
                ),
                onTap: () {
                  ctx.read<ThemeProvider>().setTheme(theme);
                  Navigator.of(ctx).pop();
                },
              ),
            const Divider(),
            // 明暗模式
            const Text('明暗模式', style: TextStyle(fontWeight: FontWeight.w600)),
            for (final mode in [
              (ThemeMode.system, '跟随系统'),
              (ThemeMode.light, '浅色'),
              (ThemeMode.dark, '深色'),
            ])
              RadioListTile<ThemeMode>(
                title: Text(mode.$2),
                value: mode.$1,
                groupValue: ctx.watch<ThemeProvider>().mode,
                onChanged: (v) => ctx.read<ThemeProvider>().setMode(v!),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('关闭')),
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
            SizedBox(height: 12),
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
            _menuItem(ctx, Icons.replay_circle_filled_outlined, '错题回顾', () {
              Navigator.of(ctx).pop();
              Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const WrongQuestionsScreen(),
              ));
            }),
            _menuItem(ctx, Icons.settings, 'AI 设置', () {
              Navigator.of(ctx).pop();
              _openAiSettings();
            }),
            _menuItem(ctx, Icons.palette_outlined, '主题', () {
              Navigator.of(ctx).pop();
              _openThemePicker(context);
            }),
            SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(BuildContext ctx, IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(label),
      onTap: onTap,
    );
  }

  Widget _tabButton(String label, int page, bool Function(int) isActive, IconData icon) {
    final active = isActive(page);
    return GestureDetector(
      onTap: () => _pageController.animateToPage(page,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? AppColors.primary : AppColors.lightTextMuted),
            SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: active ? AppColors.primary : AppColors.lightTextMuted,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}

/// Hermes 首次解压的全屏进度覆盖层
class _AgentProgressOverlay extends StatelessWidget {
  final int percent;
  final String status;
  const _AgentProgressOverlay({required this.percent, required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.lightBg.withValues(alpha: 0.98),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome, color: AppColors.primary, size: 48),
            SizedBox(height: 20),
            Text(
              '正在初始化学习环境...',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.lightText),
            ),
            SizedBox(height: 8),
            Text(
              '首次启动需解压内置 AI 引擎（只需一次）',
              style: TextStyle(fontSize: 13, color: AppColors.lightTextMuted),
            ),
            SizedBox(height: 24),
            // 进度条
            Container(
              width: 260,
              height: 8,
              decoration: BoxDecoration(
                color: AppColors.lightDivider,
                borderRadius: BorderRadius.circular(4),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (percent / 100).clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
            SizedBox(height: 12),
            Text(
              '$percent% · $status',
              style: TextStyle(fontSize: 13, color: AppColors.lightTextMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 对话页 — 优先用配置的外部 AI，Hermes 本地 Agent 作为补充状态显示
class _ChatScreen extends StatefulWidget {
  final AgentBridge agent;

  /// AI 配置版本号 — 设置页保存后递增，触发本页重新加载模型
  final int aiConfigVersion;
  const _ChatScreen({required this.agent, this.aiConfigVersion = 0});

  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<MessageBlock> _messages = [];
  final Set<String> _userMsgIds = {};
  bool _sending = false;

  StreamSubscription? _agentSub;
  StreamSubscription<MessageBlock>? _streamSub;

  OpenAiCompatibleAiService? _ai;

  static const String _historyKey = 'chat_history_blocks';
  static const String _historyUserIdsKey = 'chat_history_user_ids';

  @override
  void initState() {
    super.initState();
    _loadAi();
    _loadHistory();
    // 订阅 Hermes 事件，状态变化（失败/就绪）时刷新顶部状态条
    _agentSub = widget.agent.events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant _ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 设置页保存了新配置 → 重新加载 AI 服务
    if (oldWidget.aiConfigVersion != widget.aiConfigVersion) {
      _loadAi();
    }
  }

  Future<void> _loadAi() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString('api_key') ?? '';
    final model = prefs.getString('ai_model') ?? '';
    final vendor = prefs.getString('ai_vendor') ?? '';
    if (key.isEmpty || model.isEmpty || vendor.isEmpty) return;

    final preset = kAiVendors.where((v) => v.id == vendor).firstOrNull;
    final base = preset?.baseUrl ?? prefs.getString('ai_base_url') ?? '';
    if (base.isEmpty) return;
    final url = base.endsWith('/chat/completions') ? base : '$base/chat/completions';
    setState(() => _ai = OpenAiCompatibleAiService(baseUrl: url, model: model, apiKey: key));
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    _streamSub?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 对话历史持久化到 SharedPreferences（切 tab / 重进不丢失）
  void _persistHistory() {
    final prefsFuture = SharedPreferences.getInstance();
    prefsFuture.then((prefs) {
      prefs.setString(_historyKey, jsonEncode(_messages.map((m) => m.toMap()).toList()));
      prefs.setStringList(_historyUserIdsKey, _userMsgIds.toList());
    });
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final blocks = list
          .map((e) => MessageBlock.fromMap((e as Map).cast<String, dynamic>()))
          .whereType<MessageBlock>()
          .toList();
      if (blocks.isEmpty) return;
      final userIds = prefs.getStringList(_historyUserIdsKey) ?? [];
      if (!mounted) return;
      setState(() {
        _messages.addAll(blocks);
        _userMsgIds.addAll(userIds);
      });
      _scrollToBottom();
    } catch (_) {}
  }

  /// 停止当前流式回复
  void _stopStreaming() {
    _streamSub?.cancel();
    _streamSub = null;
    if (!mounted) return;
    setState(() {
      _sending = false;
      _messages.add(TextBlock(id: generateBlockId(), content: '（已停止生成）'));
    });
    _persistHistory();
  }

  void _onStreamDone() {
    if (!mounted) return;
    setState(() => _sending = false);
    _persistHistory();
    _scrollToBottom();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    final hermesUp = widget.agent.isRunning;
    if (!hermesUp && _ai == null) return;
    _input.clear();
    setState(() {
      final um = TextBlock(id: generateBlockId(), content: text);
      _userMsgIds.add(um.id);
      _messages.add(um);
      _sending = true;
    });
    _persistHistory();
    _scrollToBottom();

    if (!hermesUp) {
      // Hermes 未就绪时回退外部 AI
      try {
        final reply = await _ai!.chat(text);
        if (!mounted) return;
        setState(() {
          _messages.add(TextBlock(id: generateBlockId(), content: reply));
          _sending = false;
        });
        _persistHistory();
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _messages.add(TextBlock(id: generateBlockId(), content: '⚠️ $e', isError: true));
          _sending = false;
        });
        _persistHistory();
      }
      _scrollToBottom();
      return;
    }

    // 本地 Hermes Agent（与 App 共用同一模型）
    final history = _messages
        .whereType<TextBlock>()
        .toList()
        .reversed
        .skip(1) // 跳过刚加入的当前用户消息，send() 内部会用 newMessage 追加
        .toList()
        .reversed
        .map((b) => {
              'role': _userMsgIds.contains(b.id) ? 'user' : 'assistant',
              'content': b.content,
            })
        .toList();

    try {
      _streamSub = widget.agent.send(messages: history, newMessage: text).listen(
        (block) {
          if (!mounted) return;
          setState(() => _upsertBlock(block));
          _scrollToBottom();
        },
        onDone: _onStreamDone,
        onError: (Object e) {
          if (!mounted) return;
          setState(() {
            _messages.add(TextBlock(id: generateBlockId(), content: '⚠️ $e', isError: true));
            _sending = false;
          });
          _persistHistory();
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(TextBlock(id: generateBlockId(), content: '⚠️ $e', isError: true));
        _sending = false;
      });
      _persistHistory();
    }
  }

  /// 按 id 插入或更新流式消息块（Hermes 会对同一块多次 yield 累积内容）。
  void _upsertBlock(MessageBlock block) {
    final idx = _messages.indexWhere((b) => b.id == block.id);
    if (idx >= 0) {
      _messages[idx] = block;
    } else {
      _messages.add(block);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  /// 渲染一条消息块（Hermes 事件模型）。
  Widget _messageWidget(MessageBlock block) {
    switch (block.type) {
      case BlockType.text:
        final t = block as TextBlock;
        final isUser = _userMsgIds.contains(t.id);
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: isUser
                  ? AppColors.primary
                  : (t.isError ? AppColors.wrong : AppColors.lightSurfaceAlt),
              borderRadius: BorderRadius.circular(14),
            ),
            child: isUser || t.isError || t.isStreaming
                ? Text(
                    t.content.isEmpty ? '…' : t.content,
                    style: TextStyle(
                      color: isUser ? Colors.white : AppColors.lightText,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  )
                : MarkdownBody(
                    data: t.content,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                      p: TextStyle(color: AppColors.lightText, fontSize: 14, height: 1.5),
                    ),
                  ),
          ),
        );
      case BlockType.toolCall:
        return _ToolCallBubble(block as ToolCallBlock);
      case BlockType.status:
        final s = block as StatusBlock;
        return Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: s.isWarning ? AppColors.primaryLight : AppColors.lightSurfaceAlt,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  s.isWarning ? Icons.warning_amber : Icons.info_outline,
                  size: 14,
                  color: AppColors.lightTextMuted,
                ),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    s.text,
                    style: TextStyle(color: AppColors.lightTextMuted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        );
      case BlockType.divider:
        return const Divider(height: 24);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.lightBg,
      child: Column(
        children: [
          // 顶部 Hermes 状态条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.bolt,
                    size: 14,
                    color: widget.agent.isRunning
                        ? AppColors.correct
                        : widget.agent.hasFailed
                            ? AppColors.wrong
                            : AppColors.lightTextMuted),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.agent.isRunning
                        ? 'Hermes 本地已就绪'
                        : widget.agent.hasFailed
                            ? 'Hermes 启动失败'
                            : '云端 AI 对话（本地 Hermes 尚未就绪）',
                    style: TextStyle(color: AppColors.lightTextMuted, fontSize: 12),
                  ),
                ),
                if (widget.agent.hasFailed)
                  GestureDetector(
                    onTap: () => widget.agent.start(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.wrong.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('重试',
                          style: TextStyle(color: AppColors.wrong, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 消息列表
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.chat_bubble_outline, color: AppColors.lightTextMuted, size: 56),
                        SizedBox(height: 12),
                        Text('问我任何学习问题',
                            style: TextStyle(color: AppColors.lightTextMuted, fontSize: 16)),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _messageWidget(_messages[i]),
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
                    enabled: (widget.agent.isRunning || _ai != null) && !_sending,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: (widget.agent.isRunning || _ai != null)
                          ? '输入问题...'
                          : '请先在设置中配置 AI',
                      hintStyle: TextStyle(color: AppColors.lightTextMuted),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                GestureDetector(
                  onTap: _sending
                      ? _stopStreaming
                      : ((widget.agent.isRunning || _ai != null) ? _send : null),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _sending
                          ? AppColors.lightTextMuted
                          : (widget.agent.isRunning || _ai != null)
                              ? AppColors.primary
                              : AppColors.lightDivider,
                      shape: BoxShape.circle,
                    ),
                    child: _sending
                        ? const Icon(Icons.stop, size: 18, color: Colors.white)
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
/// 工具调用卡片（可点击展开结果）
class _ToolCallBubble extends StatefulWidget {
  final ToolCallBlock block;
  const _ToolCallBubble(this.block);

  @override
  State<_ToolCallBubble> createState() => _ToolCallBubbleState();
}

class _ToolCallBubbleState extends State<_ToolCallBubble> {
  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.lightSurfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.lightDivider),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: b.isRunning ? null : () => setState(() => b.toggleExpanded()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      b.isError
                          ? Icons.error_outline
                          : b.isRunning
                              ? Icons.hourglass_top
                              : Icons.check_circle_outline,
                      size: 14,
                      color: b.isError
                          ? AppColors.wrong
                          : b.isRunning
                              ? AppColors.secondary
                              : AppColors.correct,
                    ),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        b.toolLabel,
                        style: TextStyle(
                          color: AppColors.lightTextMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(width: 6),
                    if (b.isRunning)
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        b.expanded ? Icons.expand_less : Icons.expand_more,
                        size: 14,
                        color: AppColors.lightTextMuted,
                      ),
                  ],
                ),
                if (b.expanded && (b.resultSummary != null || b.errorMessage != null))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      b.errorMessage ?? b.resultSummary ?? '',
                      style: TextStyle(
                        color: b.isError ? AppColors.wrong : AppColors.lightTextMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件管理页 — 显示 Hermes 本地引擎运行状态、AI 配置状态与数据说明
class _FilesScreen extends StatefulWidget {
  final AgentBridge agent;
  const _FilesScreen({required this.agent});

  @override
  State<_FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<_FilesScreen> {
  StreamSubscription? _agentSub;
  bool _aiConfigured = false;

  @override
  void initState() {
    super.initState();
    _agentSub = widget.agent.events.listen((_) {
      if (mounted) setState(() {});
    });
    _checkAi();
  }

  @override
  void dispose() {
    _agentSub?.cancel();
    super.dispose();
  }

  Future<void> _checkAi() async {
    final settings = await widget.agent.readAiSettings();
    if (!mounted) return;
    setState(() => _aiConfigured = settings != null);
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    return Container(
      color: AppColors.lightBg,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _InfoCard(
            icon: Icons.auto_awesome,
            title: '本地 AI 引擎（Hermes）',
            subtitle: agent.isRunning
                ? '已就绪，可在 AI 对话页直接使用本地 Agent'
                : agent.hasFailed
                    ? '启动失败，请点击重试'
                    : agent.isInitialized
                        ? '环境已解压，正在启动…'
                        : '首次启动需要解压内置引擎（约 80MB）',
            trailing: agent.hasFailed
                ? TextButton(onPressed: () => agent.start(), child: const Text('重试'))
                : agent.isRunning
                    ? Icon(Icons.check_circle, color: AppColors.correct, size: 20)
                    : SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.secondary),
                      ),
          ),
          SizedBox(height: 12),
          _InfoCard(
            icon: Icons.tune,
            title: 'AI 模型配置',
            subtitle: _aiConfigured
                ? '已配置真实 AI，刷题出题与对话均可用'
                : '未配置，刷题会使用示例题，请到「AI 设置」配置',
            trailing: Icon(
              _aiConfigured ? Icons.check_circle : Icons.error_outline,
              color: _aiConfigured ? AppColors.correct : AppColors.secondary,
              size: 20,
            ),
          ),
          SizedBox(height: 12),
          _InfoCard(
            icon: Icons.storage,
            title: '数据存储',
            subtitle: '学习数据、题目与做题记录均保存在本机，不上传云端',
            trailing: Icon(Icons.lock_outline, color: AppColors.lightTextMuted, size: 20),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _InfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lightDivider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.primary, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(color: AppColors.lightText, fontSize: 15, fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(color: AppColors.lightTextMuted, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
