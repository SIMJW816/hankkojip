import 'package:flutter/material.dart';

import 'api.dart';
import 'ingredient_jar.dart';

class _Message {
  _Message(this.text, {this.user = false, this.recipe, this.foods = const []});
  final String text;
  final bool user;
  final Map<String, dynamic>? recipe;
  final List<String> foods;
}

/// 음식 추천과 양념 배합을 같은 대화에서 이어 갑니다.
class AiDemoChat extends StatefulWidget {
  const AiDemoChat({
    super.key,
    this.api,
    this.real = false,
    required this.onReview,
  });
  final Api? api;
  final bool real;
  final void Function(Map<String, dynamic>) onReview;

  @override
  State<AiDemoChat> createState() => _AiDemoChatState();
}

class _AiDemoChatState extends State<AiDemoChat> {
  final input = TextEditingController();
  final scroll = ScrollController();
  final messages = <_Message>[
    _Message('안녕하세요! 오늘 먹을 음식이나 양념 배합을 함께 정해요. 무엇이 궁금하세요?'),
  ];
  final history = <Map<String, String>>[];
  Map<String, dynamic>? currentRecipe;
  bool busy = false;

  @override
  void didUpdateWidget(covariant AiDemoChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != null && oldWidget.api?.base != widget.api?.base) {
      history.clear();
      currentRecipe = null;
      input.clear();
      messages
        ..clear()
        ..add(_Message('서버가 변경되어 새 대화를 시작합니다.'));
    }
  }

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  void add(
    String text, {
    bool user = false,
    Map<String, dynamic>? recipe,
    List<String> foods = const [],
  }) {
    setState(() {
      messages.add(_Message(text, user: user, recipe: recipe, foods: foods));
    });
    scrollToLatest();
  }

  void scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> send([String? choice]) async {
    final text = (choice ?? input.text).trim();
    if (busy || text.isEmpty) return;
    if (text.length > 500) {
      add('메시지는 500자 이내로 입력해 주세요.');
      return;
    }
    input.clear();
    add(text, user: true);
    final api = widget.api;
    if (api == null) {
      input.text = text;
      add('상단 설정에서 Flask 서버를 연결한 뒤 다시 보내 주세요.');
      return;
    }
    setState(() => busy = true);
    scrollToLatest();
    try {
      final response = await api.call(
        '/ai/chat',
        method: 'POST',
        body: {
          'message': text,
          'history': history.toList(),
          'current_recipe': currentRecipe,
        },
      );
      if (!mounted || widget.api?.base != api.base) return;
      final reply = response['message'] as String;
      final recipe = response['recipe'] as Map<String, dynamic>?;
      final foods = (response['foods'] as List).cast<String>();
      final options = foods
          .asMap()
          .entries
          .map((entry) => '${entry.key + 1}. ${entry.value}')
          .join(' / ');
      final replyContext = options.isEmpty
          ? reply
          : '${String.fromCharCodes(reply.runes.take(1200))}\n추천 음식: $options';
      history.addAll([
        {'role': 'user', 'content': text},
        {
          'role': 'assistant',
          'content': String.fromCharCodes(replyContext.runes.take(1500)),
        },
      ]);
      if (history.length > 12) history.removeRange(0, history.length - 12);
      while (history.length > 2 &&
          history.fold<int>(
                0,
                (sum, entry) => sum + entry['content']!.runes.length,
              ) >
              6000) {
        history.removeRange(0, 2);
      }
      if (recipe != null) currentRecipe = recipe;
      add(reply, recipe: recipe, foods: foods);
    } catch (e) {
      if (mounted && widget.api?.base == api.base) {
        input.text = text;
        add('답변을 불러오지 못했어요: $e\n입력한 메시지를 확인하고 다시 보내 주세요.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void reset() {
    setState(() {
      messages.clear();
      history.clear();
      currentRecipe = null;
      input.clear();
    });
    add('새 대화를 시작할게요. 오늘 먹을 음식이나 양념을 물어보세요.');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final choices = currentRecipe == null
        ? ['오늘 뭐 먹지?', '양념 배합 만들기']
        : ['덜 짜게 해줘', '대체 재료 알려줘'];
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI 배합 도우미',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text('음식 추천부터 양념 배합까지 대화해 보세요.'),
                    TextButton.icon(
                      onPressed: busy ? null : reset,
                      icon: const Icon(Icons.refresh),
                      label: const Text('새 대화'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final m = messages[index];
                    return Align(
                      alignment: m.user
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        constraints: const BoxConstraints(maxWidth: 560),
                        decoration: BoxDecoration(
                          color: m.user
                              ? colors.primaryContainer
                              : colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              m.user ? '나' : '한꼬집',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(m.text),
                            if (m.foods.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                children: m.foods
                                    .map(
                                      (food) => ActionChip(
                                        label: Text(food),
                                        onPressed: busy
                                            ? null
                                            : () => send(food),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                            if (m.recipe != null) ...[
                              const Divider(),
                              Text(
                                '${m.recipe!['name']} · ${m.recipe!['servings']}인분',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              ...(m.recipe!['items'] as List).map(
                                (i) => Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 40,
                                        height: 40,
                                        child: FittedBox(
                                          child: IngredientJar(
                                            color: slotColor(i['slot']),
                                            ingredientName:
                                                i['name'] as String?,
                                            liquid: i['kind'] == 'liquid',
                                            registered: true,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '${i['slot']} · ${i['name']}',
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${(i['grams'] as num).toStringAsFixed(1)} g',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (identical(m.recipe, currentRecipe))
                                FilledButton(
                                  onPressed: widget.api == null || busy
                                      ? null
                                      : () => widget.onReview(m.recipe!),
                                  child: Text(
                                    widget.real
                                        ? '배합 확인 · 저장 / 실계량'
                                        : '배합 확인 · 저장 / 데모 계량',
                                  ),
                                )
                              else
                                const Text('이전 배합 제안'),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (busy)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Flexible(child: Text('AI가 답변을 준비하고 있어요…')),
                        ],
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: choices
                      .map(
                        (c) => ActionChip(
                          label: Text(c),
                          onPressed: busy ? null : () => send(c),
                        ),
                      )
                      .toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: input,
                        enabled: !busy,
                        maxLength: 500,
                        minLines: 1,
                        maxLines: 3,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => send(),
                        decoration: const InputDecoration(
                          labelText: '메시지',
                          hintText: '음식이나 양념에 대해 물어보세요',
                          counterText: '',
                        ),
                      ),
                    ),
                    IconButton.filled(
                      onPressed: busy ? null : () => send(),
                      icon: const Icon(Icons.send),
                      tooltip: '메시지 보내기',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
