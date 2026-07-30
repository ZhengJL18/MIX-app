import 'dart:async';
import 'package:flutter/material.dart';
import '../db/database_helper.dart';
import '../models/message_block.dart';
import '../providers/app_state.dart';
import '../services/agent_bridge.dart';
import '../widgets/agent_message_widgets.dart';

/// AI 聊天页 — 事件驱动渲染。
///
/// 核心机制：
/// 1. 消息列表存 MessageBlock 实体，不存 Markdown 字符串
/// 2. AgentBridge 返回事件流 → 按类型分发到对应 widget
/// 3. 流式文本通过刷新回调更新，不重建 widget 树
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final List<MessageBlock> _blocks = [];
  bool _running = false;
  bool _apiConfigured = false;
  bool _agentReady = false;
  StreamSubscription? _subscription;

  // 流式气泡的刷新句柄
  final Map<String, GlobalKey<_StreamingTextBubbleState>> _streamingKeys = {};

  @override
  void initState() {
    super.initState();
    _checkConfig();
    _initAgent();
    _loadHistory();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _checkConfig() async {
    final apiKey = await context.read<AppState>().getConfig('api_key');
    if (mounted) setState(() => _apiConfigured = apiKey?.isNotEmpty == true);
  }

  Future<void> _initAgent() async {
    // MockAgentBridge 用于开发测试
    // 正式版换成 AgentBridge
    final bridge = AgentBridge(); // MockAgentBridge();

    bridge.events.listen((event) {
      if (event is AgentBridgeStatus) {
        if (event.type == 'agent_ready') {
          if (mounted) setState(() => _agentReady = true);
        }
      }
    });
  }

  Future<void> _loadHistory() async {
    final db = await DatabaseHelper.instance.database;
    final convos = await db.query('conversations', orderBy: 'updated_at DESC', limit: 1);
    if (convos.isEmpty) return;

    final msgs = await db.query('messages',
      where: 'conversation_id = ?', whereArgs: [convos.first['id']],
      orderBy: 'id ASC', limit: 20);

    if (mounted) {
      setState(() {
        for (final m in msgs) {
          _blocks.add(TextBlock(
            id: m['id'] as String,
            content: m['content'] as String,
          ));
        }
      });
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _running) return;
    _controller.clear();

    // 用户消息
    setState(() {
      _blocks.add(TextBlock(id: generateBlockId(), content: text));
      _running = true;
    });
    _scrollDown();

    // 获取 API Key
    final apiKey = await context.read<AppState>().getConfig('api_key');
    if (apiKey == null || apiKey.isEmpty) {
      setState(() {
        _blocks.add(TextBlock(
          id: generateBlockId(),
          content: '⚠️ 请先在设置中配置 API Key。',
          isError: true,
        ));
        _running = false;
      });
      return;
    }

    // 构造历史
    final history = _blocks
        .whereType<TextBlock>()
        .map((b) => {'role': b.isError ? 'user' : 'assistant', 'content': b.content})
        .toList();

    // 使用 MockAgentBridge 发消息
    // 正式版换成 AgentBridge(apiKey: apiKey, baseUrl: baseUrl)
    final bridge = MockAgentBridge();
    StreamSubscription? sub;

    sub = bridge.send(messages: history, newMessage: text).listen((block) {
      if (!mounted) return;

      setState(() {
        // 检查是否需要更新已有的流式文本块
        if (block is TextBlock && block.isStreaming) {
          final existingIdx = _blocks.indexWhere((b) =>
            b.id == block.id && b is TextBlock && b.isStreaming);
          if (existingIdx != -1) {
            // 更新已有块
            (block as TextBlock).content = (block as TextBlock).content;
            // 通知对应 widget 刷新
            _streamingKeys[block.id]?.currentState?.refresh();
            return;
          }
        }
        _blocks.add(block);
      });
      _scrollDown();

      if (block is DividerBlock) {
        setState(() => _running = false);
        sub?.cancel();
      }
    });
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7);
    final surface = isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF);

    return Container(
      color: bg,
      child: Column(
        children: [
          // API 未配置提示
          if (!_apiConfigured)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: const Color(0xFFFF8C42).withValues(alpha: 0.15),
              child: const Text('请在设置中配置 API Key 使用 AI 助手',
                  style: TextStyle(color: Color(0xFFFF8C42), fontSize: 13)),
            ),
          // 消息列表
          Expanded(
            child: _blocks.isEmpty
                ? _emptyState(isDark)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: _blocks.length,
                    itemBuilder: (_, i) => _buildBlock(_blocks[i], isDark),
                  ),
          ),
          // 输入区
          _buildInput(surface, isDark),
        ],
      ),
    );
  }

  // ── 按类型分发渲染 ──

  Widget _buildBlock(MessageBlock block, bool isDark) {
    if (block is TextBlock) {
      // 流式文本气泡需要 GlobalKey 以支持刷新
      if (block.isStreaming) {
        final key = _streamingKeys.putIfAbsent(
          block.id, () => GlobalKey<_StreamingTextBubbleState>());
        return StreamingTextBubble(key: key, block: block);
      }
      return StreamingTextBubble(block: block);
    }
    if (block is ToolCallBlock) {
      return ToolCallCard(block: block);
    }
    if (block is StatusBlock) {
      return StatusBar(block: block);
    }
    if (block is DividerBlock) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(color: Color(0xFFFF8C42)),
      );
    }
    return const SizedBox.shrink();
  }

  // ── 空状态 ──

  Widget _emptyState(bool isDark) {
    final muted = isDark ? Colors.white38 : const Color(0xFFB0A090);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_awesome, size: 52,
                color: const Color(0xFFFF8C42).withValues(alpha: 0.5)),
            const SizedBox(height: 20),
            Text('MIX AI 助手', style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.bold,
              color: isDark ? Colors.white54 : const Color(0xFF8A7A6A),
            )),
            const SizedBox(height: 8),
            Text('问学习问题 · 查科目数据 · 管理笔记', style: TextStyle(fontSize: 14, color: muted)),
            const SizedBox(height: 32),
            _suggestChip('帮我看看今天该复习什么', isDark),
            _suggestChip('列出药理学所有知识点', isDark),
            _suggestChip('我最近的薄弱点是什么', isDark),
          ],
        ),
      ),
    );
  }

  Widget _suggestChip(String text, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () {
          _controller.text = text;
          _send();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF16213E) : const Color(0xFFFEF9EF),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: isDark ? Colors.white12 : const Color(0xFFD8D0C0)),
          ),
          child: Text(text, style: TextStyle(fontSize: 14,
              color: isDark ? Colors.white54 : const Color(0xFF8A7A6A))),
        ),
      ),
    );
  }

  // ── 输入区 ──

  Widget _buildInput(Color surface, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      color: surface,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                enabled: !_running,
                maxLines: 4,
                minLines: 1,
                decoration: InputDecoration(
                  hintText: _running ? 'AI 思考中...' : '问学习问题...',
                  hintStyle: TextStyle(
                      color: isDark ? Colors.white24 : const Color(0xFFC0B8A8)),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFF5ECD7),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: _running ? null : (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _running ? null : _send,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 46, height: 46,
                decoration: BoxDecoration(
                  color: _running ? Colors.grey : const Color(0xFFFF8C42),
                  borderRadius: BorderRadius.circular(23),
                ),
                child: const Icon(Icons.arrow_upward, color: Colors.white, size: 22),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
