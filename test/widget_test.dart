import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mix_app/main.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    // Mock SharedPreferences so that AppEntry sees onboarding as complete
    SharedPreferences.setMockInitialValues({
      'onboarding_complete': true,
      'ai_vendor': 'deepseek',
      'ai_model': 'deepseek-chat',
      'api_key': 'test-key',
      'identity': 'collegeEngineer',
    });

    await tester.pumpWidget(const MixApp());
    await tester.pumpAndSettle();

    expect(find.text('Mix'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('刷题'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
  });
}
