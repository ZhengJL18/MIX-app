/// 对应 `ref/hermes-agent/agent/file_safety.py`（像素级复刻）。
///
/// tools 和 ACP shims 共用的文件安全规则。
///
/// ## Dart 适配
/// - `hermes_constants.get_hermes_home()` / `get_default_hermes_root()` →
///   可注入钩子 [hermesHomePathProvider] / [hermesRootPathProvider]。
/// - `os.path.realpath` → [_realpath]（resolveSymbolicLinksSync，失败回退
///   normalize+absolute）。`Path.resolve()` 同理。
/// - `Path.relative_to`（抛 ValueError）→ `p.isWithin` 判真后再 `p.relative`。
/// - `Path.home()` → [homePath]（HOME / USERPROFILE 环境变量）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 解析活动 HERMES_HOME（profile-aware）的钩子，无循环导入。
/// 复刻 hermes_constants.get_hermes_home 时赋值。
String Function() hermesHomePathProvider = () {
  return p.join(homePath(), '.hermes');
};

/// 解析 Hermes 根目录（始终是任何 profile 的父目录，绝不 per-profile）的钩子。
/// 复刻 hermes_constants.get_default_hermes_root 时赋值。
String Function() hermesRootPathProvider = () {
  return p.join(homePath(), '.hermes');
};

/// 用户主目录。Python `Path.home()` 对应物。
String homePath() {
  final h = Platform.environment['HOME'];
  if (h != null && h.isNotEmpty) {
    return h;
  }
  final u = Platform.environment['USERPROFILE'];
  if (u != null && u.isNotEmpty) {
    return u;
  }
  return '.';
}

/// `os.path.expanduser`：展开前导 `~`/`~/`。不做 `~user`（文件安全场景不需要）。
String _expanduser(String path) {
  if (path == '~') {
    return homePath();
  }
  if (path.startsWith('~/') || path.startsWith(r'~\\')) {
    return p.join(homePath(), path.substring(2));
  }
  return path;
}

/// `os.path.realpath` 对应物：解析符号链接；失败回退 normalize+absolute。
/// `Path.resolve()` 同理。
String realpath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } catch (_) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return p.normalize(p.absolute(_expanduser(path)));
    }
  }
}

/// 返回必须绝不可写的精确敏感路径。
Set<String> buildWriteDeniedPaths(String home) {
  final hermesHome = hermesHomePathProvider();
  final hermesRoot = hermesRootPathProvider();
  final candidates = <String>[
    p.join(home, '.ssh', 'authorized_keys'),
    p.join(home, '.ssh', 'id_rsa'),
    p.join(home, '.ssh', 'id_ed25519'),
    p.join(home, '.ssh', 'config'),
    // 活动 profile 的 .env（非 profile 模式下为顶层 .env）。
    p.join(hermesHome, '.env'),
    // 顶层 .env，即使在 profile 模式下 —— 覆盖它会泄漏凭据到每个继承自根的
    // profile（#15981）。
    p.join(hermesRoot, '.env'),
    // 活动 profile 的 Anthropic PKCE 凭据存储。
    p.join(hermesHome, '.anthropic_oauth.json'),
    // 顶层 Anthropic PKCE 凭据存储即使在 profile 激活时仍敏感；默认/非
    // profile 会话仍读取它。
    p.join(hermesRoot, '.anthropic_oauth.json'),
    // Bitwarden Secrets Manager 加密磁盘缓存。
    p.join(hermesHome, 'cache', 'bws_cache.enc.json'),
    p.join(hermesRoot, 'cache', 'bws_cache.enc.json'),
    p.join(home, '.netrc'),
    p.join(home, '.pgpass'),
    p.join(home, '.npmrc'),
    p.join(home, '.pypirc'),
    p.join(home, '.git-credentials'),
    '/etc/sudoers',
    '/etc/passwd',
    '/etc/shadow',
  ];
  return candidates.map((x) => realpath(x)).toSet();
}

/// 返回必须绝不可写的敏感目录前缀。
List<String> buildWriteDeniedPrefixes(String home) {
  return [
    for (final x in [
      p.join(home, '.ssh'),
      p.join(home, '.aws'),
      p.join(home, '.gnupg'),
      p.join(home, '.kube'),
      '/etc/sudoers.d',
      '/etc/systemd',
      p.join(home, '.docker'),
      p.join(home, '.azure'),
      p.join(home, '.config', 'gh'),
      p.join(home, '.config', 'gcloud'),
    ])
      realpath(x) + p.separator,
  ];
}

/// 返回解析后的 HERMES_WRITE_SAFE_ROOT 路径。支持多个目录由
/// ``os.pathsep``（Unix ``:``，Windows ``;``）分隔。
Set<String> getSafeWriteRoots() {
  final env = Platform.environment['HERMES_WRITE_SAFE_ROOT'] ?? '';
  if (env.isEmpty) {
    return <String>{};
  }
  final roots = <String>{};
  // Python os.pathsep：Unix ':' / Windows ';'（列表分隔符，非路径组件分隔符）。
  final sep = Platform.isWindows ? ';' : ':';
  for (final path in env.split(sep)) {
    if (path.isNotEmpty) {
      try {
        roots.add(realpath(_expanduser(path)));
      } catch (_) {
        continue;
      }
    }
  }
  return roots;
}

/// 返回 ``'credential'``、``'safe_root'``，或若允许写入则 ``null``。
String? _classifyWriteDenial(String path) {
  final home = realpath(_expanduser('~'));
  final resolved = realpath(_expanduser(path));

  if (buildWriteDeniedPaths(home).contains(resolved)) {
    return 'credential';
  }
  for (final prefix in buildWriteDeniedPrefixes(home)) {
    if (resolved.startsWith(prefix)) {
      return 'credential';
    }
  }

  const mcpTokensDirName = 'mcp-tokens';

  final hermesDirs = <String>[];
  for (final base in [hermesHomePathProvider(), hermesRootPathProvider()]) {
    try {
      final real = realpath(base);
      if (!hermesDirs.contains(real)) {
        hermesDirs.add(real);
      }
    } catch (_) {
      continue;
    }
  }

  for (final baseReal in hermesDirs) {
    // 会话转录是应用自有状态。让 agent 的通用文件工具重写 state.db 或旧 JSON
    // 快照可能伪造对话历史并使 resume/compression 状态失效。
    try {
      if (resolved == realpath(p.join(baseReal, 'state.db'))) {
        return 'credential';
      }
      final sessionsReal = realpath(p.join(baseReal, 'sessions'));
      if (resolved == sessionsReal ||
          resolved.startsWith(sessionsReal + p.separator)) {
        return 'credential';
      }
    } catch (_) {
      // pass
    }
    try {
      final mcpReal = realpath(p.join(baseReal, mcpTokensDirName));
      if (resolved == mcpReal ||
          resolved.startsWith(mcpReal + p.separator)) {
        return 'credential';
      }
    } catch (_) {
      // pass
    }
    try {
      final pairingReal = realpath(p.join(baseReal, 'pairing'));
      if (resolved == pairingReal ||
          resolved.startsWith(pairingReal + p.separator)) {
        return 'credential';
      }
    } catch (_) {
      // pass
    }
  }

  final safeRoots = getSafeWriteRoots();
  if (safeRoots.isNotEmpty) {
    var allowed = false;
    for (final safeRoot in safeRoots) {
      if (resolved == safeRoot ||
          resolved.startsWith(safeRoot + p.separator)) {
        allowed = true;
        break;
      }
    }
    if (!allowed) {
      return 'safe_root';
    }
  }

  return null;
}

/// 若路径被写黑名单或 safe root 阻塞则返回 True。
bool isWriteDenied(String path) => _classifyWriteDenial(path) != null;

/// 当对 ``path`` 的写入被阻塞时返回面向用户/模型的消息。
String? getWriteDeniedError(String path, {String verb = 'Write'}) {
  final denial = _classifyWriteDenial(path);
  if (denial == null) {
    return null;
  }
  if (denial == 'safe_root') {
    final rootsDisplay = getSafeWriteRoots().toList()..sort();
    return "$verb denied: '$path' is outside HERMES_WRITE_SAFE_ROOT "
        '(${rootsDisplay.join(Platform.isWindows ? ';' : ':')}). Unset the variable '
        "or add this path's directory prefix.";
  }
  return "$verb denied: '$path' is a protected system/credential file.";
}

/// 常见含秘密的项目本地环境文件 basename。
/// 这些被阻塞因为 .env 文件常含 API keys、数据库密码和其他凭据。
const Set<String> _blockedProjectEnvBasenames = {
  '.env',
  '.env.local',
  '.env.development',
  '.env.production',
  '.env.test',
  '.env.staging',
  '.envrc',
};

/// 当读取目标是拒绝的 Hermes 路径时返回错误消息。
///
/// 三个类别被阻塞：
///
///   * HERMES_HOME/skills/.hub 下的内部 Hermes 缓存文件 —— 可读元数据，攻击者可
///     用作 prompt-injection 载体。
///   * HERMES_HOME 和全局 Hermes 根下的凭据/秘密存储：``auth.json``、
///     ``auth.lock``、``.anthropic_oauth.json``、``.env``、
///     ``webhook_subscriptions.json``、``auth/google_oauth.json``、以及
///     ``mcp-tokens/`` 下任何东西。这些保存明文 provider keys、OAuth tokens 和
///     HMAC secrets，agent 从不需要直接读取 —— provider 工具/gateway 适配器经
///     内部渠道消费它们。
///   * 磁盘上任何地方的项目本地环境文件：``.env``、``.env.local``、
///     ``.env.development``、``.env.production``、``.env.test``、
///     ``.env.staging``、``.envrc``。这些常含用户自己项目的 API keys、数据库
///     密码等凭据。帮用户调试项目的 agent 通常不应需要读取它们 ——
///     ``.env.example`` 是文档化形状的替代。
///
/// **这不是安全边界。** terminal 工具以同一 OS 用户运行且有 shell 访问；agent
/// 仍可 ``cat auth.json`` 或 ``cat ~/.hermes/.env`` 并外泄文件。read-deny 作为
/// 纵深防御存在，它：
///
///   * 对尊重工具拒绝的模型返回清晰错误，经验上促使多数现代模型停止而非求助 shell。
///   * 当有东西试图读取凭据时暴露可见审计轨迹 —— 比通用 ``cat`` 更易在日志中发现。
///
/// 围绕此的任何用户可见表述应视为"可能有帮助"而非"阻止攻击者"。坚定的模型或
/// 恶意指令总能 shell 出去。
///
/// 针对非进程 cwd 解析相对路径的调用者（如 tools/file_tools.py 的
/// ``TERMINAL_CWD``）必须预解析并传绝对路径字符串。本函数的 ``resolve()`` 锚定
/// 在 Python 进程 cwd，因此任务 terminal cwd 与进程 cwd 不同时，相对输入如
/// ``"auth.json"`` 会错过黑名单。
String? getReadBlockError(String path) {
  final resolved = realpath(_expanduser(path));

  // 解析活动 HERMES_HOME（profile-aware）和全局 Hermes 根，使 profile 模式下
  // <root>/auth.json 等凭据存储也被阻塞。与写拒绝加宽同形（#15981, #14157）。
  final hermesDirs = <String>[];
  for (final base in [hermesHomePathProvider(), hermesRootPathProvider()]) {
    try {
      final real = realpath(base);
      if (!hermesDirs.contains(real)) {
        hermesDirs.add(real);
      }
    } catch (_) {
      continue;
    }
  }

  // Skills .hub：prompt-injection 载体。
  for (final hd in hermesDirs) {
    final blockedDirs = [
      p.join(hd, 'skills', '.hub', 'index-cache'),
      p.join(hd, 'skills', '.hub'),
    ];
    for (final blocked in blockedDirs) {
      if (!p.isWithin(blocked, resolved)) {
        continue;
      }
      return 'Access denied: $path is an internal Hermes cache file '
          'and cannot be read directly to prevent prompt injection. '
          'Use the skills_list or skill_view tools instead.';
    }
  }

  // 凭据/秘密存储。HERMES_HOME 或 Hermes 根下任一处的精确文件匹配。
  final credentialFileNames = <String>[
    'auth.json',
    'auth.lock',
    '.anthropic_oauth.json',
    '.env',
    'webhook_subscriptions.json',
    p.join('auth', 'google_oauth.json'),
    // Bitwarden Secrets Manager 磁盘缓存：保存明文 secret 值以避免跨背靠背 CLI
    // 调用重新获取。由 #31968 引入但未加入此守卫。
    p.join('cache', 'bws_cache.json'),
  ];
  for (final hd in hermesDirs) {
    for (final name in credentialFileNames) {
      try {
        final blocked = realpath(p.join(hd, name));
        if (resolved == blocked) {
          return 'Access denied: $path is a Hermes credential store '
              'and cannot be read directly. Provider tools consume '
              'these credentials through internal channels. '
              '(Defense-in-depth — not a security boundary; the '
              'terminal tool can still bypass.)';
        }
      } catch (_) {
        continue;
      }
    }
  }

  // mcp-tokens/：目录前缀匹配 —— 内部任何东西都是 OAuth token 材料。
  for (final hd in hermesDirs) {
    final mcpTokens = realpath(p.join(hd, 'mcp-tokens'));
    if (resolved == mcpTokens) {
      return 'Access denied: $path is the Hermes MCP token directory '
          'and cannot be read directly. (Defense-in-depth — not a '
          'security boundary; the terminal tool can still bypass.)';
    }
    if (p.isWithin(mcpTokens, resolved)) {
      return 'Access denied: $path is a Hermes MCP token file '
          'and cannot be read directly. (Defense-in-depth — not a '
          'security boundary; the terminal tool can still bypass.)';
    }
  }

  // 阻塞磁盘上任意处的常见含秘密项目本地 .env 文件。帮用户处理项目的 agent
  // 很少需要读取原始 .env 内容 —— .env.example 是文档化形状的替代。terminal
  // 工具仍可 ``cat .env``；这是纵深防御，不是边界。
  if (_blockedProjectEnvBasenames.contains(p.basename(resolved).toLowerCase())) {
    return 'Access denied: $path is a secret-bearing environment file '
        'and cannot be read to prevent credential leakage. '
        'If you need to check the file structure, read .env.example instead. '
        '(Defense-in-depth — not a security boundary; the terminal tool can still bypass.)';
  }

  return null;
}

/// 若 *path* 是拒绝的 Hermes 读取则抛 [FormatException]（见 [getReadBlockError]），
/// 否则返回。
///
/// provider 输入加载点（读模型/工具提供的本地文件，如 image-gen ``image_url`` /
/// ``reference_image_urls`` 路径）的共享咽喉点。集中守卫使每个 provider 以相同
/// 语义强制同一读取边界，而不是各自 open-code try/except（#57698）。
///
/// 刻意 best-effort：若调用点 agent.file_safety 机制不可用则守卫 no-op，不破坏
/// 本地图像加载 —— 与黑名单自身的纵深防御（非安全边界）框架一致。真实命中的
/// 阻塞 [FormatException] 仍传播；只有意外内部错误被吞掉。
void raiseIfReadBlocked(String path) {
  String? blocked;
  try {
    blocked = getReadBlockError(path);
  } catch (_) {
    return;
  }
  if (blocked != null) {
    throw FormatException(blocked);
  }
}

/// Profile 作用域目录（HERMES_HOME、Hermes 根、根下 profiles 各子目录中）应被
/// 守卫。在此加新区域无需其他代码变更即可扩展守卫。
final List<String> profileScopedAreas = ['skills', 'plugins', 'cron', 'memories'];

/// 返回从 HERMES_HOME 派生的活动 profile 名。
///
/// ``~/.hermes``              -> ``"default"``
/// ``~/.hermes/profiles/X``  -> ``"X"``
///
/// 任何解析失败回退 ``"default"``，使守卫永不抛进工具路径。
String _resolveActiveProfileName() {
  String homeReal;
  String rootReal;
  try {
    homeReal = realpath(hermesHomePathProvider());
    rootReal = realpath(hermesRootPathProvider());
  } catch (_) {
    return 'default';
  }
  final profilesDir = p.join(rootReal, 'profiles');
  if (p.isWithin(profilesDir, homeReal)) {
    final rel = p.relative(homeReal, from: profilesDir);
    final parts = p.split(rel);
    if (parts.isNotEmpty) {
      return parts.first;
    }
  }
  return 'default';
}

/// 如果写入目标落在另一 profile 的作用域区域（skills/plugins/cron/memories），
/// 则将其分类为 cross-profile。
///
/// 当目标在 Hermes 作用域之外，或在活动 profile 内，或不命中 profile 作用域区域
/// 时返回 null。否则返回含以下键的 dict：
///
///   * ``active_profile``：agent 运行所在 profile 名
///   * ``target_profile``：路径所属 profile 名
///   * ``area``：哪个作用域区域（``"skills"``、``"plugins"`` 等）
///   * ``target_path``：解析后的路径字符串
///
/// 调用者决定如何处理结果 —— 向模型表面警告、提示用户、或（明确同意 /
/// ``cross_profile=True``）照样继续。
Map<String, String>? classifyCrossProfileTarget(String path) {
  final target = realpath(_expanduser(path));
  final rootReal = realpath(hermesRootPathProvider());

  String? targetProfile;
  String? area;

  if (!p.isWithin(rootReal, target)) {
    return null;
  }
  final rel = p.relative(target, from: rootReal);
  final parts = p.split(rel);
  if (parts.isEmpty) {
    return null;
  }

  if (profileScopedAreas.contains(parts.first)) {
    // ``<root>/<area>/...`` → default profile。
    targetProfile = 'default';
    area = parts.first;
  } else if (parts.first == 'profiles' &&
      parts.length >= 3 &&
      profileScopedAreas.contains(parts[2])) {
    // ``<root>/profiles/<name>/<area>/...`` → named profile。
    targetProfile = parts[1];
    area = parts[2];
  } else {
    return null;
  }

  final activeProfile = _resolveActiveProfileName();
  if (targetProfile == activeProfile) {
    // 同 profile 写入 —— 不是 cross-profile 事件。
    return null;
  }

  return {
    'active_profile': activeProfile,
    'target_profile': targetProfile,
    'area': area,
    'target_path': target,
  };
}

/// 当 *path* 是 cross-profile 时返回面向模型警告字符串。
///
/// 当写入在作用域内（同 profile）或完全在 Hermes 之外时返回 null。调用者预期将
/// 警告作为工具结果错误表面给 agent，NOT 静默允许写入 —— agent 必须要么获得
/// 明确用户指示继续，要么向写入工具传 ``cross_profile=True``。
///
/// 这是纵深防御：terminal 工具以同一 OS 用户运行，不经此守卫即可写任意这些路径。
/// 把守卫视为混乱减少器，而非安全边界。
String? getCrossProfileWarning(String path) {
  final info = classifyCrossProfileTarget(path);
  if (info == null) {
    return null;
  }
  return 'Cross-profile write blocked by soft guard: ${info['target_path']} '
      "belongs to Hermes profile '${info['target_profile']}', but the "
      "agent is running under profile '${info['active_profile']}'. "
      "Editing another profile's ${info['area']}/ will affect that "
      "profile's future sessions, not the one you are currently in. "
      'Confirm with the user before proceeding. To bypass this guard '
      'after explicit user direction, retry the call with '
      '``cross_profile=True``. (Defense-in-depth — not a security '
      'boundary; the terminal tool can still bypass.)';
}

/// 在 sandbox-mirror 路径中返回内层 ``.hermes`` part 的索引。
///
/// 匹配 ``…/sandboxes/<backend>/<task>/home/.hermes/…`` 并返回内层 Hermes-state
/// 部分开始处索引。不含 sandbox-mirror 形状的路径返回 null。
int? _findSandboxMirrorSegments(List<String> parts) {
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] != 'sandboxes') {
      continue;
    }
    // 需要至少：sandboxes / <backend> / <task> / home / .hermes / <thing>
    if (i + 5 >= parts.length) {
      continue;
    }
    if (parts[i + 3] == 'home' && parts[i + 4] == '.hermes') {
      return i + 4;
    }
  }
  return null;
}

/// 将写入目标分类为权威 Hermes 状态的 sandbox-mirror。
///
/// 路径不匹配 sandbox-mirror 形状时返回 null。否则返回含以下键的 dict：
///
///   * ``target_path``：解析后的路径字符串
///   * ``mirror_root``：``…/sandboxes/<backend>/<task>/home/.hermes`` 前缀
///   * ``inner_path``：mirror 的 ``.hermes`` 下的部分
///
/// 检测仅路径形状 —— 不要求任何 Hermes resolver 成功，因此在 HERMES_HOME 解析
/// 会含糊的上下文调用也能正确工作。
Map<String, String>? classifySandboxMirrorTarget(String path) {
  final target = realpath(_expanduser(path));
  final parts = p.split(target);
  final innerIdx = _findSandboxMirrorSegments(parts);
  if (innerIdx == null) {
    return null;
  }

  final mirrorRoot = p.joinAll(parts.sublist(0, innerIdx + 1));
  final innerPath = innerIdx + 1 < parts.length
      ? p.joinAll(parts.sublist(innerIdx + 1))
      : '';

  return {
    'target_path': target,
    'mirror_root': mirrorRoot,
    'inner_path': innerPath,
  };
}

/// 当 *path* 落在 sandbox mirror 中时返回面向模型警告。
///
/// 路径不是 sandbox-mirror 目标时返回 null。调用者预期将警告作为工具结果错误
/// 表面。bypass kwarg（``cross_profile=True``）与 cross-profile 守卫共享：两者
/// 都是用户可授权的软性"我知道我在做什么"覆盖。
///
/// 纵深防御，NOT 安全边界：terminal 工具以同一 OS 用户运行，可直接写 mirror
/// 路径。守卫存在于 #32049 的静默成功 + 分叉拷贝 footgun 触发前表面误分类。
String? getSandboxMirrorWarning(String path) {
  final info = classifySandboxMirrorTarget(path);
  if (info == null) {
    return null;
  }
  return 'Sandbox-mirror write blocked by soft guard: ${info['target_path']} '
      "sits under '${info['mirror_root']}', which is a per-task mirror "
      'created by a non-local terminal backend (docker/daytona/etc.). '
      'Writes here land on a copy that the host Hermes process never '
      "reads — the authoritative file is likely '${info['inner_path']}' "
      'under the real HERMES_HOME. Use the host-side tool for '
      'authoritative state (e.g. ``memory`` for memories), or address '
      'the host path directly. To bypass this guard after explicit '
      'user direction, retry the call with ``cross_profile=True``. '
      '(Defense-in-depth — not a security boundary; the terminal tool '
      'can still bypass.)';
}

/// 将写入目标分类为容器侧 sandbox mirror。
///
/// 当已确立文件工具在 home 为 sandbox mirror 的容器中执行后，``mirror_prefix``
/// 必须由调用者提供。无此类上下文激活或路径不在 mirror 前缀下时返回 null。
/// 否则返回：
///
///   * ``target_path``：解析后的路径字符串
///   * ``mirror_root``：声明的容器 mirror 前缀
///   * ``inner_path``：mirror 根下的部分
Map<String, String>? classifyContainerMirrorTarget(
  String path, {
  String? mirrorPrefix,
}) {
  if (mirrorPrefix == null || mirrorPrefix.isEmpty) {
    return null;
  }
  final target = realpath(_expanduser(path));
  final mirror = realpath(_expanduser(mirrorPrefix));
  if (!p.isWithin(mirror, target)) {
    return null;
  }
  final inner = p.relative(target, from: mirror);
  return {
    'target_path': target,
    'mirror_root': mirror,
    // Python 用 as_posix() —— 统一正斜杠。
    'inner_path': p.posix.joinAll(p.split(inner)),
  };
}

/// 当 *path* 落在容器权威 Hermes 状态的 sandbox mirror 中时返回面向模型警告。
///
/// 仅当当前文件工具后端已知在 Docker sandbox 内执行时调用者提供
/// ``mirror_prefix``。与 ``get_cross_profile_warning`` 相同契约：软守卫，非
/// mirror 路径返回 null，调用者作为工具结果错误表面。明确用户指示后经
/// ``cross_profile=True`` bypass。
String? getContainerMirrorWarning(String path, {String? mirrorPrefix}) {
  final info = classifyContainerMirrorTarget(path, mirrorPrefix: mirrorPrefix);
  if (info == null) {
    return null;
  }
  return 'Sandbox-mirror write blocked by soft guard: ${info['target_path']} '
      "sits under '${info['mirror_root']}', which is the container's "
      'bind-mounted home — a per-task mirror that the host Hermes '
      'process never reads. The authoritative file is '
      "'${info['inner_path']}' under the real HERMES_HOME. Use the "
      'host-side tool for authoritative state (e.g. ``memory`` for '
      'memories), or address the host path directly. To bypass after '
      'explicit user direction, retry with ``cross_profile=True``. '
      '(Defense-in-depth — not a security boundary; the terminal tool '
      'can still bypass.)';
}
