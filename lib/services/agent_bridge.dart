import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
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

  /// Hermes api_server 的 Bearer 认证 key（API_SERVER_KEY）。
  /// 无 key 时 api_server 拒绝启动；MIX 用固定内部 key 与本地 Hermes 通信。
  static const String _apiServerKey = 'mix-local-agent';

  // ── 初始化状态 ──
  bool get isRunning => _running;
  bool get isInitialized => _initialized;
  int get port => _port;

  /// 确保环境已解压（首次启动时调用）
  Future<void> ensureInitialized() async {
    if (_initialized) return;

    final filesDir = Directory(await _getFilesDir());
    final marker = File('${filesDir.path}/.initialized');

    // 检查是否已解压
    if (await marker.exists()) {
      _initialized = true;
      return;
    }

    // 解压 bundle（首次启动）
    try {
      await _extractAssets(filesDir);
      await marker.writeAsString('ok');
      _initialized = true;
    } catch (e) {
      debugPrint('[AgentBridge] ensureInitialized 失败: $e');
      rethrow;
    }
  }

  /// 启动 Hermes 子进程。
  Future<void> start() async {
    if (_running) return;

    try {
      await ensureInitialized();
    } catch (e) {
      debugPrint('[AgentBridge] ensureInitialized 失败: $e');
      _controller.add(AgentBridgeError('初始化失败', 'Hermes 环境解压失败: $e'));
      return;
    }

    final filesDir = await _getFilesDir();
    // Hermes gateway api_server 固定端口 8642（见 api_server.py DEFAULT_PORT）
    _port = 8642;

    try {
      final pythonBin = '${filesDir}/python/python3.14';
      final pkgDir = '${filesDir}/python-packages';
      final srcDir = '${filesDir}/hermes-source';

      // Hermes 0.15.2 通过 gateway 暴露 OpenAI 兼容 API（/v1/chat/completions）。
      // 端口由 api_server 的 DEFAULT_PORT=8642 决定，agent_bridge 从 /health 读取。
      _process = await Process.start(
        pythonBin,
        ['-m', 'hermes_cli.main', 'gateway', 'run'],
        workingDirectory: srcDir,
        environment: {
          'PYTHONPATH': '$pkgDir:$srcDir:${srcDir}/plugins/mix',
          'HOME': filesDir,
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

      // 等待就绪
      await _waitForHealth(timeout: const Duration(seconds: 10));
      _running = true;

      // 进程退出时清理状态
      _process!.exitCode.then((_) {
        _running = false;
        _process = null;
      });

      _controller.add(AgentBridgeStatus('agent_ready', 'Hermes 已就绪'));
    } catch (e) {
      _running = false;
      _process?.kill();
      _process = null;
      debugPrint('[AgentBridge] start 失败: $e');
      _controller.add(AgentBridgeError('启动失败', 'Hermes Agent 启动失败: $e'));
    }
  }

  /// 停止子进程。
  Future<void> stop() async {
    _process?.kill();
    _process = null;
    _running = false;
  }

  /// 发送消息并接收事件流（SSE）。
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

    // 构造请求
    final body = jsonEncode({
      'model': 'claude-sonnet-4-20250514',
      'messages': [
        ...messages,
        {'role': 'user', 'content': newMessage},
      ],
      'stream': true,
    });

    // 当前正在累积的文本块（在 try 外声明以便 catch 能访问）
    TextBlock? currentText;
    ToolCallBlock? currentTool;
    String pendingBuffer = '';

    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'));
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiServerKey');
      request.write(body);

      final response = await request.close();
      final stream = response.transform(utf8.decoder);


      await for (final chunk in stream) {
        // 解析 SSE 行
        for (final line in chunk.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6);
          if (data == '[DONE]') break;

          try {
            final event = jsonDecode(data) as Map<String, dynamic>;
            final type = event['type'] as String?;

            switch (type) {
              case 'text_delta':
                final content = event['content'] as String? ?? '';
                pendingBuffer += content;
                // 每 100ms 左右 yield 一次，让 UI 有时间刷新
                if (pendingBuffer.length > 20 || pendingBuffer.contains('\n')) {
                  if (currentText == null) {
                    currentText = TextBlock(id: generateBlockId(), isStreaming: true);
                  }
                  currentText.append(pendingBuffer);
                  yield currentText;
                  pendingBuffer = '';
                }
                break;

              case 'tool_start':
                // 刷出剩余缓冲区
                if (pendingBuffer.isNotEmpty && currentText != null) {
                  currentText.append(pendingBuffer);
                  yield currentText;
                  pendingBuffer = '';
                }
                currentTool = ToolCallBlock(
                  id: generateBlockId(),
                  toolName: event['name'] as String? ?? 'unknown',
                  toolLabel: event['label'] as String? ?? event['name'] as String? ?? '工具调用',
                  status: 'running',
                );
                yield currentTool;
                break;

              case 'tool_end':
                if (currentTool != null) {
                  final result = event['result'] as String?;
                  if (event['error'] == true) {
                    currentTool.markError(result ?? '执行失败');
                  } else {
                    currentTool.markSuccess((result?.length ?? 0) > 150 ? '${result!.substring(0, 150)}...' : result);
                  }
                  yield currentTool;
                  currentTool = null;
                }
                break;

              case 'status':
                yield StatusBlock(
                  id: generateBlockId(),
                  text: event['text'] as String? ?? '',
                  isWarning: event['warning'] == true,
                );
                break;

              case 'error':
                if (currentText != null) {
                  currentText.markError(event['message'] as String? ?? '未知错误');
                  yield currentText;
                } else {
                  yield TextBlock(id: generateBlockId(), content: '⚠️ ${event['message']}', isError: true);
                }
                break;
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

  Future<void> _extractAssets(Directory filesDir) async {
    // 从 APK assets 解压 mix-agent-bundle.tar.gz。
    // 用 Dart archive 包（纯 Dart）绕开 Android SELinux 对 tar 命令的限制，
    // 并剥离 bundle 内部的 files/ 前缀（打包时带了 files/ 顶层目录）。
    // 逐文件容错：单个文件失败跳过，不中断整体解压。
    try {
      await filesDir.create(recursive: true);
      final bundleData = await rootBundle.load('assets/mix-agent-bundle.tar.gz');
      final archive = await _readTarGz(bundleData);

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
      }
      debugPrint('[AgentBridge] 解压完成: 成功 $okCount, 失败 $failCount');

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

// ── Mock 实现（开发/测试用） ──

class MockAgentBridge extends AgentBridge {
  bool get isRunning => true;

  @override
  Future<void> ensureInitialized() async {
    _initialized = true;
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
