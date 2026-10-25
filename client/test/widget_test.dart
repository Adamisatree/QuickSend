import 'package:flutter_test/flutter_test.dart';
import 'package:quicksend_native/main.dart';

void main() {
  testWidgets('renders the native QuickSend dashboard', (tester) async {
    await tester.pumpWidget(const QuickSendApp());
    await tester.pump();
    expect(find.text('Send files'), findsWidgets);
    expect(find.text('Connect devices'), findsOneWidget);
  });
}
