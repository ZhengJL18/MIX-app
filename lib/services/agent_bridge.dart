import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../models/ai_settings.dart';
import '../models/message_block.dart';

/// Agent 桥接层 — 管理 Hermes 子进程 + HTTP/SSE 通信。
///
/// 设计原则：
/// 1. 不关心进程死活 — 切前台启动，切后台杀掉
/// 2. 不搞心跳 — 死了就是死了，下次重新拉
/// 3. 通信唯一方式 — localhost HTTP/SSE，单连接
/// 4. 错误全部兜底 — 进程挂/端口忙/请求超时 → 自动重建
class AgentBridge {
  // ── 公开事件流 ──
  final StreamController<AgentBridgeEvent> _controller = StreamController.broadcast();
  Stream<AgentBridgeEvent> get events => _controller.stream;

  // ── 子进程 ──
  Process? _process;
  int _port = 0;
  bool _running = false;
  bool _initialized = false;
  bool _failed = false;
  bool _starting = false; // 防重入：解压/启动过程中多次 start() 只执行一次
  Completer<void>? _startCompleter; // 进行中的 start()，供重入调用等待

  /// Hermes api_server 的 Bearer 认证 key（API_SERVER_KEY）。
  /// 无 key 时 api_server 拒绝启动；Hermes 0.15.2 要求长度 >= 16 字符，
  /// 否则 api_server 视作弱密钥拒绝启动（见 api_server.py）。
  /// MIX 用固定内部 key 与本地 Hermes 通信。
  static const String _apiServerKey = 'mix-local-agent-2026';

  // ── 初始化状态 ──
  bool get isRunning => _running;
  bool get isInitialized => _initialized;
  bool get hasFailed => _failed;
  int get port => _port;

  /// 当前 bundle 的版本标记。bundle 内容更新时递增，
  /// 与 marker 文件比对不一致会强制重新解压，避免旧依赖残留。
  static const String _bundleVersion = '2026-07-31-android-deps-v1';

  /// 确保环境已解压（首次启动时调用）
  ///
  /// [onProgress] 可选：解压时回调进度百分比（0~100）和状态文字，
  /// 供 UI 显示可视化解压进度条。
  Future<void> ensureInitialized({
    void Function(int percent, String status)? onProgress,
  }) async {
    if (_initialized) return;

    final filesDir = Directory(await _getFilesDir());
    final marker = File('${filesDir.path}/.initialized');

    // 已解压且版本一致则直接返回
    if (await marker.exists() && await marker.readAsString() == _bundleVersion) {
      _initialized = true;
      return;
    }

    // bundle 版本变更或首次启动 → 清掉旧的第三方包，避免残留坏依赖
    final stalePkgs = Directory('${filesDir.path}/python-packages');
    if (await stalePkgs.exists()) {
      try {
        await stalePkgs.delete(recursive: true);
      } catch (e) {
        debugPrint('[AgentBridge] 清理旧 python-packages 失败: $e');
      }
    }

    // 解压 bundle
    try {
      onProgress?.call(0, '正在解压学习环境...');
      await _extractAssets(filesDir, onProgress: onProgress);
      await marker.writeAsString(_bundleVersion);
      _initialized = true;
    } catch (e) {
      debugPrint('[AgentBridge] ensureInitialized 失败: $e');
      rethrow;
    }
  }

  /// 启动 Hermes 子进程。
  ///
  /// 可重入安全：若已有启动在进行，等待同一个 Completer，保证
  /// 同一时刻只拉一个 gateway 进程（Hermes 检测到双实例会退出）。
  Future<void> start() async {
    // 已在运行或正在启动 → 等待进行中的那次完成，不重复拉进程
    if (_running) {
      debugPrint('[AgentBridge] start: 已在运行，跳过');
      return;
    }
    if (_starting) {
      final pending = _startCompleter;
      if (pending != null) {
        debugPrint('[AgentBridge] start: 等待进行中的启动');
        await pending.future;
        return;
      }
    }

    debugPrint('[AgentBridge] start: 开始全新启动');
    final completer = Completer<void>();
    _startCompleter = completer;
    _starting = true;
    _failed = false;

    try {
      await ensureInitialized(onProgress: (percent, status) {
        _controller.add(AgentBridgeProgress(percent, status));
      });
    } catch (e) {
      _starting = false;
      _startCompleter = null;
      completer.complete();
      debugPrint('[AgentBridge] ensureInitialized 失败: $e');
      _failed = true;
      _controller.add(AgentBridgeError('初始化失败', 'Hermes 环境解压失败: $e'));
      return;
    }

    final filesDir = await _getFilesDir();
    // Hermes gateway api_server 固定端口 8642（见 api_server.py DEFAULT_PORT）
    _port = 8642;

    // 若端口已被监听（gateway 已在跑，例如重复 start() 或上次残留），
    // 直接复用，不再拉第二个进程（否则 Hermes 检测到双实例会退出）。
    if (await _isPortListening(_port)) {
      debugPrint('[AgentBridge] gateway 已在运行，直接复用端口 $_port');
      _running = true;
      _failed = false;
      _starting = false;
      _startCompleter = null;
      completer.complete();
      _controller.add(AgentBridgeStatus('agent_ready', 'Hermes 已就绪'));
      return;
    }

    try {
      final pythonBin = '${filesDir}/python/python3.14';
      final pkgDir = '${filesDir}/python-packages';
      final srcDir = '${filesDir}/hermes-source';
      final hermesHome = '$filesDir/.hermes';

      // 把 App 的 AI 配置同步给 Hermes（同一份模型/provider/key）
      await _writeHermesAiConfig();

      // 清掉 gateway 残留锁/pid 文件（上次崩溃或卸载残留的旧 PID），
      // 否则 Hermes 启动时读到旧锁误判"已有实例"主动退出
      // （日志: Another gateway instance...Exiting to avoid double-running）。
      final hermesLockDir = Directory('$hermesHome');
      if (await hermesLockDir.exists()) {
        for (final name in ['gateway.lock', 'gateway.pid']) {
          final f = File('$hermesHome/$name');
          if (await f.exists()) {
            try {
              await f.delete();
            } catch (e) {
              debugPrint('[AgentBridge] 清理 gateway 锁失败 $name: $e');
            }
          }
        }
      }

      // Hermes 0.15.2 通过 gateway 暴露 OpenAI 兼容 API（/v1/chat/completions）。
      // 端口由 api_server 的 DEFAULT_PORT=8642 决定，agent_bridge 从 /health 读取。
      //
      // 华为 SELinux 策略拒绝 App 直接执行 app_data_file 里的 ELF 二进制
      // （avc: denied execute_no_trans），直接 exec python3.14 会 Permission denied。
      // 改用 /system/bin/linker64 作为启动器：execve 目标是系统 linker（允许），
      // linker 再以 dlopen 方式加载 python3.14 及其动态库（execute 允许）。
      // 已在真机沙盒验证 gateway 经 linker64 可正常启动（/health 200）。
      _process = await Process.start(
        '/system/bin/linker64',
        [
          pythonBin,
          '-S',
          '-m',
          'hermes_cli.main',
          'gateway',
          'run',
        ],
        workingDirectory: srcDir,
        environment: {
          // bundle 的 python 是相对布局：可执行文件在 files/python/，
          // 标准库（lib-python/、lib-dynload/）也在 files/python/ 下。
          // PYTHONHOME 必须指向该目录，否则 Python 启动时找不到 encodings
          // 等标准库 → Fatal Python error: Failed to import encodings。
          'PYTHONHOME': '${filesDir}/python',
          'PYTHONPATH': '$pkgDir:$srcDir:${srcDir}/plugins/mix',
          'HOME': filesDir,
          'HERMES_HOME': hermesHome,
          'PATH': '${filesDir}/python:/system/bin:/usr/bin:/bin',
          'TERMINAL_CWD': filesDir,
          // python3.14 依赖 Termux 的 libandroid-support.so，已打进 bundle 的 files/python/
          'LD_LIBRARY_PATH': '${filesDir}/python',
          // api_server 无 API_SERVER_KEY 拒绝启动，必须设置
          'API_SERVER_KEY': _apiServerKey,
        },
      );

      // 监听 stderr（打印到 logcat 便于诊断）
      _process!.stderr.transform(utf8.decoder).listen((line) {
        if (line.trim().isNotEmpty) {
          debugPrint('[Hermes] $line');
        }
      });

      // 等待就绪。Hermes gateway 冷启动慢（手机端 Python 解释器 + 导入依赖
      // 需 20-30 秒），10 秒不够，放宽到 45 秒避免误判启动失败。
      await _waitForHealth(timeout: const Duration(seconds: 45));
      _running = true;
      _failed = false;

      // 进程退出时清理状态
      _process!.exitCode.then((_) {
        _running = false;
        _process = null;
      });

      _controller.add(AgentBridgeStatus('agent_ready', 'Hermes 已就绪'));
    } catch (e) {
      _running = false;
      _failed = true;
      _process?.kill();
      _process = null;
      debugPrint('[AgentBridge] start 失败: $e');
      _controller.add(AgentBridgeError('启动失败', 'Hermes Agent 启动失败: $e'));
    } finally {
      _starting = false;
      _startCompleter = null;
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// 停止子进程。
  Future<void> stop() async {
    _process?.kill();
    _process = null;
    _running = false;
  }

  /// 读取当前 AI 配置（设置页用）。
  Future<AiSettings?> readAiSettings() => AiSettings.load();

  /// 重新从 SharedPreferences 读取配置并同步给 Hermes。
  ///
  /// onboarding 预热时 gateway 可能在用户填入 AI key 之前就启动了，
  /// 完成引导后调用此方法，让 Hermes 用上最新的 provider/key。
  Future<void> applySavedSettings() async {
    final settings = await AiSettings.load();
    if (settings == null) return;
    await applyAiSettings(settings);
  }

  /// 保存 AI 配置并同步给 Hermes。
  ///
  /// 配置写入 SharedPreferences 后重新生成 Hermes 的 config.yaml/.env，
  /// 若 gateway 已在运行则重启使其生效（Hermes 启动时读一次配置）。
  Future<void> applyAiSettings(AiSettings settings) async {
    await settings.save();
    try {
      await _writeHermesAiConfig();
    } catch (e) {
      debugPrint('[AgentBridge] 同步 Hermes AI 配置失败: $e');
    }
    if (_running) {
      await stop();
      await start();
    }
  }

  /// 把 App 的 AI 配置写到 Hermes home（config.yaml + .env），
  /// 让本地 Hermes 与 App 共用同一个模型和 provider。
  Future<void> _writeHermesAiConfig() async {
    final filesDir = await _getFilesDir();
    final hermesHome = Directory('$filesDir/.hermes');
    await hermesHome.create(recursive: true);

    final settings = await AiSettings.load();
    if (settings == null || !settings.isComplete) {
      // 未配置 AI 时清掉旧配置，避免残留上次的 provider/key
      final cfg = File('${hermesHome.path}/config.yaml');
      final env = File('${hermesHome.path}/.env');
      if (await cfg.exists()) await cfg.delete();
      if (await env.exists()) await env.delete();
      return;
    }

    final provider = settings.hermesProvider;
    final yaml = StringBuffer()
      ..writeln('model:')
      ..writeln('  provider: ${provider?.providerId ?? "openai-api"}')
      ..writeln('  default: ${settings.model}')
      ..writeln('  base_url: ${settings.baseUrl}');
    await File('${hermesHome.path}/config.yaml').writeAsString(yaml.toString());

    if (provider != null) {
      await File('${hermesHome.path}/.env')
          .writeAsString('${provider.envKey}=${settings.apiKey}\n');
    }
  }

  /// 发送消息并接收事件流（SSE）。
  ///
  /// Hermes api_server 暴露的是 OpenAI 兼容协议（/v1/chat/completions），
  /// SSE 格式为标准 OpenAI chunk：`data: {"choices":[{"delta":{...}}]}`。
  /// 这里解析 delta.content（流式文本）和 delta.tool_calls（工具调用），
  /// 实现真正的流式渲染 + 多步工具调用展示（类似 Claude Code 的拆任务机制）。
  ///
  /// [messages] 是对话历史，[newMessage] 是当前输入。
  /// 返回事件流，每条事件对应一个 MessageBlock 操作。
  Stream<MessageBlock> send({
    required List<Map<String, dynamic>> messages,
    required String newMessage,
  }) async* {
    if (!_running) {
      yield TextBlock(id: generateBlockId(), content: '⚠️ Agent 未就绪，请稍后再试。', isError: true);
      return;
    }

    // 构造请求 — 用 App 配置的模型（与外部对话/出题共用同一模型）
    final settings = await AiSettings.load();
    final model =
        (settings != null && settings.model.isNotEmpty) ? settings.model : 'claude-sonnet-4-20250514';
    final body = jsonEncode({
      'model': model,
      'messages': [
        ...messages,
        {'role': 'user', 'content': newMessage},
      ],
      'stream': true,
    });

    // 当前正在累积的文本块 / 工具调用（在 try 外声明以便 catch 能访问）
    TextBlock? currentText;
    String pendingBuffer = '';
    // 工具调用累积：index → (ToolCallBlock, name, argsBuffer)
    final Map<int, _ToolCallAccum> toolAccum = {};

    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiServerKey');
      request.write(body);

      final response = await request.close();
      final stream = response.transform(utf8.decoder);

      // 逐字节缓冲解码，避免 Android 流式缓冲导致 SSE 行不完整
      String buffer = '';
      await for (final chunk in stream) {
        buffer += chunk;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();

        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data: ')) continue;
          final data = trimmed.substring(6);
          if (data == '[DONE]') continue;

          try {
            final event = jsonDecode(data) as Map<String, dynamic>;
            final choices = event['choices'] as List<dynamic>?;
            if (choices == null || choices.isEmpty) continue;
            final choice = choices[0] as Map<String, dynamic>;
            final delta = choice['delta'] as Map<String, dynamic>? ?? {};
            final finish = choice['finish_reason'] as String?;

            // ── 流式文本（delta.content）──
            final content = delta['content'] as String?;
            if (content != null && content.isNotEmpty) {
              pendingBuffer += content;
              if (pendingBuffer.length >= 12 || pendingBuffer.contains('\n')) {
                if (currentText == null) {
                  currentText = TextBlock(id: generateBlockId(), isStreaming: true);
                }
                currentText.append(pendingBuffer);
                yield currentText;
                pendingBuffer = '';
              }
            }

            // ── 工具调用（delta.tool_calls，参数跨 chunk 累积）──
            final toolCalls = delta['tool_calls'] as List<dynamic>?;
            if (toolCalls != null) {
              for (final tc in toolCalls) {
                final tcMap = tc as Map<String, dynamic>;
                final idx = (tcMap['index'] as num?)?.toInt() ?? 0;
                final func = tcMap['function'] as Map<String, dynamic>?;
                if (func == null) continue;

                var acc = toolAccum[idx];
                if (acc == null) {
                  acc = _ToolCallAccum(
                    block: ToolCallBlock(
                      id: generateBlockId(),
                      toolName: func['name'] as String? ?? 'unknown',
                      toolLabel: func['name'] as String? ?? '工具调用',
                      status: 'running',
                    ),
                  );
                  toolAccum[idx] = acc;
                  // 工具开始时先刷出当前文本缓冲
                  if (pendingBuffer.isNotEmpty && currentText != null) {
                    currentText.append(pendingBuffer);
                    yield currentText;
                    pendingBuffer = '';
                  }
                  yield acc.block;
                }
                // 工具名可能后到（首个 chunk 只有 args）
                if (func['name'] is String && (func['name'] as String).isNotEmpty) {
                  acc.name = func['name'] as String;
                  acc.block.toolName = acc.name;
                  acc.block.toolLabel = acc.name;
                }
                final argsDelta = func['arguments'] as String?;
                if (argsDelta != null && argsDelta.isNotEmpty) {
                  acc.argsBuffer += argsDelta;
                }
              }
            }

            // ── 结束（finish_reason）→ 收尾工具调用 ──
            if (finish == 'tool_calls') {
              for (final acc in toolAccum.values) {
                acc.block.markToolCall(acc.argsBuffer);
                yield acc.block;
              }
            }
          } catch (_) {}
        }
      }

      // 结束流式文本
      if (currentText != null) {
        if (pendingBuffer.isNotEmpty) currentText.append(pendingBuffer);
        currentText.finish();
        yield currentText;
      }

      yield DividerBlock();

    } catch (e) {
      if (currentText != null) {
        currentText.markError('通信中断: $e');
        yield currentText;
      } else {
        yield TextBlock(id: generateBlockId(), content: '⚠️ 通信中断: $e', isError: true);
      }
    }
  }

  // ── 资源释放 ──
  void dispose() {
    stop();
    _controller.close();
  }

  // ── 私有辅助 ──

  Future<String> _getFilesDir() async {
    // Android 下返回 /data/data/包名/files/
    // Dart 端可以用 platform 包获取，这里简化
    return '/data/data/com.mix.mix_app/files';
  }

  /// 检查本机端口是否已被监听（Hermes gateway 是否已在运行）。
  Future<bool> _isPortListening(int port) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForHealth({Duration timeout = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final client = HttpClient();
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:$_port/health'));
        final response = await request.close();
        if (response.statusCode == 200) return;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
    }
    throw TimeoutException('Hermes 启动超时');
  }

  Future<void> _extractAssets(
    Directory filesDir, {
    void Function(int percent, String status)? onProgress,
  }) async {
    // 从 APK assets 解压 mix-agent-bundle.tar.gz。
    // 用 Dart archive 包（纯 Dart）绕开 Android SELinux 对 tar 命令的限制，
    // 并剥离 bundle 内部的 files/ 前缀（打包时带了 files/ 顶层目录）。
    // 逐文件容错：单个文件失败跳过，不中断整体解压。
    try {
      await filesDir.create(recursive: true);
      final bundleData = await rootBundle.load('assets/mix-agent-bundle.tar.gz');
      final archive = await _readTarGz(bundleData);

      final total = archive.length;
      var okCount = 0;
      var failCount = 0;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        // 剥离 files/ 前缀 → 落在 filesDir 根
        var path = entry.name;
        if (path.startsWith('files/')) path = path.substring('files/'.length);
        if (path.isEmpty) continue;

        try {
          final out = File('${filesDir.path}/$path');
          await out.create(recursive: true);
          await out.writeAsBytes(entry.content as List<int>, flush: true);
          okCount++;
        } catch (e) {
          failCount++;
          debugPrint('[AgentBridge] 解压失败 ${entry.name}: $e');
        }

        // 进度回调：每解压 1/20 汇报一次（避免高频刷新卡 UI）
        if (total > 0 && okCount % (total ~/ 20).clamp(1, total) == 0) {
          final pct = (okCount * 100 / total).round().clamp(0, 100);
          onProgress?.call(pct, '正在解压学习环境... $pct%');
        }
      }
      debugPrint('[AgentBridge] 解压完成: 成功 $okCount, 失败 $failCount');
      onProgress?.call(100, '环境就绪');

      // archive 解压不保留 tar 的执行权限位 → python 二进制补 chmod +x
      final py = File('${filesDir.path}/python/python3.14');
      if (await py.exists()) {
        await Process.run('chmod', ['+x', py.path]);
      }
    } catch (e) {
      throw Exception('初始化 Hermes Agent 失败: $e');
    }
  }

  Future<List<ArchiveFile>> _readTarGz(ByteData data) async {
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final decompressed = GZipDecoder().decodeBytes(bytes);
    final tar = TarDecoder().decodeBytes(decompressed, verify: false);
    return tar.files;
  }
}

/// SSE 工具调用累积器 — 工具参数跨多个 chunk 增量到达，这里聚合。
class _ToolCallAccum {
  final ToolCallBlock block;
  String name;
  String argsBuffer = '';

  _ToolCallAccum({required this.block, this.name = ''});
}

// ── 事件类型 ──

abstract class AgentBridgeEvent {}
class AgentBridgeStatus extends AgentBridgeEvent {
  final String type;
  final String message;
  AgentBridgeStatus(this.type, this.message);
}
class AgentBridgeError extends AgentBridgeEvent {
  final String type;
  final String message;
  AgentBridgeError(this.type, this.message);
}
class AgentBridgeProgress extends AgentBridgeEvent {
  final int percent;
  final String status;
  AgentBridgeProgress(this.percent, this.status);
}

// ── Mock 实现（开发/测试用） ──

class MockAgentBridge extends AgentBridge {
  bool get isRunning => true;

  @override
  Future<void> ensureInitialized({
    void Function(int percent, String status)? onProgress,
  }) async {
    _initialized = true;
    onProgress?.call(100, '环境就绪');
  }

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Stream<MessageBlock> send({
    required List<Map<String, dynamic>> messages,
    required String newMessage,
  }) async* {
    // 模拟流式回复，用于开发和测试渲染管线
    final reply = _mockReply(newMessage);
    final text = TextBlock(id: generateBlockId(), isStreaming: true);

    for (var i = 0; i < reply.length; i += 3) {
      text.append(reply.substring(i, (i + 3).clamp(0, reply.length)));
      yield text;
      await Future.delayed(const Duration(milliseconds: 30));
    }
    text.finish();
    yield text;

    yield StatusBlock(id: generateBlockId(), text: '回答完成', autoDismiss: true);
    yield DividerBlock();
  }

  String _mockReply(String msg) {
    if (msg.contains('科目') || msg.contains('药理学')) {
      return '''## 药理学掌握度分析

根据你的学习数据，以下是药理学各知识点的掌握情况：

| 知识点 | 掌握度 | 建议 |
|--------|--------|------|
| **药物代谢动力学** | 35% | ⚠️ 需要重点复习 |
| 药效动力学 | 72% | ✅ 良好 |
| 胆碱能药物 | 68% | 🔄 适当巩固 |

**重点建议：** 药物代谢动力学是你的薄弱环节（仅 35%），建议今天花 15 分钟复习 \$F = C \\cdot V_d\$ 等核心公式。

> 需要我为你生成几道练习题吗？''';
    }
    if (msg.contains('统计') || msg.contains('学习')) {
      return '## 学习统计\n\n总练习次数：47 次\n正确率：72%\n连续学习：5 天\n\n### 各科掌握度\n- 药理学：58%\n- 高等数学：82%\n- 线性代数：45%';
    }
    return '你好！我是 MIX 学习助手。我可以帮你查学习数据、管理科目、生成练习题。有什么需要帮忙的吗？';
  }
}
