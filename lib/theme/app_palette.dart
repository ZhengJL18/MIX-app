import 'package:flutter/material.dart';

/// 统一色板 — ThemeExtension，随主题切换。
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
      Theme.of(this).extension<AppPalette>() ?? AppPalettePresets.warm;
}

/// 预设色板。
abstract final class AppPalettePresets {
  /// 暖橙（现在的多邻国暖色风格）
  static const AppPalette warm = AppPalette(
    primary: Color(0xFFFF6B35),
    primaryLight: Color(0xFFFFF0E8),
    secondary: Color(0xFFFFB347),
    accent: Color(0xFFFF4D6D),
    gold: Color(0xFFFFD700),
    correct: Color(0xFF4ECDC4),
    wrong: Color(0xFFFF6B6B),
    bg: Color(0xFFFFF8F0),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFFFF0E0),
    text: Color(0xFF2D1810),
    textMuted: Color(0xFF8B7355),
    divider: Color(0xFFE8DDD0),
  );

  /// 冷蓝（清爽学习风）
  static const AppPalette cool = AppPalette(
    primary: Color(0xFF4A90E2),
    primaryLight: Color(0xFFE8F1FC),
    secondary: Color(0xFF5EC8C0),
    accent: Color(0xFF7C6FE0),
    gold: Color(0xFFF5B841),
    correct: Color(0xFF3EB489),
    wrong: Color(0xFFE25563),
    bg: Color(0xFFF4F8FC),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEAF2FA),
    text: Color(0xFF1A2733),
    textMuted: Color(0xFF5E7A94),
    divider: Color(0xFFDCE8F2),
  );

  /// 深棕（暖棕黑）
  static const AppPalette midnight = AppPalette(
    primary: Color(0xFFFF7A50),
    primaryLight: Color(0xFF3D2218),
    secondary: Color(0xFFFFC36B),
    accent: Color(0xFFFF6D8A),
    gold: Color(0xFFFFD700),
    correct: Color(0xFF5BD6CD),
    wrong: Color(0xFFFF7B7B),
    bg: Color(0xFF1A0F0A),
    surface: Color(0xFF2D1810),
    surfaceAlt: Color(0xFF3D2218),
    text: Color(0xFFFFF0E8),
    textMuted: Color(0xFFA09080),
    divider: Color(0xFF3D2D20),
  );

  /// 黑夜（纯黑科技风）
  static const AppPalette night = AppPalette(
    primary: Color(0xFF6C8CFF),
    primaryLight: Color(0xFF1E2340),
    secondary: Color(0xFF00C2A8),
    accent: Color(0xFFFF5C8A),
    gold: Color(0xFFFFC940),
    correct: Color(0xFF00D4A0),
    wrong: Color(0xFFFF6B6B),
    bg: Color(0xFF0B0E14),
    surface: Color(0xFF161A24),
    surfaceAlt: Color(0xFF1F2533),
    text: Color(0xFFECEFF5),
    textMuted: Color(0xFF7C86A0),
    divider: Color(0xFF2A3040),
  );
}

