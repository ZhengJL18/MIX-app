import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/app_theme.dart';
import 'theme/app_palette.dart';
import 'providers/app_state.dart';
import 'providers/theme_provider.dart';
import 'screens/practice_screen.dart';
import 'screens/subject_management_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/ai_settings_screen.dart';
import 'screens/wrong_questions_screen.dart';
import 'services/native_agent_bridge.dart';
import 'services/update_service.dart';
import 'models/message_block.dart';
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
        // 让所有用 context.appPalette.xxx（全局 getter）的组件重新读新色板，
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

  /// 原生 Hermes Agent 桥接 — 进程内运行，App 入口持有。
  final NativeAgentBridge _agent = NativeAgentBridge();

  @override
  void initState() {
    super.initState();
    _checkOnboarding();
    // 预初始化记忆/会话存储（无解压/无子进程，很轻）
    _agent.start();
    // 自动更新检查（fire-and-forget，失败静默不打扰）
    _checkUpdate();
  }

  /// 启动时静默检查更新，有新版且 onboarding 已完成 → 弹窗提示。
  Future<void> _checkUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (!mounted || info == null) return;
    final prefs = await SharedPreferences.getInstance();
    final complete = prefs.getBool('onboarding_complete') ?? false;
    if (!mounted || !complete) return; // onboarding 未完成不打扰
    _showUpdateDialog(info);
  }

  void _showUpdateDialog(UpdateInfo info) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('发现新版本 v${info.version}'),
        content: SingleChildScrollView(
          child: Text(info.notes?.trim().isNotEmpty == true
              ? info.notes!
              : '有新版本可用，点击更新。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _downloadAndInstall(info);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(UpdateInfo info) async {
    if (!mounted) return;
    // 下载进度提示
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在下载更新...'),
          ],
        ),
      ),
    );
    final ok = await UpdateService.downloadAndInstall(info.downloadUrl);
    if (!mounted) return;
    Navigator.of(context).pop(); // 关下载提示
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('下载失败，请稍后重试')),
      );
    }
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
      onComplete: () async {
        if (mounted) setState(() => _onboardingComplete = true);
      },
    );
  }
}

/// 主界面框架
class _MainShell extends StatefulWidget {
  final NativeAgentBridge agent;
  const _MainShell({required this.agent});

  @override
  State<_MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<_MainShell> {
  final PageController _pageController = PageController(initialPage: 1);
  int _currentPage = 1;

  /// 原生 Hermes Agent 桥接层 — 由 App 入口传入
  late final NativeAgentBridge _agent = widget.agent;

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
                      _ChatScreen(agent: _agent),
                      const PracticeScreen(),
                      _FilesScreen(agent: _agent),
                    ],
                  ),
                ),
              ],
            ),
          ),
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
                Icon(Icons.auto_awesome, color: context.appPalette.primary, size: 22),
                SizedBox(width: 6),
                Text('Mix',
                    style: TextStyle(
                        color: context.appPalette.text,
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

  /// 打开 AI 设置页（原生 agent 每次 send 实时读配置，无需通知刷新）
  Future<void> _openAiSettings() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
    );
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
      backgroundColor: context.appPalette.surface,
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
                color: context.appPalette.divider,
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
      leading: Icon(icon, color: context.appPalette.primary),
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
              ? context.appPalette.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? context.appPalette.primary : context.appPalette.textMuted),
            SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: active ? context.appPalette.primary : context.appPalette.textMuted,
                    fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}

/// AI 对话页 — 用原生 Hermes Agent（带工具/记忆）+ 云端直连兜底
class _ChatScreen extends StatefulWidget {
  final NativeAgentBridge agent;
  const _ChatScreen({required this.agent});

  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<MessageBlock> _messages = [];
  final Set<String> _userMsgIds = {};
  bool _sending = false;

  // 切 tab 时不销毁本页（PageView 默认会 dispose 离开的页）。
  // 保持存活 → _streamSub 不取消 → Agent 回复在后台继续，
  // 切回来状态完整（用户要的"冻结当前状态"）。
  @override
  bool get wantKeepAlive => true;

  StreamSubscription<MessageBlock>? _streamSub;

  static const String _historyKey = 'chat_history_blocks';
  static const String _historyUserIdsKey = 'chat_history_user_ids';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
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
    // 原生 agent 进程内随时可用；无配置时 send 会给出友好错误块
    _input.clear();
    setState(() {
      final um = TextBlock(id: generateBlockId(), content: text);
      _userMsgIds.add(um.id);
      _messages.add(um);
      _sending = true;
    });
    _persistHistory();
    _scrollToBottom();

    // 原生 Hermes Agent（进程内，带记忆/文件/网络工具，与 App 共用同一模型）
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
          // 每个块持久化：流式到一半退出，已显示文本不丢（途径A冻结）
          _persistHistory();
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
                  ? context.appPalette.primary
                  : (t.isError ? context.appPalette.wrong : context.appPalette.surfaceAlt),
              borderRadius: BorderRadius.circular(14),
            ),
            child: isUser || t.isError || t.isStreaming
                ? Text(
                    t.content.isEmpty ? '…' : t.content,
                    style: TextStyle(
                      color: isUser ? Colors.white : context.appPalette.text,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  )
                : MarkdownBody(
                    data: t.content,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                      p: TextStyle(color: context.appPalette.text, fontSize: 14, height: 1.5),
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
              color: s.isWarning ? context.appPalette.primaryLight : context.appPalette.surfaceAlt,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  s.isWarning ? Icons.warning_amber : Icons.info_outline,
                  size: 14,
                  color: context.appPalette.textMuted,
                ),
                SizedBox(width: 6),
                Flexible(
                  child: Text(
                    s.text,
                    style: TextStyle(color: context.appPalette.textMuted, fontSize: 12),
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
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    return Container(
      color: context.appPalette.bg,
      child: Column(
        children: [
          // 顶部 Agent 状态条（原生 Hermes 进程内运行，恒就绪）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Icon(Icons.bolt, size: 14, color: context.appPalette.correct),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '原生 Hermes Agent 已就绪',
                    style: TextStyle(color: context.appPalette.textMuted, fontSize: 12),
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
                        Icon(Icons.chat_bubble_outline, color: context.appPalette.textMuted, size: 56),
                        SizedBox(height: 12),
                        Text('问我任何学习问题',
                            style: TextStyle(color: context.appPalette.textMuted, fontSize: 16)),
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
                    enabled: !_sending,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '输入问题...',
                      hintStyle: TextStyle(color: context.appPalette.textMuted),
                      filled: true,
                      fillColor: context.appPalette.surfaceAlt,
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
                  onTap: _sending ? _stopStreaming : _send,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _sending
                          ? context.appPalette.textMuted
                          : context.appPalette.primary,
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
          color: context.appPalette.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.appPalette.divider),
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
                          ? context.appPalette.wrong
                          : b.isRunning
                              ? context.appPalette.secondary
                              : context.appPalette.correct,
                    ),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        b.toolLabel,
                        style: TextStyle(
                          color: context.appPalette.textMuted,
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
                        color: context.appPalette.textMuted,
                      ),
                  ],
                ),
                if (b.expanded && (b.resultSummary != null || b.errorMessage != null))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      b.errorMessage ?? b.resultSummary ?? '',
                      style: TextStyle(
                        color: b.isError ? context.appPalette.wrong : context.appPalette.textMuted,
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

/// 文件管理页 — 显示原生 Hermes Agent 状态、AI 配置状态与数据说明
class _FilesScreen extends StatefulWidget {
  final NativeAgentBridge agent;
  const _FilesScreen({required this.agent});

  @override
  State<_FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<_FilesScreen> {
  bool _aiConfigured = false;

  @override
  void initState() {
    super.initState();
    _checkAi();
  }

  Future<void> _checkAi() async {
    final settings = await widget.agent.readAiSettings();
    if (!mounted) return;
    setState(() => _aiConfigured = settings != null);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.appPalette.bg,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _InfoCard(
            icon: Icons.auto_awesome,
            title: '原生 Hermes Agent',
            subtitle: '进程内运行，带记忆/文件/网络工具，可直接在 AI 对话页使用',
            trailing: Icon(Icons.check_circle, color: context.appPalette.correct, size: 20),
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
              color: _aiConfigured ? context.appPalette.correct : context.appPalette.secondary,
              size: 20,
            ),
          ),
          SizedBox(height: 12),
          _InfoCard(
            icon: Icons.storage,
            title: '数据存储',
            subtitle: '学习数据、题目与做题记录均保存在本机，不上传云端',
            trailing: Icon(Icons.lock_outline, color: context.appPalette.textMuted, size: 20),
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
        color: context.appPalette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appPalette.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: context.appPalette.primary, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(color: context.appPalette.text, fontSize: 15, fontWeight: FontWeight.w600)),
                SizedBox(height: 4),
                Text(subtitle,
                    style: TextStyle(color: context.appPalette.textMuted, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}
