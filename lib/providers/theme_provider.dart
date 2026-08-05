import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';

/// 全局主题状态 — 支持多套主题自由切换，持久化到本地。
class ThemeProvider extends ChangeNotifier {
  static const String _themeKey = 'app_theme_id';

  AppThemeId _themeId = AppThemeId.warm;
  ThemeMode _mode = ThemeMode.system;

  AppThemeId get themeId => _themeId;
  ThemeMode get mode => _mode;

  /// 加载已保存的主题偏好（App 启动时调用）。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTheme = prefs.getString(_themeKey);
    if (savedTheme != null) {
      _themeId = AppThemeId.fromId(savedTheme);
    }
    notifyListeners();
  }

  /// 切换主题色板（ThemeData 重建 + ThemeExtension 自动跟随，无需同步全局）。
  Future<void> setTheme(AppThemeId id) async {
    if (_themeId == id) return;
    _themeId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, id.id);
  }

  /// 切换明暗模式（跟随系统 / 浅色 / 深色）。
  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
  }
}
