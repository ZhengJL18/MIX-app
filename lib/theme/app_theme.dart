import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_palette.dart';

/// 主题标识 — 可持久化到 SharedPreferences。
enum AppThemeId {
  warm('warm', '暖橙'),
  cool('cool', '冷蓝'),
  midnight('midnight', '深棕'),
  night('night', '黑夜');

  final String id;
  final String label;
  const AppThemeId(this.id, this.label);

  static AppThemeId fromId(String? id) {
    return AppThemeId.values.firstWhere(
      (t) => t.id == id,
      orElse: () => AppThemeId.warm,
    );
  }
}

class AppTheme {
  AppTheme._();

  /// 主题色板表。
  static const Map<AppThemeId, AppPalette> palettes = {
    AppThemeId.warm: AppPalettePresets.warm,
    AppThemeId.cool: AppPalettePresets.cool,
    AppThemeId.midnight: AppPalettePresets.midnight,
    AppThemeId.night: AppPalettePresets.night,
  };

  /// 根据主题 id 和亮度构建 ThemeData。
  static ThemeData build(AppThemeId id, {required Brightness brightness}) {
    final palette = palettes[id]!;
    // 同步全局活动色板（AppColors.xxx 据此跟随主题）
    AppColors.palette = palette;
    final isDark = brightness == Brightness.dark;

    final ColorScheme scheme;
    if (isDark) {
      scheme = ColorScheme.dark(
        primary: palette.primary,
        secondary: palette.secondary,
        tertiary: palette.accent,
        surface: palette.surface,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: palette.text,
        onSurfaceVariant: palette.textMuted,
      );
    } else {
      scheme = ColorScheme.light(
        primary: palette.primary,
        secondary: palette.secondary,
        tertiary: palette.accent,
        surface: palette.surface,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: palette.text,
        onSurfaceVariant: palette.textMuted,
      );
    }

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: palette.bg,
      colorScheme: scheme,
      extensions: [palette],
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 1,
        shadowColor: palette.text.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: palette.divider,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: palette.primary),
      textTheme: TextTheme(
        headlineLarge: TextStyle(
          fontSize: 28, fontWeight: FontWeight.w700, color: palette.text,
        ),
        headlineMedium: TextStyle(
          fontSize: 22, fontWeight: FontWeight.w600, color: palette.text,
        ),
        titleLarge: TextStyle(
          fontSize: 18, fontWeight: FontWeight.w600, color: palette.text,
        ),
        titleMedium: TextStyle(
          fontSize: 16, fontWeight: FontWeight.w500, color: palette.text,
        ),
        bodyLarge: TextStyle(
          fontSize: 17, height: 1.6, color: palette.text,
        ),
        bodyMedium: TextStyle(
          fontSize: 15, height: 1.5, color: palette.text,
        ),
        labelLarge: TextStyle(
          fontSize: 14, fontWeight: FontWeight.w500, color: palette.textMuted,
        ),
      ),
    );
  }

  // ── 兼容旧引用：保留 light/dark getter（返回暖色主题） ──
  static ThemeData get light => build(AppThemeId.warm, brightness: Brightness.light);
  static ThemeData get dark => build(AppThemeId.warm, brightness: Brightness.dark);
}
