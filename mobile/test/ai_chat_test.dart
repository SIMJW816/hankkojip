import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hankkojip/ai_chat.dart';
import 'package:hankkojip/api.dart';
import 'package:hankkojip/ingredient_jar.dart';

Map<String, dynamic> recipe(double grams) => {
  'name': '덮밥 양념',
  'mode': 'AI',
  'servings': 2,
  'items': [
    {
      'slot': 'L1',
      'name': '간장',
      'kind': 'liquid',
      'revision': 4,
      'grams': grams,
    },
  ],
};

class ConversationApi extends Api {
  ConversationApi() : super('http://localhost:5000');
  final requests = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> call(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    expect(path, '/ai/chat');
    requests.add(Map<String, dynamic>.from(body!));
    switch (body['message']) {
      case '오늘 뭐 먹지?':
        return {
          'message': '이 음식은 어떠세요?',
          'foods': ['돼지고기 덮밥'],
          'recipe': null,
        };
      case '돼지고기 덮밥':
        return {'message': '몇 인분을 준비하시나요?', 'foods': [], 'recipe': null};
      case '2인분 양념 추천해줘':
        return {'message': '양념을 추천할게요.', 'foods': [], 'recipe': recipe(4)};
      default:
        return {'message': '덜 짜게 조절했어요.', 'foods': [], 'recipe': recipe(2)};
    }
  }
}

class DelayedApi extends Api {
  DelayedApi() : super('http://localhost:5000');
  final result = Completer<Map<String, dynamic>>();
  int calls = 0;

  @override
  Future<Map<String, dynamic>> call(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) {
    expect(path, '/ai/chat');
    calls++;
    return result.future;
  }
}

Future<void> sendText(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byTooltip('메시지 보내기'));
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [390.0, 1024.0]) {
    testWidgets('음식 추천 → 배합 → 후속 대화 ($width)', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ConversationApi();
      Map<String, dynamic>? reviewed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiDemoChat(api: api, onReview: (r) => reviewed = r),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(ActionChip, '오늘 뭐 먹지?'));
      await tester.pumpAndSettle();
      expect(api.requests.first['message'], '오늘 뭐 먹지?');
      await tester.tap(find.widgetWithText(ActionChip, '돼지고기 덮밥'));
      await tester.pumpAndSettle();
      expect(
        (api.requests[1]['history'] as List)[1]['content'],
        contains('1. 돼지고기 덮밥'),
      );
      expect(find.text('몇 인분을 준비하시나요?'), findsOneWidget);
      await sendText(tester, '2인분 양념 추천해줘');
      expect(find.text('L1 · 간장'), findsOneWidget);
      expect(
        tester.widget<IngredientJar>(find.byType(IngredientJar)).color,
        slotColor('L1'),
      );
      await sendText(tester, '좀 덜 짜게 해줘');
      expect(
        (api.requests.last['current_recipe']['items'] as List).first['grams'],
        4.0,
      );
      expect((api.requests.last['history'] as List).length, 6);
      expect(find.text('이전 배합 제안'), findsOneWidget);
      await tester.ensureVisible(find.text('배합 확인 · 저장 / 데모 계량'));
      await tester.tap(find.text('배합 확인 · 저장 / 데모 계량'));
      expect((reviewed?['items'] as List).first['grams'], 2.0);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('새 대화'));
      await tester.pumpAndSettle();
      expect(find.textContaining('새 대화를 시작'), findsOneWidget);
      await sendText(tester, '안녕');
      expect(api.requests.last['history'], isEmpty);
      expect(api.requests.last['current_recipe'], isNull);
    });
  }

  testWidgets('서버 미연결 안내와 메시지 보존', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AiDemoChat(onReview: (_) {})),
      ),
    );
    await sendText(tester, '오늘 뭐 먹을까?');
    expect(find.textContaining('Flask 서버를 연결'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '오늘 뭐 먹을까?',
    );
  });

  testWidgets('응답 대기 중 표시, 중복 요청 차단, 음식 추천', (tester) async {
    final api = DelayedApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiDemoChat(api: api, onReview: (_) {}),
        ),
      ),
    );
    await tester.tap(find.widgetWithText(ActionChip, '오늘 뭐 먹지?'));
    await tester.pump();
    expect(find.text('AI가 답변을 준비하고 있어요…'), findsOneWidget);
    expect(
      tester
          .widget<ActionChip>(find.widgetWithText(ActionChip, '오늘 뭐 먹지?'))
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(api.calls, 1);
    api.result.complete({
      'message': '국수는 어떠세요?',
      'foods': ['국수'],
      'recipe': null,
    });
    await tester.pumpAndSettle();
    expect(find.text('AI가 답변을 준비하고 있어요…'), findsNothing);
    expect(find.widgetWithText(ActionChip, '국수'), findsOneWidget);
    expect(find.text('배합 확인 · 저장 / 데모 계량'), findsNothing);
  });

  testWidgets('요청 실패 시 입력 보존 및 재시도 가능', (tester) async {
    final api = DelayedApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiDemoChat(api: api, onReview: (_) {}),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '오늘 뭐 먹을까?');
    await tester.tap(find.byTooltip('메시지 보내기'));
    await tester.pump();
    api.result.completeError(ApiException('연결 실패'));
    await tester.pumpAndSettle();
    expect(find.textContaining('연결 실패'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '오늘 뭐 먹을까?',
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('작은 화면에서 여러 재료와 긴 이름을 확인', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DelayedApi();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.2)),
          child: Scaffold(
            body: AiDemoChat(api: api, onReview: (_) {}),
          ),
        ),
      ),
    );
    await tester.tap(find.widgetWithText(ActionChip, '오늘 뭐 먹지?'));
    await tester.pump();
    final slots = ['P1', 'P2', 'P3', 'P4', 'L1', 'L2'];
    api.result.complete({
      'message': '배합을 확인해 주세요.',
      'foods': [],
      'recipe': {
        'name': '볶음밥 양념',
        'servings': 2,
        'items': slots
            .map(
              (slot) => {
                'slot': slot,
                'name': '길이가긴양념이름을가진등록재료',
                'kind': slot.startsWith('L') ? 'liquid' : 'powder',
                'grams': 2,
              },
            )
            .toList(),
      },
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('배합 확인 · 저장 / 데모 계량'));
    expect(find.byType(IngredientJar), findsNWidgets(6));
    expect(tester.takeException(), isNull);
  });
}
