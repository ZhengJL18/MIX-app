// 导入工具文件只为触发自注册副作用，analyzer 视为 unused → 文件级忽略
// ignore_for_file: unused_import

import 'dart:async';

import 'package:path_provider/path_provider.dart';

import '../hermes/agent/agent.dart';
import '../hermes/db/session_db.dart';
import '../hermes/llm/openai_llm.dart';
// 导入工具文件即触发自注册（registry.register 在库加载时执行）
import '../hermes/tools/clarify_tool.dart';
import '../hermes/tools/company_tool.dart';
import '../hermes/tools/cron_tools.dart';
import '../hermes/tools/delegate_tool.dart';
import '../hermes/tools/file_tools.dart';
import '../hermes/tools/memory_manager.dart';
import '../hermes/tools/memory_tool.dart';
import '../hermes/tools/moa_tool.dart';
import '../hermes/tools/model_tools.dart';
import '../hermes/tools/session_search_tool.dart';
import '../hermes/tools/skills_tool.dart';
import '../hermes/tools/todo_tool.dart';
import '../hermes/tools/vision_tool.dart';
import '../hermes/tools/web_tools.dart';
import '../models/ai_settings.dart';
import '../models/message_block.dart';

/// 原生 Hermes Agent 桥接 — 用 hermes-app 的纯 Dart `JailerAgent` 替换
/// 打包的 Python bundle + gateway 子进程。
///
/// 设计：
/// - 进程内运行，无解压/无子进程/无端口。首次 lazily 初始化记忆/会话/技能。
/// - 每个 send() 构造一个 JailerAgent（携带本次回调），记忆/会话实例全局共享。
/// - 记忆系统（MemoryManager）就是「教学记忆」的载体——Agent 自己写自己读。
class NativeAgentBridge {
  bool _initialized = false;

  SessionDB? _sessionDb;
  MemoryManager? _memory;

  /// 原生 agent 进程内运行，无需启动/预热，永远就绪。
  bool get isRunning => true;
  bool get isInitialized => _initialized;
  bool get hasFailed => false;

  /// 无 bundle/子进程，启动是 no-op（记忆/会话首次 send 时 lazily 初始化）。
  Future<void> start() async => ensureInitialized();

  Future<AiSettings?> readAiSettings() => AiSettings.load();

  /// 原生 agent 每次 send 都实时读 AiSettings，无需重启 gateway。
  Future<void> applyAiSettings(AiSettings settings) async {
    await settings.save();
  }

  /// 首次调用时初始化：应用文件目录 + 记忆 + 会话 + 技能。
  Future<void> ensureInitialized() async {
    if (_initialized) return;

    // Android 下 = /data/data/<pkg>/files，与学科画像 subject_library 同根，
    // agent 的 file 工具能读到 0号文件。
    final dir = (await getApplicationSupportDirectory()).path;
    configureFileTools(cwd: dir);

    registerMemoryTool(baseDir: dir);
    _memory = MemoryManager(store: memoryStore!);

    final sdb = SessionDB(dbPath: '$dir/state.db');
    await sdb.init();
    await sdb.createSession('main', source: 'app');
    _sessionDb = sdb;
    sessionDb = sdb; // session_search 工具的全局

    registerSkillTools(skillsRoot: '$dir/skills');
    _initialized = true;
  }

  /// 发送一条消息，返回流式 [MessageBlock] 事件。
  ///
  /// [messages] 历史（不含当前消息，[newMessage] 会追加），
  /// [newMessage] 当前输入。
  Stream<MessageBlock> send({
    required List<Map<String, dynamic>> messages,
    required String newMessage,
  }) async* {
    await ensureInitialized();

    final settings = await AiSettings.load();
    if (settings == null || !settings.isComplete) {
      yield TextBlock(
        id: generateBlockId(),
        content: '⚠️ 尚未配置 AI 接口，请先在「AI 设置」填入 API Key。',
        isError: true,
      );
      return;
    }

    final controller = StreamController<MessageBlock>();
    // 后台跑 agent，事件实时写入 controller
    final running = _runConversation(
      controller: controller,
      settings: settings,
      messages: messages,
      newMessage: newMessage,
    );
    // 先挂上监听，再消费事件（_runConversation 首行让出，保证先 attach）
    await for (final block in controller.stream) {
      yield block;
    }
    await running; // agent 抛错在此传播
  }

  Future<void> _runConversation({
    required StreamController<MessageBlock> controller,
    required AiSettings settings,
    required List<Map<String, dynamic>> messages,
    required String newMessage,
  }) async {
    // 让出事件循环：确保 send() 的 await for 已挂上 controller 监听，
    // 否则 onDelta 的 add 会被缓冲成一次性投递，失去流式渲染。
    await Future<void>.delayed(Duration.zero);

    TextBlock? currentText;
    final Map<String, ToolCallBlock> toolBlocks = {};

    final agent = JailerAgent(
      llm: OpenAiLlmClient(
        config: LlmConfig(
          baseUrl: settings.baseUrl,
          apiKey: settings.apiKey,
          model: settings.model,
        ),
      ),
      systemPrompt: _systemPrompt(),
      toolDefinitionsProvider: () => getToolDefinitions(),
      memoryManager: _memory,
      sessionDb: _sessionDb,
      sessionId: 'main',
      onDelta: (delta) {
        currentText ??= TextBlock(id: generateBlockId(), isStreaming: true);
        currentText!.append(delta);
        controller.add(currentText!);
      },
      onToolEvent: (name, status) {
        final block = toolBlocks[name];
        if (status == 'running' && block == null) {
          final b = ToolCallBlock(
            id: generateBlockId(),
            toolName: name,
            toolLabel: name,
            status: 'running',
          );
          toolBlocks[name] = b;
          controller.add(b);
        } else if (status == 'done' && block != null) {
          block.status = 'success';
          controller.add(block);
        }
      },
    );

    try {
      final result = await agent.runConversation(
        newMessage,
        conversationHistory: messages,
      );
      // 纯工具回合可能无 onDelta → 用最终结果兜底
      if (currentText == null && (result.finalResponse ?? '').isNotEmpty) {
        controller.add(TextBlock(
          id: generateBlockId(),
          content: result.finalResponse!,
        ));
      } else if (currentText != null) {
        currentText!.finish();
        controller.add(currentText!);
      }
      controller.add(DividerBlock());
    } catch (e) {
      if (currentText != null) {
        currentText!.markError('通信中断: $e');
        controller.add(currentText!);
      } else {
        controller.add(TextBlock(
          id: generateBlockId(),
          content: '⚠️ $e',
          isError: true,
        ));
      }
    } finally {
      await controller.close();
    }
  }

  String _systemPrompt() {
    return '你是 MIX 学习助手，一个 AI 学习教练。你拥有文件/记忆/网络等工具，'
        '可以用工具读写学习资料与长期记忆。用中文简洁回答，结合学生的学科画像'
        '与近况给出针对性的讲解与建议。';
  }
}
