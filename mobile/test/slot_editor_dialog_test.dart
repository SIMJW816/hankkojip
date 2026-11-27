import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hankkojip/slot_editor_dialog.dart';

void main() {
  for (final save in [true, false]) {
    testWidgets('재료 수정 ${save ? '저장' : '취소'} 후 닫기 애니메이션', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      Map<String, dynamic>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => const SlotEditorDialog(
                      slot: {'id': 'P1', 'name': '소금', 'available': 1},
                    ),
                  );
                },
                child: const Text('수정'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('수정'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '설탕');
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(save ? '저장' : '취소'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result, save ? {'name': '설탕', 'available': true} : isNull);
    });
  }
}
