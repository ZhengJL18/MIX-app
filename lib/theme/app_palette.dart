import 'package:flutter/material.dart';

/// 统一色板 — ThemeExtension，随主题切换。
///
/// 配色从种子色经 Material 3 `ColorScheme.fromSeed` 生成（学原生 Hermes），
/// 保证整套颜色协调、明暗自动适配，不再手工硬编码散乱色值。
class AppPalette extends ThemeExtension<AppPalette> {
  final Color primary;
  final Color primaryLight;
  final Color secondary;
  final Color accent;
  final Color gold;

  final Color correct;
  final Color wrong;

  final Color bg;
  final Color surface;
  final Color surfaceAlt;

  final Color text;
  final Color textMuted;

  final Color divider;

  const AppPalette({
    required this.primary,
    required this.primaryLight,
    required this.secondary,
    required this.accent,
    required this.gold,
    required this.correct,
    required this.wrong,
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.text,
    required this.textMuted,
    required this.divider,
  });

  /// 从种子色生成整套协调配色（Material 3 fromSeed）。
  /// [seed] 主题种子色，[isDark] 决定明暗。
  factory AppPalette.fromSeed(Color seed, {required bool isDark}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: isDark ? Brightness.dark : Brightness.light,
    );
    return AppPalette(
      primary: scheme.primary,
      primaryLight: scheme.primaryContainer,
      secondary: scheme.secondaryContainer,
      accent: scheme.tertiary,
      // 金色点缀固定用 amber 系（不参与协调生成，作为强调色）
      gold: isDark ? const Color(0xFFFFD54F) : const Color(0xFFF9A825),
      // 对/错语义色固定用 Material 标准绿/红，保证语义清晰
      correct: isDark ? const Color(0xFF81C784) : const Color(0xFF2E7D32),
      wrong: isDark ? const Color(0xFFEF9A9A) : const Color(0xFFC62828),
      bg: scheme.surface,
      surface: scheme.surfaceContainerHighest,
      surfaceAlt: scheme.surfaceContainer,
      text: scheme.onSurface,
      textMuted: scheme.onSurfaceVariant,
      divider: scheme.outlineVariant,
    );
  }

  @override
  AppPalette copyWith({
    Color? primary,
    Color? primaryLight,
    Color? secondary,
    Color? accent,
    Color? gold,
    Color? correct,
    Color? wrong,
    Color? bg,
    Color? surface,
    Color? surfaceAlt,
    Color? text,
    Color? textMuted,
    Color? divider,
  }) {
    return AppPalette(
      primary: primary ?? this.primary,
      primaryLight: primaryLight ?? this.primaryLight,
      secondary: secondary ?? this.secondary,
      accent: accent ?? this.accent,
      gold: gold ?? this.gold,
      correct: correct ?? this.correct,
      wrong: wrong ?? this.wrong,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      text: text ?? this.text,
      textMuted: textMuted ?? this.textMuted,
      divider: divider ?? this.divider,
    );
  }

  @override
  AppPalette lerp(AppPalette? other, double t) {
    if (other == null) return this;
    return AppPalette(
      primary: Color.lerp(primary, other.primary, t)!,
      primaryLight: Color.lerp(primaryLight, other.primaryLight, t)!,
      secondary: Color.lerp(secondary, other.secondary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      gold: Color.lerp(gold, other.gold, t)!,
      correct: Color.lerp(correct, other.correct, t)!,
      wrong: Color.lerp(wrong, other.wrong, t)!,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
    );
  }
}

/// 便捷扩展：从 BuildContext 取当前主题色板。
extension AppColorsContext on BuildContext {
  AppPalette get appColors =>
      Theme.of(this).extension<AppPalette>() ?? AppPalettePresets.warmLight;
}

/// 预设色板 — 每个主题两个 seed（亮/暗），经 fromSeed 生成。
/// 对应原生 Hermes 的 5 套主题。
abstract final class AppPalettePresets {
  /// 青绿
  static final AppPalette tealLight =
      AppPalette.fromSeed(const Color(0xFF00897B), isDark: false);
  static final AppPalette tealDark =
      AppPalette.fromSeed(const Color(0xFF4DB6AC), isDark: true);

  /// 靛蓝
  static final AppPalette indigoLight =
      AppPalette.fromSeed(const Color(0xFF3F51B5), isDark: false);
  static final AppPalette indigoDark =
      AppPalette.fromSeed(const Color(0xFF7986CB), isDark: true);

  /// 暖橙
  static final AppPalette warmLight =
      AppPalette.fromSeed(const Color(0xFFE65100), isDark: false);
  static final AppPalette warmDark =
      AppPalette.fromSeed(const Color(0xFFFFB74D), isDark: true);

  /// 紫罗兰
  static final AppPalette violetLight =
      AppPalette.fromSeed(const Color(0xFF7B1FA2), isDark: false);
  static final AppPalette violetDark =
      AppPalette.fromSeed(const Color(0xFFBA68C8), isDark: true);

  /// 玫瑰
  static final AppPalette roseLight =
      AppPalette.fromSeed(const Color(0xFFC2185B), isDark: false);
  static final AppPalette roseDark =
      AppPalette.fromSeed(const Color(0xFFF06292), isDark: true);

  /// 旧名兼容（warm 默认浅色）。
  static final AppPalette warm = warmLight;
}
