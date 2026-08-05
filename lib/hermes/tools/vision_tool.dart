/// vision_analyze 工具：分析本地图片（或 URL），用多模态 LLM。
///
/// 视觉模型单独配置（vision_api_key/base_url/model，存 SharedPreferences），
/// 与主对话模型分离。OpenAI 兼容 vision 请求：image_url data URI base64。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'registry.dart';

/// 读取视觉模型配置。
Future<Map<String, String>> _loadVisionConfig() async {
  final prefs = await SharedPreferences.getInstance();
  return {
    'api_key': prefs.getString('vision_api_key') ?? '',
    'base_url': prefs.getString('vision_base_url') ?? '',
    'model': prefs.getString('vision_model') ?? '',
  };
}

/// 保存视觉模型配置（UI 设置页调用）。
Future<void> saveVisionConfig({
  required String apiKey,
  String baseUrl = '',
  String model = '',
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('vision_api_key', apiKey);
  await prefs.setString('vision_base_url', baseUrl);
  await prefs.setString('vision_model', model);
}

bool _isImageFile(String path) {
  final ext = path.toLowerCase().split('.').last;
  return const {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
  }.contains(ext);
}

String _mimeFor(String path) {
  final ext = path.toLowerCase().split('.').last;
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    _ => 'image/png',
  };
}

/// 图片 → data URI（base64）。
Future<String> _imageToDataUri(String path) async {
  final file = File(path);
  final bytes = await file.readAsBytes();
  return 'data:${_mimeFor(path)};base64,${base64Encode(bytes)}';
}

/// vision_analyze 主逻辑。
Future<String> _handleVision(Map<String, dynamic> args, [Map<String, dynamic>? kwargs]) async {
  final config = await _loadVisionConfig();
  final apiKey = config['api_key'] ?? '';
  if (apiKey.isEmpty) {
    return toolError('vision_analyze: 未配置视觉模型。请在设置中配置视觉 API key。');
  }
  final path = args['path'] as String? ?? '';
  final prompt = args['prompt'] as String? ?? 'Describe this image in detail.';
  if (path.isEmpty) {
    return toolError('vision_analyze: missing path');
  }
  if (!File(path).existsSync()) {
    return toolError("vision_analyze: file not found '$path'");
  }
  if (!_isImageFile(path)) {
    return toolError("vision_analyze: '$path' is not a supported image (png/jpg/gif/webp/bmp)");
  }

  String dataUri;
  try {
    dataUri = await _imageToDataUri(path);
  } catch (e) {
    return toolError('vision_analyze: failed to read image: $e');
  }

  final baseUrl = config['base_url'] ?? '';
  final model = config['model'] ?? '';
  final chatUrl = baseUrl.isEmpty
      ? 'https://api.openai.com/v1/chat/completions'
      : (baseUrl.endsWith('/chat/completions')
          ? baseUrl
          : '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions');

  final body = jsonEncode({
    'model': model,
    'messages': [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': prompt},
          {'type': 'image_url', 'image_url': {'url': dataUri}},
        ],
      },
    ],
  });

  try {
    final resp = await http
        .post(
          Uri.parse(chatUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      return toolError('vision_analyze: HTTP ${resp.statusCode} '
          '${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = data['choices'] as List? ?? [];
    if (choices.isEmpty) {
      return 'vision_analyze: no response';
    }
    final content = (choices.first as Map<String, dynamic>)['message']
        ?['content'] as String? ?? '';
    return content;
  } catch (e) {
    return toolError('vision_analyze: $e');
  }
}

const Map<String, dynamic> _visionSchema = {
  'name': 'vision_analyze',
  'description':
      'Analyze a local image file (or note: images only) using a multimodal '
      'vision model. Returns a text description or answers about the image. '
      'Provide the file path and an optional prompt.',
  'parameters': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Path to the image file'},
      'prompt': {'type': 'string', 'description': 'What to ask about the image'},
    },
    'required': ['path'],
  },
};

/// 注册 vision_analyze 工具。
void registerVisionTool() {
  registry.register(
    name: 'vision_analyze',
    toolset: 'vision',
    schema: _visionSchema,
    handler: _handleVision,
    isAsync: true,
    emoji: '👁️',
  );
}
