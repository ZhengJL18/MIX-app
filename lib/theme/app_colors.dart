import 'package:flutter/material.dart';
import 'app_palette.dart';

/// 全局活动色板 — 由 AppTheme 切换时更新。
/// AppColors.xxx 均从当前活动色板动态读取，全局跟随主题。
class AppColors {
  AppColors._();

  /// 当前激活的色板（默认 warm，App 启动时由主题系统设置）。
  static AppPalette palette = AppPalettePresets.warm;

  // ─── 品牌主色 ───
  static Color get primary => palette.primary;
  static Color get primaryLight => palette.primaryLight;
  static Color get secondary => palette.secondary;
  static Color get accent => palette.accent;
  static Color get gold => palette.gold;

  // ─── 语义色 ───
  static Color get correct => palette.correct;
  static Color get wrong => palette.wrong;

  // ─── 背景/表面 ───
  static Color get lightBg => palette.bg;
  static Color get lightSurface => palette.surface;
  static Color get lightSurfaceAlt => palette.surfaceAlt;

  // ─── 文字 ───
  static Color get lightText => palette.text;
  static Color get lightTextMuted => palette.textMuted;

  // ─── 分割线 ───
  static Color get lightDivider => palette.divider;

  // ─── 深色模式兼容（旧引用，映射到同一色板） ───
  static Color get darkBg => palette.bg;
  static Color get darkSurface => palette.surface;
  static Color get darkSurfaceAlt => palette.surfaceAlt;
  static Color get darkText => palette.text;
  static Color get darkTextMuted => palette.textMuted;
  static Color get darkDivider => palette.divider;
}
