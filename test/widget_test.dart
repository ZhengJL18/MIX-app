import 'package:flutter_test/flutter_test.dart';

import 'package:mix_app/main.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MixApp());
    expect(find.text('Mix'), findsOneWidget);
    expect(find.text('AI'), findsOneWidget);
    expect(find.text('刷题'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
  });
}
