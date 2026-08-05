/// 对应 `ref/hermes-agent/tools/url_safety.py`（像素级复刻，核心 SSRF 防护）。
///
/// 拦截访问私网/内网/云元数据端点的 URL（SSRF 防护）。
///
/// ## Dart 适配
/// - `ipaddress` 模块：Dart 无内置，用 [InternetAddress] 解析 + 手写私网段判定。
/// - `socket.getaddrinfo`：Dart `InternetAddress.lookup`。
/// - `_proxy_is_configured`：App 无代理，恒 false。
library;

import 'dart:async';
import 'dart:io';

/// 需拦截的内网 hostname（云元数据端点）。
const Set<String> blockedHostnames = {
  'metadata.google.internal',
  'metadata.goog',
};

/// 云元数据端点 IP（永远拦截，无视 allow_private 开关）。
const List<String> alwaysBlockedIps = [
  '169.254.169.254', // AWS/GCP/Azure/DO/Oracle metadata
  '169.254.170.2', // AWS ECS task metadata
  '169.254.169.253', // Azure IMDS wire server
  'fd00:ec2::254', // AWS metadata (IPv6)
  '100.100.100.200', // Alibaba Cloud metadata
  // IPv4-mapped IPv6 variants。
  '::ffff:169.254.169.254',
  '::ffff:169.254.170.2',
  '::ffff:169.254.169.253',
  '::ffff:100.100.100.200',
];

/// 永远拦截的网络段（link-local 范围）。
const List<String> alwaysBlockedNetworks = [
  '169.254.0.0/16',
  '::ffff:169.254.0.0/112',
];

/// 允许解析到私网 IP 的 HTTPS hostname（极窄白名单，对齐 Python）。
const Set<String> trustedPrivateIpHosts = {
  'multimedia.nt.qq.com.cn',
};

/// CGNAT（100.64.0.0/10）需显式拦截（Python ipaddress.is_private 不覆盖）。
const String cgnatNetwork = '100.64.0.0/10';

/// 允许访问私网 IP 的开关（对应 HERMES_ALLOW_PRIVATE_URLS）。
///
/// 默认 true：单机私有 App，走 VPN/代理时 DNS 可能解析到代理服务器的内网
/// 地址，拦私网 IP 会误杀正常访问。云元数据端点由 [alwaysBlockedIps] 永远
/// 拦截（SSRF 安全底线，不受此开关影响）。
bool allowPrivateUrls = true;

/// 解析 hostname（IPv4/IPv6）。
Future<List<InternetAddress>> _lookup(String hostname) async {
  try {
    return await InternetAddress.lookup(hostname);
  } catch (_) {
    return const [];
  }
}

/// 判断 IP 字符串是否为私网/保留地址。
///
/// Dart 的 InternetAddress 无公开 isPrivate getter，手写段判定
/// （对齐 Python ipaddress.is_private 常用范围）。
bool _isPrivateIp(String ip) {
  final addr = InternetAddress.tryParse(ip);
  if (addr == null) {
    return false;
  }
  if (addr.isLoopback || addr.isLinkLocal) {
    return true;
  }
  if (addr.type == InternetAddressType.IPv4) {
    final parts = ip.split('.');
    final a = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
    final b = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    // 私网段：10/8、172.16/12、192.168/16。
    if (a == 10) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    // 保留段：0/8、127/8、169.254/16（link-local）、192.0.2/24 等。
    if (a == 0) return true;
    if (a == 127) return true;
    if (a == 169 && b == 254) return true;
    // CGNAT 100.64.0.0/10。
    if (a == 100 && b >= 64 && b <= 127) return true;
    // 测试段 198.18/15。
    if (a == 198 && (b == 18 || b == 19)) return true;
  } else {
    // IPv6：唯一本地地址 fc00::/7（含 fd00:: 私网）。
    final lower = ip.toLowerCase();
    if (lower.startsWith('fc') || lower.startsWith('fd')) {
      return true;
    }
  }
  return false;
}

/// IP 是否在 always-blocked 集合（云元数据 / link-local）。
bool _isAlwaysBlockedIp(String ip) {
  if (alwaysBlockedIps.contains(ip)) {
    return true;
  }
  // 检查网络段（简化：仅前两段匹配 link-local 169.254.x.x / IPv4-mapped）。
  if (ip.startsWith('169.254.') || ip.startsWith('::ffff:169.254.')) {
    return true;
  }
  return false;
}

/// 检查 hostname 是否命中永远拦截的黑名单（无论 allow_private）。
bool _hostnameAlwaysBlocked(String hostname) {
  return blockedHostnames.contains(hostname);
}

/// URL 是否永远被拦截（云元数据 floor）。
///
/// 返回 True（= 拦截）当：
/// - hostname 在黑名单
/// - IP 在 always-blocked 集合 / link-local 网段
/// - hostname 解析到以上任一
///
/// 比 isSafeUrl 窄：只拦哨兵集合，不拦普通私网地址。
Future<bool> isAlwaysBlockedUrl(String url) async {
  try {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final hostname = (uri.host.trim().toLowerCase()).replaceAll(RegExp(r'\.+$'), '');
    if (hostname.isEmpty) {
      return false;
    }
    if (_hostnameAlwaysBlocked(hostname)) {
      return true;
    }
    // 字面 IP。
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) {
      return _isAlwaysBlockedIp(hostname);
    }
    // 解析 hostname 检查每个 IP。
    final addrs = await _lookup(hostname);
    for (final a in addrs) {
      if (_isAlwaysBlockedIp(a.address)) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// URL 目标是否非私网/内网地址。
///
/// fail-closed：DNS 错误和异常拦截请求。
/// `allowPrivateUrls` 开启时跳过私网 IP 拦截，但云元数据端点永远拦截。
Future<bool> isSafeUrl(String url) async {
  try {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return false;
    }
    final hostname = (uri.host.trim().toLowerCase()).replaceAll(RegExp(r'\.+$'), '');
    final scheme = uri.scheme.trim().toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return false;
    }
    if (hostname.isEmpty) {
      return false;
    }
    // 内网 hostname 永远拦截（无视 toggle）。
    if (_hostnameAlwaysBlocked(hostname)) {
      return false;
    }
    // 白名单 host：HTTPS + trusted host 允许私网 IP。
    if (scheme == 'https' && trustedPrivateIpHosts.contains(hostname)) {
      return true;
    }
    // 字面 IP。
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) {
      if (_isAlwaysBlockedIp(hostname)) {
        return false;
      }
      if (allowPrivateUrls) {
        return true;
      }
      return !_isPrivateIp(hostname);
    }
    // 解析 hostname。
    final addrs = await _lookup(hostname);
    if (addrs.isEmpty) {
      // DNS 失败 → fail-closed 拦截（App 无代理）。
      return false;
    }
    for (final a in addrs) {
      final ip = a.address;
      if (_isAlwaysBlockedIp(ip)) {
        return false;
      }
      if (allowPrivateUrls) {
        continue;
      }
      if (_isPrivateIp(ip)) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false; // fail-closed。
  }
}

/// 敏感查询参数名检测（URL 含凭据时拦截）。
///
/// 对齐 Python `_SENSITIVE_QUERY_PARAM_NAMES`：**精确匹配**窄名单，且只匹配
/// 值非空的参数。故意不含裸词 `key`/`auth`/`sig`（避免误杀 `?keyword=`、
/// `?authentication=`、CDN 的 `?sig=` 等合法参数）。
const Set<String> sensitiveQueryKeys = {
  'access_token',
  'api_key',
  'apikey',
  'auth_token',
  'authorization',
  'awsaccesskeyid',
  'client_secret',
  'credential',
  'credentials',
  'jwt',
  'password',
  'passwd',
  'secret',
  'session_id',
  'signature',
  'token',
  'x_amz_security_token',
  'x_amz_signature',
  'x-amz-security-token',
  'x-amz-signature',
};

/// 返回 URL 中的敏感查询参数名，无则 null。
String? sensitiveQueryParamName(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return null;
    }
    // 用 queryParametersAll 保留重复参数 + 检查值非空。
    for (final entry in uri.queryParametersAll.entries) {
      if (sensitiveQueryKeys.contains(entry.key.toLowerCase()) &&
          entry.value.any((v) => v.isNotEmpty)) {
        return entry.key;
      }
    }
  } catch (_) {}
  return null;
}

/// 规范化 URL（小写 scheme/host、处理 IPv6 等）。
String normalizeUrlForRequest(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.toString();
  } catch (_) {
    return url;
  }
}
