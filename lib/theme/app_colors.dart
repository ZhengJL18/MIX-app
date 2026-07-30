import 'package:flutter/material.dart';

/// MIX 暖色高饱和色调 — 多邻国式大胆配色
class AppColors {
  AppColors._();

  // ─── 品牌主色 ───
  static const Color primary = Color(0xFFFF6B35); // 珊瑚橙
  static const Color primaryLight = Color(0xFFFFF0E8);
  static const Color secondary = Color(0xFFFFB347); // 暖琥珀
  static const Color accent = Color(0xFFFF4D6D); // 暖粉
  static const Color gold = Color(0xFFFFD700); // 金色

  // ─── 语义色 ───
  static const Color correct = Color(0xFF4ECDC4); // 青绿
  static const Color wrong = Color(0xFFFF6B6B); // 珊瑚红

  // ─── 浅色模式 ───
  static const Color lightBg = Color(0xFFFFF8F0); // 奶油白
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceAlt = Color(0xFFFFF0E0);
  static const Color lightText = Color(0xFF2D1810); // 暖深棕
  static const Color lightTextMuted = Color(0xFF8B7355); // 暖灰棕
  static const Color lightDivider = Color(0xFFE8DDD0);

  // ─── 深色模式 ───
  static const Color darkBg = Color(0xFF1A0F0A); // 暖深棕黑
  static const Color darkSurface = Color(0xFF2D1810);
  static const Color darkSurfaceAlt = Color(0xFF3D2218);
  static const Color darkText = Color(0xFFFFF0E8); // 奶白
  static const Color darkTextMuted = Color(0xFFA09080);
  static const Color darkDivider = Color(0xFF3D2D20);
}
