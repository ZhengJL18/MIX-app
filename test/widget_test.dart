import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:mix_app/theme/app_palette.dart';
import 'package:mix_app/theme/app_theme.dart';

void main() {
  testWidgets('主题色板预设有效', (WidgetTester tester) async {
    // 所有预设色板都应包含完整语义色
    for (final palette in AppTheme.palettes.values) {
      expect(palette.primary, isNotNull);
      expect(palette.bg, isNotNull);
      expect(palette.surface, isNotNull);
      expect(palette.text, isNotNull);
      expect(palette.textMuted, isNotNull);
      expect(palette.divider, isNotNull);
    }
  });

  testWidgets('AppTheme 可构建 light/dark', (WidgetTester tester) async {
    for (final id in AppThemeId.values) {
      final light = AppTheme.build(id, brightness: Brightness.light);
      final dark = AppTheme.build(id, brightness: Brightness.dark);
      expect(light.scaffoldBackgroundColor, isNotNull);
      expect(dark.scaffoldBackgroundColor, isNotNull);
    }
  });

  testWidgets('AppPalette lerp 不崩溃', (WidgetTester tester) async {
    final a = AppPalettePresets.warm;
    final b = AppPalettePresets.night;
    final mixed = a.lerp(b, 0.5);
    expect(mixed.primary, isNotNull);
  });
}
