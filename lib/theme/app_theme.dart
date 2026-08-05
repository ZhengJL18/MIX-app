import 'package:flutter/material.dart';
import 'app_palette.dart';

/// 主题标识 — 可持久化到 SharedPreferences。
/// 对应原生 Hermes 的 5 套主题。
enum AppThemeId {
  teal('teal', '青绿'),
  indigo('indigo', '靛蓝'),
  warm('warm', '暖橙'),
  violet('violet', '紫罗兰'),
  rose('rose', '玫瑰');

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

/// 一个主题的亮/暗种子色。
class ThemeSeeds {
  final Color lightSeed;
  final Color darkSeed;
  const ThemeSeeds(this.lightSeed, this.darkSeed);
}

class AppTheme {
  AppTheme._();

  /// 主题 → 亮/暗种子色（学 Hermes：从种子生成整套协调色）。
  static const Map<AppThemeId, ThemeSeeds> seeds = {
    AppThemeId.teal: ThemeSeeds(Color(0xFF00897B), Color(0xFF4DB6AC)),
    AppThemeId.indigo: ThemeSeeds(Color(0xFF3F51B5), Color(0xFF7986CB)),
    AppThemeId.warm: ThemeSeeds(Color(0xFFE65100), Color(0xFFFFB74D)),
    AppThemeId.violet: ThemeSeeds(Color(0xFF7B1FA2), Color(0xFFBA68C8)),
    AppThemeId.rose: ThemeSeeds(Color(0xFFC2185B), Color(0xFFF06292)),
  };

  /// 兼容旧引用：按 id+亮度返回生成的色板。
  static AppPalette paletteFor(AppThemeId id, {required bool isDark}) {
    final s = seeds[id]!;
    return AppPalette.fromSeed(
      isDark ? s.darkSeed : s.lightSeed,
      isDark: isDark,
    );
  }

  /// 主题色板表（亮色，供主题切换 UI 预览 primary 用）。
  /// AppPalette 由 seed 运行时生成，无法 const，用 getter 按需生成。
  static Map<AppThemeId, AppPalette> get palettes => {
        for (final id in AppThemeId.values) id: paletteFor(id, isDark: false),
      };

  /// 根据主题 id 和亮度构建 ThemeData。
  static ThemeData build(AppThemeId id, {required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;
    final palette = paletteFor(id, isDark: isDark);

    final scheme = isDark
        ? ColorScheme.dark(
            primary: palette.primary,
            secondary: palette.secondary,
            tertiary: palette.accent,
            surface: palette.bg,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: palette.text,
            onSurfaceVariant: palette.textMuted,
          )
        : ColorScheme.light(
            primary: palette.primary,
            secondary: palette.secondary,
            tertiary: palette.accent,
            surface: palette.bg,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: palette.text,
            onSurfaceVariant: palette.textMuted,
          );

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
