/// 对应 `ref/hermes-agent/hermes_cli/providers.py`（像素级复刻，核心解析逻辑）。
///
/// Provider 定义与解析：把 provider 名/别名解析成 `ProviderDef`
/// （transport / api_key_env_vars / base_url）。
///
/// ## Dart 适配
/// - `api_key_env_vars`（env var 检查）→ [keyResolver] 钩子（App 从 SharedPreferences
///   读 key，见 jailer_config.dart）。保留 env var 语义作为默认实现。
/// - `models.dev` 远程目录 → 内置精简预设表 [builtinProviderDefs]（覆盖 App 实际
///   用的 provider）。解析链结构逐函数保留。
/// - `get_provider` 的 allow_network（远程 models.dev 拉取）→ App 无网络目录，简化。
library;

/// Provider 传输协议（决定 api_mode）。
enum Transport {
  openaiChat('openai_chat'),
  anthropicMessages('anthropic_messages'),
  codexResponses('codex_responses'),
  bedrockConverse('bedrock_converse');

  const Transport(this.value);
  final String value;

  static Transport? fromValue(String v) {
    for (final t in Transport.values) {
      if (t.value == v) {
        return t;
      }
    }
    return null;
  }
}

/// API 模式（wire 协议），对应 Hermes TRANSPORT_TO_API_MODE。
String transportToApiMode(Transport? transport) {
  switch (transport) {
    case Transport.openaiChat:
      return 'chat_completions';
    case Transport.anthropicMessages:
      return 'anthropic_messages';
    case Transport.codexResponses:
      return 'codex_responses';
    case Transport.bedrockConverse:
      return 'bedrock_converse';
    case null:
      return 'chat_completions';
  }
}

/// 完整的 provider 定义 —— 从所有来源合并。
class ProviderDef {
  final String id;
  final String name;
  final Transport transport; // openai_chat | anthropic_messages | codex_responses
  final List<String> apiKeyEnvVars; // 要检查 API key 的所有 env var
  final String baseUrl;
  final String baseUrlEnvVar;
  final bool isAggregator;
  final String authType;
  final String doc;
  final String source; // "models.dev" | "hermes" | "user-config"

  const ProviderDef({
    required this.id,
    required this.name,
    required this.transport,
    this.apiKeyEnvVars = const [],
    this.baseUrl = '',
    this.baseUrlEnvVar = '',
    this.isAggregator = false,
    this.authType = 'api_key',
    this.doc = '',
    this.source = 'hermes',
  });
}

// -- Aliases ---------------------------------------------------------------
// 人类友好/遗留名 → 规范 provider ID。用 models.dev ID 优先。

const Map<String, String> aliases = {
  // 注意：Hermes 原版把裸 'openai' 路由到 openrouter 聚合器（省钱）。
  // Jailer 是单机 App，设置页把 OpenAI 当独立厂商 —— 用户选 OpenAI 应连
  // api.openai.com。要 openrouter 直接选 openrouter 厂商。

  // zai
  'glm': 'zai',
  'z-ai': 'zai',
  'z.ai': 'zai',
  'zhipu': 'zai',

  // xai
  'x-ai': 'xai',
  'x.ai': 'xai',
  'grok': 'xai',
  'grok-oauth': 'xai-oauth',
  'xai-oauth': 'xai-oauth',
  'x-ai-oauth': 'xai-oauth',
  'xai-grok-oauth': 'xai-oauth',

  // nvidia
  'nim': 'nvidia',
  'nvidia-nim': 'nvidia',
  'build-nvidia': 'nvidia',
  'nemotron': 'nvidia',

  // kimi-for-coding (models.dev ID)
  'kimi': 'kimi-for-coding',
  'kimi-coding': 'kimi-for-coding',
  'kimi-coding-cn': 'kimi-for-coding',
  'moonshot': 'kimi-for-coding',

  // stepfun
  'step': 'stepfun',
  'stepfun-coding-plan': 'stepfun',

  // minimax-cn
  'minimax-china': 'minimax-cn',
  'minimax_cn': 'minimax-cn',

  // anthropic
  'claude': 'anthropic',
  'claude-code': 'anthropic',

  // github-copilot (models.dev ID)
  'copilot': 'github-copilot',
  'github': 'github-copilot',
  'github-copilot-acp': 'copilot-acp',

  // vercel (models.dev ID for AI Gateway)
  'ai-gateway': 'vercel',
  'aigateway': 'vercel',
  'vercel-ai-gateway': 'vercel',

  // opencode (models.dev ID for OpenCode Zen)
  'opencode-zen': 'opencode',
  'zen': 'opencode',

  // opencode-go
  'go': 'opencode-go',
  'opencode-go-sub': 'opencode-go',

  // kilo (models.dev ID for KiloCode)
  'kilocode': 'kilo',
  'kilo-code': 'kilo',
  'kilo-gateway': 'kilo',

  // deepseek
  'deep-seek': 'deepseek',

  // alibaba（dashscope/aliyun/qwen/alibaba-cloud → alibaba）
  'dashscope': 'alibaba',
  'aliyun': 'alibaba',
  'qwen': 'alibaba',
  'alibaba-cloud': 'alibaba',
};

/// 解析别名并归一化大小写到规范 provider id。
///
/// 返回规范 id 字符串。不验证 id 对应已知 provider。
String normalizeProvider(String name) {
  final key = name.trim().toLowerCase();
  return aliases[key] ?? key;
}

/// 内置精简 provider 预设表（对应 Hermes 的 models.dev + HERMES_OVERLAYS，
/// 覆盖 App 实际用的 provider）。
///
/// env var 名与 Hermes models.dev 一致（DEEPSEEK_API_KEY / DASHSCOPE_API_KEY /
/// OPENAI_API_KEY / KIMI_CN_API_KEY / GLM_API_KEY / GOOGLE_API_KEY）。
const Map<String, ProviderDef> builtinProviderDefs = {
  'deepseek': ProviderDef(
    id: 'deepseek',
    name: 'DeepSeek',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['DEEPSEEK_API_KEY'],
    baseUrl: 'https://api.deepseek.com/v1/chat/completions',
    source: 'models.dev',
  ),
  'alibaba': ProviderDef(
    id: 'alibaba',
    name: 'Alibaba (DashScope)',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['DASHSCOPE_API_KEY'],
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    source: 'models.dev',
  ),
  'openai': ProviderDef(
    id: 'openai',
    name: 'OpenAI',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['OPENAI_API_KEY'],
    baseUrl: 'https://api.openai.com/v1/chat/completions',
    source: 'models.dev',
  ),
  'kimi-for-coding': ProviderDef(
    id: 'kimi-for-coding',
    name: 'Kimi (Moonshot)',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['KIMI_CN_API_KEY'],
    baseUrl: 'https://api.moonshot.cn/v1/chat/completions',
    source: 'models.dev',
  ),
  'zai': ProviderDef(
    id: 'zai',
    name: 'Zhipu (Z.ai)',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['GLM_API_KEY'],
    baseUrl: 'https://api.z.ai/api/paas/v4/chat/completions',
    source: 'models.dev',
  ),
  'google': ProviderDef(
    id: 'google',
    name: 'Google Gemini',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['GOOGLE_API_KEY'],
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
    source: 'models.dev',
  ),
  'openrouter': ProviderDef(
    id: 'openrouter',
    name: 'OpenRouter (aggregator)',
    transport: Transport.openaiChat,
    apiKeyEnvVars: ['OPENROUTER_API_KEY'],
    baseUrl: 'https://openrouter.ai/api/v1/chat/completions',
    isAggregator: true,
    source: 'models.dev',
  ),
  'anthropic': ProviderDef(
    id: 'anthropic',
    name: 'Anthropic Claude',
    transport: Transport.anthropicMessages,
    apiKeyEnvVars: ['ANTHROPIC_API_KEY'],
    baseUrl: 'https://api.anthropic.com/v1/messages',
    source: 'models.dev',
  ),
};

/// key 解析钩子：给定 env var 名，返回 API key（App 从 SharedPreferences 读）。
String? Function(String envVar) keyResolver = (_) => null;

/// 通过 env var 检查查找内置 provider 的 key。
String? _keyForEnvVars(List<String> envVars) {
  for (final envVar in envVars) {
    final key = keyResolver(envVar);
    if (key != null && key.isNotEmpty) {
      return key;
    }
  }
  return null;
}

/// 查找内置 provider by id 或别名。
///
/// 解析顺序：Hermes overlays + models.dev catalog。
/// 返回完全解析的 ProviderDef 或 null。
ProviderDef? getProvider(String name) {
  final canonical = normalizeProvider(name);
  return builtinProviderDefs[canonical];
}

/// 用户配置的 provider（对应 config.yaml ``providers:`` 段）。
ProviderDef? resolveUserProvider(String name, Map<String, dynamic>? userConfig) {
  if (userConfig == null || userConfig.isEmpty) {
    return null;
  }
  final entry = userConfig[name];
  if (entry is! Map<String, dynamic>) {
    return null;
  }

  final displayName = entry['name'] as String? ?? name;
  final apiUrl = entry['api'] as String? ??
      entry['url'] as String? ??
      entry['base_url'] as String? ??
      '';
  final keyEnv = entry['key_env'] as String? ?? '';
  final transport = Transport.fromValue(
          entry['transport'] as String? ?? 'openai_chat') ??
      Transport.openaiChat;

  return ProviderDef(
    id: name,
    name: displayName,
    transport: transport,
    apiKeyEnvVars: keyEnv.isNotEmpty ? [keyEnv] : const [],
    baseUrl: apiUrl,
    isAggregator: false,
    authType: 'api_key',
    source: 'user-config',
  );
}

/// 确定 provider/endpoint 的 API 模式（wire 协议）。
///
/// 解析顺序：
/// 1. 已知 provider → transport → TRANSPORT_TO_API_MODE。
/// 2. bedrock 直接检查。
/// 3. 默认 'chat_completions'。
String determineApiMode(String provider, {String baseUrl = '', String model = ''}) {
  final pdef = getProvider(provider);
  if (pdef != null) {
    return transportToApiMode(pdef.transport);
  }
  if (provider == 'bedrock') {
    return 'bedrock_converse';
  }
  return 'chat_completions';
}

/// 完整解析链：内置 → 用户配置。
///
/// 这是 --provider flag 解析的主入口。
///
/// [keyResolver] 已通过顶层钩子提供 key。
ProviderDef? resolveProviderFull(
  String name, {
  Map<String, dynamic>? userProviders,
}) {
  final canonical = normalizeProvider(name);
  final raw = name.trim().toLowerCase();

  // 0. 用户定义 config provider 优先于内置别名表。
  if (userProviders != null) {
    final userPdef = resolveUserProvider(raw, userProviders);
    if (userPdef != null) {
      return userPdef;
    }
  }

  // 1. 内置（models.dev + overlays）。
  final pdef = getProvider(canonical);
  if (pdef != null) {
    return pdef;
  }

  // 2. 用户定义 providers from config。
  if (userProviders != null) {
    final byCanonical = resolveUserProvider(canonical, userProviders);
    if (byCanonical != null) {
      return byCanonical;
    }
    final byRaw = resolveUserProvider(raw, userProviders);
    if (byRaw != null) {
      return byRaw;
    }
  }

  return null;
}

/// 返回 provider 的 API key（通过 keyResolver 钩子）。
String? providerApiKey(ProviderDef pdef) => _keyForEnvVars(pdef.apiKeyEnvVars);

/// 是否聚合器 provider（如 openrouter/nous）。
bool isAggregator(String provider) {
  final pdef = getProvider(provider);
  return pdef?.isAggregator ?? false;
}
