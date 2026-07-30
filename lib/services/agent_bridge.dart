import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import '../db/database_helper.dart';
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
    await _extractAssets(filesDir);
    await marker.writeAsString('ok');
    _initialized = true;
  }

  /// 启动 Hermes 子进程。
  Future<void> start() async {
    if (_running) return;

    await ensureInitialized();

    final filesDir = await _getFilesDir();
    _port = await _findFreePort();

    try {
      final pythonBin = '${filesDir}/python/python3.14';
      final pkgDir = '${filesDir}/python-packages';
      final srcDir = '${filesDir}/hermes';

      _process = await Process.start(
        pythonBin,
        ['-m', 'hermes', 'serve', '--port', '$_port', '--config', '${filesDir}/config.yaml'],
        workingDirectory: srcDir,
        environment: {
          'PYTHONPATH': '$pkgDir:$srcDir:${srcDir}/plugins/mix',
          'HOME': filesDir,
          'PATH': '${filesDir}/python:/usr/bin:/bin',
        },
      );

      // 监听 stderr（日志用，不处理）
      _process!.stderr.transform(utf8.decoder).listen((_) {});

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

    try {
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'));
      request.headers.contentType = ContentType.json;
      request.write(body);

      final response = await request.close();
      final stream = response.transform(utf8.decoder);

      // 当前正在累积的文本块
      TextBlock? currentText;
      ToolCallBlock? currentTool;
      String pendingBuffer = '';

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
                    currentTool.markSuccess(result?.length > 150 ? '${result!.substring(0, 150)}...' : result);
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

      yield const DividerBlock();

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

  Future<int> _findFreePort() async {
    // 找随机空闲端口
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final port = server.port;
    await server.close();
    return port;
  }

  Future<void> _waitForHealth({Duration timeout = const Duration(seconds: 10)}) async {
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
    // 从 APK assets 解压 mix-agent-bundle.tar.gz
    try {
      await filesDir.create(recursive: true);
      final bundleData = await rootBundle.load('assets/mix-agent-bundle.tar.gz');
      final tempFile = File('${filesDir.path}/bundle.tar.gz');
      await tempFile.writeAsBytes(bundleData.buffer.asUint8List());
      await _runProcess('tar', ['xzf', tempFile.path, '-C', filesDir.path]);
      await tempFile.delete();
    } catch (e) {
      throw Exception('初始化 Hermes Agent 失败: $e');
    }
  }

  Future<void> _runProcess(String cmd, List<String> args) async {
    final result = await Process.run(cmd, args);
    if (result.exitCode != 0) {
      throw Exception('$cmd 失败: ${result.stderr}');
    }
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
    yield const DividerBlock();
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
