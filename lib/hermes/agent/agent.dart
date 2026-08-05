/// 对应 `ref/hermes-agent/agent/conversation_loop.py` 的 run_conversation 核心
/// （像素级复刻，最小闭环子集）。
///
/// 完整 run_conversation 是 4500+ 行（压缩门控、截断重试、中断、记忆 review、
/// MoA、fallback 链等）。本文件复刻**主循环骨架**（这是最小闭环的核心数据流）：
///
/// 1. **Prologue**：组装 messages（system + conversation_history + user）
/// 2. **主循环**（while api_call_count < max_iterations 且 budget 有余量）：
///    - 组包：api_messages + getToolDefinitions()（OpenAI 格式工具 schema）
///    - LLM 调用：chatStream（含 tool_calls 聚合）
///    - 响应含 tool_calls → 逐工具经 model_tools.handleFunctionCall 执行，
///      结果回填为 role=tool 消息 → 继续循环
///    - 响应无 tool_calls → 确定 final_response → 结束
/// 3. **收尾**：返回 {final_response, messages, api_calls, completed}
///
/// 外围（压缩/截断重试/中断/持久化）留接口，App 首版不实现。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../db/session_db.dart';
import '../llm/openai_llm.dart';
import '../tools/memory_manager.dart';
import '../tools/model_tools.dart';
import 'context_compressor.dart';
import 'error_classifier.dart';
import 'iteration_budget.dart';
import 'retry_utils.dart';

/// agent 主循环的结果。
class ConversationResult {
  final String? finalResponse;
  final List<Map<String, dynamic>> messages;
  final int apiCalls;
  final bool completed;
  final String? error;

  const ConversationResult({
    this.finalResponse,
    required this.messages,
    required this.apiCalls,
    required this.completed,
    this.error,
  });
}

/// Agent 主循环。
class JailerAgent {
  /// LLM 客户端。
  final OpenAiLlmClient llm;

  /// 系统提示词（三层 system_prompt 的简化：stable 身份提示）。
  final String systemPrompt;

  /// 工具 schema 提供者（默认取 Hermes getToolDefinitions）。
  final List<Map<String, dynamic>> Function()? toolDefinitionsProvider;

  /// 最大迭代次数（Hermes 默认 500）。
  final int maxIterations;

  /// 迭代预算。
  final IterationBudget iterationBudget;

  /// 取消标志：UI 调 [cancel] 后，循环在下一个检查点停止并返回已流式内容。
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// 请求取消当前对话。
  void cancel() => _cancelled = true;

  /// 流式文本回调（UI 打字）。
  final void Function(String delta)? onDelta;

  /// 工具调用事件回调（UI 显示工具执行）。
  final void Function(String name, String status)? onToolEvent;

  /// 记忆管理器（可选）。提供时，记忆块注入 system prompt。
  final MemoryManager? memoryManager;

  /// 上下文压缩器（可选）。提供时，超阈值自动压缩。
  final ContextCompressor? contextCompressor;

  /// 会话库（可选）。提供时，消息落库 + 跨重启恢复。
  final SessionDB? sessionDb;

  /// 会话 id（可选，落库时用）。
  final String? sessionId;

  JailerAgent({
    required this.llm,
    required this.systemPrompt,
    this.toolDefinitionsProvider,
    this.maxIterations = 500,
    this.onDelta,
    this.onToolEvent,
    this.memoryManager,
    this.contextCompressor,
    this.sessionDb,
    this.sessionId,
  }) : iterationBudget = IterationBudget(maxIterations);

  /// 把分类后的 API 错误转成用户可读的中文提示。
  String _friendlyApiError(ClassifiedError classified, String raw) {
    switch (classified.reason) {
      case FailoverReason.auth:
        return '认证失败（API key 无效或过期），请检查设置里的 API key。';
      case FailoverReason.billing:
        return '额度不足或计费问题，请检查账户余额。';
      case FailoverReason.rateLimit:
        return '请求过于频繁被限流，已重试仍失败，请稍后再试。';
      case FailoverReason.overloaded:
        return '模型服务繁忙，请稍后再试。';
      case FailoverReason.payloadTooLarge:
        return '请求过大（上下文太长），请精简内容。';
      case FailoverReason.serverError:
        return '模型服务出错（5xx），已重试仍失败。';
      case FailoverReason.clientError:
        return '请求参数被拒绝（可能是消息格式问题）。';
      case FailoverReason.network:
        return '网络错误，请检查连接。';
      default:
        return raw;
    }
  }

  /// 运行一次完整对话（带工具调用直到完成）。
  ///
  /// [conversationHistory] 之前对话消息（可选）。
  Future<ConversationResult> runConversation(
    String userMessage, {
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    // ── Prologue：组装 messages ──
    // 有记忆管理器时，把冻结快照拼进 system prompt（Hermes 记忆注入）。
    memoryManager?.onTurnStart();
    var effectiveSystem = systemPrompt;
    final memoryBlock = memoryManager?.prefetchAll(userMessage) ?? '';
    if (memoryBlock.isNotEmpty) {
      effectiveSystem = '$effectiveSystem\n\n$memoryBlock';
    }
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': effectiveSystem},
      ...?conversationHistory,
      {'role': 'user', 'content': userMessage},
    ];

    debugPrint('[Agent] runConversation 开始');
    // ── 会话落库：恢复历史 + 追加当前 user 消息 ──
    final sdb = sessionDb;
    final sid = sessionId;
    if (sdb != null && sid != null) {
      // 从库恢复历史（若该 session 已有消息）。
      // DB 行含内部列（id/session_id/timestamp/active 等），必须转成
      // OpenAI 消息格式再发给 LLM，否则严格后端会 400。
      final stored = await sdb.getMessages(sid);
      if (stored.isNotEmpty) {
        final restored = <Map<String, dynamic>>[];
        for (final m in stored) {
          final role = m['role'] as String? ?? 'user';
          final rawContent = m['content'] as String? ?? '';
          final msg = <String, dynamic>{
            'role': role,
            // assistant 消息 content 兜底空串（防 "content or tool_calls must
            // be sent"；tool 消息需空 content 用于占位）。
            'content': role == 'tool' && rawContent.isEmpty
                ? ' '
                : rawContent,
          };
          if (role == 'tool') {
            msg['tool_call_id'] = m['tool_call_id'] ?? '';
            msg['name'] = m['tool_name'] ?? '';
          } else if (role == 'assistant' && m['tool_calls'] is List) {
            msg['tool_calls'] = m['tool_calls'];
          }
          restored.add(msg);
        }
        messages.insertAll(1, restored);
      }
      await sdb.appendMessage(sid, role: 'user', content: userMessage);
    }

    var apiCallCount = 0;
    String? finalResponse;
    var failed = false;

    while (apiCallCount < maxIterations &&
        iterationBudget.remaining > 0 &&
        !_cancelled) {
      apiCallCount++;

      // 消耗迭代预算。
      if (!iterationBudget.consume()) {
        break;
      }

      // ── 上下文压缩：超阈值时用 LLM 摘要中间段 ──
      final cc = contextCompressor;
      if (cc != null) {
        final currentTokens = estimateMessagesTokens(messages);
        if (cc.shouldCompress(currentTokens)) {
          final compressed = await cc.compress(messages);
          if (compressed.length != messages.length) {
            // 替换为压缩后消息（保留历史语义）。
            messages
              ..clear()
              ..addAll(compressed);
          }
        }
      }

      // ── 组包：api_messages + tools ──
      final tools = toolDefinitionsProvider != null
          ? toolDefinitionsProvider!()
          : getToolDefinitions(quietMode: true);

      // ── LLM 调用（带错误分类 + 重试） ──
      LlmTurnResult turn;
      const maxRetries = 3;
      var attempt = 0;
      var lastError = '';
      while (true) {
        try {
          final result = await llm.chatStream(
            messages: messages,
            tools: tools,
            onDelta: onDelta,
            isCancelled: () => _cancelled,
          );
          turn = result;
          break;
        } catch (e) {
          // 取消时不重试，直接返回已流式内容。
          if (_cancelled) {
            return ConversationResult(
              finalResponse: null,
              messages: messages,
              apiCalls: apiCallCount,
              completed: false,
              error: 'cancelled',
            );
          }
          // 分类错误，决定是否重试。
          final classified = classifyApiError(e);
          lastError = e.toString();
          debugPrint('[Agent] API 调用失败 (attempt $attempt): $lastError');
          if (!classified.retryable || attempt >= maxRetries) {
            failed = true;
            final friendly = _friendlyApiError(classified, lastError);
            return ConversationResult(
              finalResponse: 'API 调用失败：$friendly\n（原始错误：$lastError）',
              messages: messages,
              apiCalls: apiCallCount,
              completed: false,
              error: lastError,
            );
          }
          // 退避后重试。
          attempt++;
          final delay = jitteredBackoff(
            attempt,
            baseDelay: 2.0,
            maxDelay: 15.0,
          );
          await Future<void>.delayed(
            Duration(milliseconds: (delay * 1000).toInt()),
          );
        }
      }

      // 把 assistant turn 追加进消息历史。
      messages.add(turn.toAssistantMessage());

      // 落库 assistant 消息。
      if (sdb != null && sid != null) {
        final toolCallsJson = turn.toolCalls.isNotEmpty
            ? jsonEncode([for (final tc in turn.toolCalls) tc.toJson()])
            : null;
        await sdb.appendMessage(
          sid,
          role: 'assistant',
          content: turn.content,
          toolCalls: toolCallsJson,
        );
      }

      // ── 有 tool_calls → 执行并回填 ──
      if (turn.hasToolCalls) {
        if (_cancelled) {
          break;
        }
        for (var ti = 0; ti < turn.toolCalls.length; ti++) {
          final tc = turn.toolCalls[ti];
          Map<String, dynamic> args;
          try {
            final decoded = tc.arguments.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(tc.arguments);
            args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
          } catch (_) {
            args = <String, dynamic>{};
          }

          onToolEvent?.call(tc.name, 'running');
          final result = await handleFunctionCall(tc.name, args);
          onToolEvent?.call(tc.name, 'done');

          // 工具 id 缺失时合成（部分后端不返回 id）。
          final effectiveId =
              tc.id.isEmpty ? 'call_${apiCallCount}_$ti' : tc.id;

          messages.add({
            'role': 'tool',
            'tool_call_id': effectiveId,
            'name': tc.name, // OpenAI 兼容端要求 tool 消息带 name。
            'content': result,
          });
          // 落库 tool 消息。
          if (sdb != null && sid != null) {
            await sdb.appendMessage(
              sid,
              role: 'tool',
              content: result,
              toolCallId: effectiveId,
              toolName: tc.name,
            );
          }
        }
        continue; // 有工具调用 → 继续循环（模型看到工具结果再决定）
      }

      // ── 无 tool_calls → final_response ──
      finalResponse = turn.content ?? '';
      break;
    }

    // 预算耗尽但未完成。
    if (finalResponse == null && !failed) {
      if (_cancelled) {
        return ConversationResult(
          finalResponse: '（已停止生成）',
          messages: messages,
          apiCalls: apiCallCount,
          completed: false,
        );
      }
      return ConversationResult(
        finalResponse: 'Iteration budget exhausted (${iterationBudget.used}/'
            '${iterationBudget.maxTotal} iterations used)',
        messages: messages,
        apiCalls: apiCallCount,
        completed: false,
      );
    }

    return ConversationResult(
      finalResponse: finalResponse,
      messages: messages,
      apiCalls: apiCallCount,
      completed: finalResponse != null,
    );
  }
}
