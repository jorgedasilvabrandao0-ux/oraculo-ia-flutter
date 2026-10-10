import 'package:flutter_test/flutter_test.dart';
import 'package:oraculo_flutter/main.dart';

void main() {
  testWidgets('O app exibe o título', (tester) async {
    await tester.pumpWidget(const OraculoApp());
    expect(find.text('O ORÁCULO'), findsOneWidget);
  });
}
