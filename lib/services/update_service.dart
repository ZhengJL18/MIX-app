import 'dart:convert';

import 'package:app_installer_plus/app_installer_plus.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// 更新信息。
class UpdateInfo {
  /// 远端版本号（如 1.0.0+12）。
  final String version;

  /// 远端 versionCode（从版本号 `+N` 解析）。
  final int buildNumber;

  /// APK 下载直链。
  final String downloadUrl;

  /// 更新说明（release body）。
  final String? notes;

  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.downloadUrl,
    this.notes,
  });
}

/// 自动更新服务。
///
/// 版本源：GitHub Releases（CI 每次 push 发 release，tag = v1.0.0+<run_number>）。
/// App 启动时 checkForUpdate()，有新版返回 UpdateInfo，无/失败返回 null（静默）。
class UpdateService {
  static const String _repo = 'ZhengJL18/MIX-app';
  static const Duration _timeout = Duration(seconds: 15);

  /// 查最新 release，与本地版本比较。有新版返回 UpdateInfo，否则 null。
  /// 网络/解析失败返回 null（启动静默，不打扰用户）。
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final resp = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_repo/releases/latest'),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'MIX-app',
            },
          )
          .timeout(_timeout);

      if (resp.statusCode != 200) return null;
      final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;

      final tagName = data['tag_name'] as String? ?? '';
      final assets = data['assets'] as List<dynamic>? ?? [];
      if (tagName.isEmpty || assets.isEmpty) return null;

      // APK 下载直链（release 上传的 app-release.apk）
      String? downloadUrl;
      for (final a in assets) {
        final name = a['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          downloadUrl = a['browser_download_url'] as String?;
          break;
        }
      }
      if (downloadUrl == null) return null;

      // 本地版本
      final local = await PackageInfo.fromPlatform();
      final localBuild = int.tryParse(local.buildNumber) ?? 0;

      // 远端 buildNumber 从 tag 末尾 +N 解析（如 v1.0.0+12 → 12）
      final plusIdx = tagName.lastIndexOf('+');
      final remoteBuild =
          plusIdx >= 0 ? int.tryParse(tagName.substring(plusIdx + 1)) ?? 0 : 0;

      if (remoteBuild <= localBuild) return null; // 无新版

      return UpdateInfo(
        version: tagName.replaceFirst('v', ''),
        buildNumber: remoteBuild,
        downloadUrl: downloadUrl,
        notes: data['body'] as String?,
      );
    } catch (_) {
      return null; // 网络失败静默
    }
  }

  /// 下载并安装新版 APK（app_installer_plus 自带 FileProvider + 授权引导）。
  /// [onProgress] 0~1 下载进度。
  /// 返回 true 表示已触发安装，false 表示失败。
  static Future<bool> downloadAndInstall(
    String downloadUrl, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      await AppInstallerPlus().downloadAndInstallApk(
        downloadFileUrl: downloadUrl,
        onProgress: onProgress,
      );
      return true;
    } catch (e) {
      return false;
    }
  }
}
