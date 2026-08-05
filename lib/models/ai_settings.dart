import 'package:shared_preferences/shared_preferences.dart';

import '../data/preset_data.dart';

/// 单个 App vendor → Hermes 推理 provider 的映射信息。
class HermesProvider {
  /// Hermes config.yaml `model.provider` 的 provider id（见 hermes_cli/auth.py PROVIDER_REGISTRY）
  final String providerId;

  /// 该 provider 的 API key 环境变量名（写入 Hermes ~/.hermes/.env）
  final String envKey;

  const HermesProvider({required this.providerId, required this.envKey});
}

/// App vendor id → Hermes provider 映射。
/// 与 kAiVendors 的 id 一一对应；custom 走自定义 endpoint + OPENAI_API_KEY。
const Map<String, HermesProvider> kHermesProviderMap = {
  'deepseek': HermesProvider(providerId: 'deepseek', envKey: 'DEEPSEEK_API_KEY'),
  'qwen': HermesProvider(providerId: 'alibaba', envKey: 'DASHSCOPE_API_KEY'),
  'openai': HermesProvider(providerId: 'openai-api', envKey: 'OPENAI_API_KEY'),
  'moonshot': HermesProvider(providerId: 'kimi-coding-cn', envKey: 'KIMI_CN_API_KEY'),
  'zhipu': HermesProvider(providerId: 'zai', envKey: 'GLM_API_KEY'),
  'gemini': HermesProvider(providerId: 'gemini', envKey: 'GOOGLE_API_KEY'),
  'custom': HermesProvider(providerId: 'openai-api', envKey: 'OPENAI_API_KEY'),
};

/// AI 配置：App 与本地 Hermes Agent 共用同一份（vendor + 模型 + key + baseUrl）。
class AiSettings {
  final String vendorId;
  final String model;
  final String apiKey;
  final String baseUrl;

  const AiSettings({
    required this.vendorId,
    required this.model,
    required this.apiKey,
    required this.baseUrl,
  });

  /// 是否是一份可用的完整配置。
  bool get isComplete =>
      vendorId.isNotEmpty && model.isNotEmpty && apiKey.isNotEmpty && baseUrl.isNotEmpty;

  /// OpenAI 兼容的完整 chat.completions 端点。
  /// 预设厂商 baseUrl 是根地址（如 https://api.deepseek.com/v1），
  /// Hermes LLM 客户端要求完整端点，缺 /chat/completions 时补上。
  String get chatBaseUrl => baseUrl.endsWith('/chat/completions')
      ? baseUrl
      : '$baseUrl/chat/completions';

  /// 对应的 Hermes provider 信息；未知 vendor 返回 null。
  HermesProvider? get hermesProvider => kHermesProviderMap[vendorId];

  /// 从 SharedPreferences 读取（与 onboarding 共用 ai_vendor/ai_model/api_key key）。
  /// 自定义厂商（vendorId == 'custom'）读 ai_base_url 作为 endpoint。
  static Future<AiSettings?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final vendorId = prefs.getString('ai_vendor') ?? '';
    final model = prefs.getString('ai_model') ?? '';
    final apiKey = prefs.getString('api_key') ?? '';
    final preset = kAiVendors.where((v) => v.id == vendorId).firstOrNull;
    final baseUrl = preset?.baseUrl ?? prefs.getString('ai_base_url') ?? '';
    final settings = AiSettings(
      vendorId: vendorId,
      model: model,
      apiKey: apiKey,
      baseUrl: baseUrl,
    );
    return settings.isComplete ? settings : null;
  }

  /// 写入 SharedPreferences。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_vendor', vendorId);
    await prefs.setString('ai_model', model);
    await prefs.setString('api_key', apiKey);
    if (vendorId == 'custom' && baseUrl.isNotEmpty) {
      await prefs.setString('ai_base_url', baseUrl);
    }
  }
}
