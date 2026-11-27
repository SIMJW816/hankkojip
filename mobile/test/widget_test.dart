import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hankkojip/api.dart';
import 'package:hankkojip/ingredient_jar.dart';
import 'package:hankkojip/main.dart';

class DelayedSuggestionApi extends Api {
  DelayedSuggestionApi() : super('http://localhost:5000');
  final result = Completer<Map<String, dynamic>>();
  int calls = 0;

  @override
  Future<Map<String, dynamic>> call(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) {
    expect(path, '/suggestions');
    calls++;
    return result.future;
  }
}

void main() {
  for (final width in [390.0, 1024.0]) {
    testWidgets('배합 입력과 검증: 화면 너비 $width', (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: BlendEditor(
            api: Api('http://localhost:5000'),
            slots: [
              {
                'id': 'P1',
                'name': '소금',
                'kind': 'powder',
                'revision': 1,
                'available': 1,
              },
            ],
          ),
        ),
      );
      await tester.tap(find.text('내 레시피에 저장'));
      await tester.pump();
      expect(find.textContaining('재료를 하나 이상'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('변경된 슬롯의 과거 레시피를 자동 재지정하지 않음', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlendEditor(
          api: Api('http://localhost:5000'),
          slots: [
            {'id': 'P1', 'name': '설탕', 'kind': 'powder', 'revision': 2},
          ],
          initial: {
            'name': '이전 배합',
            'servings': 2,
            'mode': 'CUSTOM',
            'items': [
              {
                'slot': 'P1',
                'name': '소금',
                'kind': 'powder',
                'revision': 1,
                'grams': 2,
              },
            ],
          },
        ),
      ),
    );
    await tester.ensureVisible(find.text('내 레시피에 저장'));
    await tester.tap(find.text('내 레시피에 저장'));
    await tester.pump();
    expect(find.textContaining('슬롯이 바뀐 레시피'), findsOneWidget);
  });

  testWidgets('직접 배합 AI 요청 중 입력을 잠그고 결과가 없으면 기존 입력 유지', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DelayedSuggestionApi();
    await tester.pumpWidget(
      MaterialApp(
        home: BlendEditor(
          api: api,
          slots: const [
            {
              'id': 'P1',
              'name': '소금',
              'kind': 'powder',
              'revision': 1,
              'available': 1,
            },
            {
              'id': 'L1',
              'name': '간장',
              'kind': 'liquid',
              'revision': 1,
              'available': 1,
            },
          ],
        ),
      ),
    );
    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    expect(
      tester
          .widgetList<IngredientJar>(find.byType(IngredientJar))
          .map((jar) => jar.color),
      [slotColor('P1'), slotColor('L1')],
    );
    await tester.enterText(field('P1 · 소금'), '3');
    await tester.tap(find.text('AI 배합 제안받기'));
    await tester.pumpAndSettle();
    await tester.enterText(field('음식 이름'), '볶음밥');
    await tester.tap(find.text('AI 배합 생성'));
    await tester.pump();
    expect(find.text('AI가 배합을 만들고 있어요…'), findsOneWidget);
    expect(tester.widget<TextField>(field('P1 · 소금')).enabled, isFalse);
    expect(tester.widget<TextField>(field('레시피 이름')).enabled, isFalse);
    expect(tester.widget<TextField>(field('음식 이름')).enabled, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '내 레시피에 저장'))
          .onPressed,
      isNull,
    );
    expect(api.calls, 1);
    api.result.complete({'notice': '재료가 부족해요.', 'recipe': null});
    await tester.pumpAndSettle();
    expect(find.textContaining('기존 입력은 유지됩니다.'), findsOneWidget);
    expect(tester.widget<TextField>(field('P1 · 소금')).controller!.text, '3');
    expect(tester.widget<TextField>(field('P1 · 소금')).enabled, isTrue);
  });

  for (final succeeds in [true, false]) {
    testWidgets('직접 배합 AI 요청 ${succeeds ? '완료 후 제안 적용' : '실패 후 기존 입력 유지'}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = DelayedSuggestionApi();
      await tester.pumpWidget(
        MaterialApp(
          home: BlendEditor(
            api: api,
            slots: const [
              {
                'id': 'P1',
                'name': '소금',
                'kind': 'powder',
                'revision': 1,
                'available': 1,
              },
            ],
          ),
        ),
      );
      Finder field(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      await tester.enterText(field('P1 · 소금'), '3');
      await tester.tap(find.text('AI 배합 제안받기'));
      await tester.pumpAndSettle();
      await tester.enterText(field('음식 이름'), '볶음밥');
      await tester.tap(find.text('AI 배합 생성'));
      await tester.pump();
      if (succeeds) {
        api.result.complete({
          'notice': '배합을 확인해 주세요.',
          'recipe': {
            'name': '볶음밥 양념',
            'mode': 'AI',
            'servings': 2,
            'items': [
              {
                'slot': 'P1',
                'name': '소금',
                'kind': 'powder',
                'revision': 1,
                'grams': 7,
              },
            ],
          },
        });
      } else {
        api.result.completeError(ApiException('서버에 연결할 수 없습니다.'));
      }
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('P1 · 소금'));
      expect(
        tester.widget<TextField>(field('P1 · 소금')).controller!.text,
        succeeds ? '7' : '3',
      );
      expect(tester.widget<TextField>(field('P1 · 소금')).enabled, isTrue);
      await tester.ensureVisible(find.text('AI 배합 생성'));
      expect(
        find.textContaining(succeeds ? '배합을 확인해 주세요.' : '기존 입력은 유지됩니다.'),
        findsOneWidget,
      );
      expect(find.text('AI가 배합을 만들고 있어요…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
