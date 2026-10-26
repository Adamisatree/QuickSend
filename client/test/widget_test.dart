import 'package:flutter_test/flutter_test.dart';
import 'package:quicksend_native/main.dart';

void main() {
  testWidgets('renders the native QuickSend dashboard', (tester) async {
    await tester.pumpWidget(const QuickSendApp());
    await tester.pump();
    expect(find.text('发送文件'), findsWidgets);
    expect(find.text('连接设备'), findsOneWidget);
  });
}
