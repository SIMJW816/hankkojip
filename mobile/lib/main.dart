import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'ai_chat.dart';
import 'ingredient_jar.dart';
import 'kitchen_welcome.dart';
import 'slot_editor_dialog.dart';

void main() => runApp(const SeasoningApp());

typedef Json = Map<String, dynamic>;
Json copy(Json value) => jsonDecode(jsonEncode(value)) as Json;
String grams(dynamic value) =>
    value is num ? '${value.toStringAsFixed(2)} g' : '미측정';
String status(dynamic value) => switch (value) {
  'starting' => '시작 확인 중',
  'running' => '계량 중',
  'stopping' => '중단 요청 중',
  'unconfirmed' => '정지 확인 불가',
  'completed' => '완료',
  'stopped' => '중단',
  _ => '오류',
};

bool isActiveJob(Json job) =>
    ['starting', 'running', 'stopping', 'unconfirmed'].contains(job['status']);

class SeasoningApp extends StatelessWidget {
  const SeasoningApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '한꼬집',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff344d3d))
          .copyWith(
            primary: const Color(0xff344d3d),
            onPrimary: Colors.white,
            surface: Colors.white,
            onSurface: const Color(0xff282c28),
            outlineVariant: const Color(0xffe6e7df),
          ),
      scaffoldBackgroundColor: const Color(0xfff7f6f2),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff7f6f2),
        foregroundColor: Color(0xff344d3d),
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xffe6e7df)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          side: const BorderSide(color: Color(0xffd4dacf)),
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: Color(0xffe2e9dc),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Color(0xfff8f9f5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
    ),
    home: const Kitchen(),
  );
}

class Kitchen extends StatefulWidget {
  const Kitchen({super.key});
  @override
  State<Kitchen> createState() => _KitchenState();
}

class _KitchenState extends State<Kitchen> with WidgetsBindingObserver {
  final address = TextEditingController(
    text: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://127.0.0.1:8000',
    ),
  );
  final controlKey = TextEditingController();
  Api? api;
  Json? data;
  String? error;
  bool busy = false, polling = false, foreground = true;
  int tab = 0;
  bool favoritesOnly = false;
  Timer? timer;
  List<Json> rows(String key) => (data?[key] as List? ?? []).cast<Json>();
  Json get device => (data?['device'] as Json?) ?? {};
  bool get usesArduino => device['mode'] == 'uart';

  String get deviceStatus {
    if (!usesArduino) return '데모 모드 · 장치 미연결';
    if (device['connected'] != true) return 'Arduino 미연결';
    if (device['error'] case final String reason) return reason;
    return device['ready'] == true
        ? 'Arduino 계량 준비 완료'
        : 'Arduino 연결됨 · 준비 또는 계량 중';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    connect();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (api != null && foreground && !busy && !polling) refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && api != null) refresh();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    address.dispose();
    controlKey.dispose();
    super.dispose();
  }

  void message(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> connect() async {
    try {
      final next = Api(address.text.trim(), controlKey: controlKey.text.trim());
      final state = await next.call('/state');
      if (mounted) {
        setState(() {
          api = next;
          data = state;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    }
  }

  Future<void> refresh() async {
    if (polling) return;
    polling = true;
    final current = api;
    try {
      final state = await current!.call('/state');
      if (mounted && current == api) {
        setState(() {
          data = state;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && current == api) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      polling = false;
    }
  }

  Future<void> perform(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      message(e);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> settings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('서버 연결'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('앱과 Flask 서버를 같은 시험망에 연결하고 서버 주소를 입력하세요.'),
              const SizedBox(height: 16),
              TextField(
                controller: address,
                onChanged: (_) => controlKey.clear(),
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Flask 서버 주소'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controlKey,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '실계량 제어 키'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              perform(connect);
            },
            child: const Text('연결'),
          ),
        ],
      ),
    );
  }

  Future<void> editSlot(Json slot) async {
    final result = await showDialog<Json>(
      context: context,
      builder: (_) => SlotEditorDialog(slot: slot),
    );
    if (!mounted || result == null) return;
    await perform(() async {
      await api!.call('/slots/${slot['id']}', method: 'PUT', body: result);
    });
  }

  Future<void> editor([Json? recipe]) async {
    final result = await Navigator.push<Json>(
      context,
      MaterialPageRoute(
        builder: (_) => BlendEditor(
          api: api!,
          slots: rows('slots').map(copy).toList(),
          initial: recipe,
        ),
      ),
    );
    await refresh();
    if (result != null && mounted) await approve(result);
  }

  Future<void> approve(Json recipe) async {
    final currentApi = api;
    if (currentApi == null) return;
    await refresh();
    if (!mounted || currentApi != api) return;
    if (error != null) {
      message(error!);
      return;
    }
    final real = usesArduino;
    if (real && device['ready'] != true) {
      message(deviceStatus);
      return;
    }
    // Generated once per approval session, retained on network failures/retries.
    final key = List.generate(
      24,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    bool approved = false, sending = false;
    String? failure;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !sending,
          child: AlertDialog(
            title: Text(real ? '실계량 최종 승인' : '데모 계량 최종 승인'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${recipe['name']} · ${recipe['servings']}인분'),
                    ...((recipe['items'] as List).map(
                      (i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          '${i['slot']} · ${i['name']}   ${grams(i['grams'])}',
                        ),
                      ),
                    )),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        real
                            ? '빈 컵과 목표 중량을 확인했으며, 실제 장치 작동을 승인합니다.'
                            : '목표 중량을 확인했으며 모의 계량을 승인합니다.',
                      ),
                      value: approved,
                      onChanged: sending
                          ? null
                          : (v) => update(() {
                              approved = v!;
                            }),
                    ),
                    if (failure != null)
                      Text(
                        failure!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: sending ? null : () => Navigator.pop(context),
                child: const Text('닫기'),
              ),
              FilledButton(
                onPressed: !approved || sending
                    ? null
                    : () async {
                        update(() {
                          sending = true;
                          failure = null;
                        });
                        try {
                          await currentApi.call(
                            '/jobs',
                            method: 'POST',
                            body: {
                              'approved': true,
                              'device_mode': real ? 'uart' : 'demo',
                              'request_key': key,
                              'recipe': recipe,
                            },
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                          if (mounted) {
                            setState(() {
                              tab = 3;
                            });
                          }
                          await refresh();
                        } catch (e) {
                          if (dialogContext.mounted) {
                            update(() {
                              failure = '$e';
                              sending = false;
                            });
                          }
                        }
                      },
                child: Text(sending ? '요청 중…' : '승인하고 시작'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> deleteRecipe(Json recipe) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('레시피 삭제'),
        content: Text('“${recipe['name']}”을 삭제할까요? 제조 이력은 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await perform(() async {
        await api!.call('/recipes/${recipe['id']}', method: 'DELETE');
      });
    }
  }

  Future<void> deleteHistory(Json job) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('제조 이력 삭제'),
        content: Text('“${job['name']}” 이력을 삭제할까요? 복구할 수 없으며 저장한 레시피는 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await perform(() async {
        await api!.call('/jobs/${job['id']}', method: 'DELETE');
      });
    }
  }

  Widget emptyPanel(IconData icon, String title, String description) => panel(
    SizedBox(
      width: double.infinity,
      child: Column(
        children: [
          const SizedBox(height: 12),
          CircleAvatar(
            radius: 30,
            backgroundColor: const Color(0xffeef2eb),
            child: Icon(icon, size: 30, color: const Color(0xff687d52)),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(description, textAlign: TextAlign.center),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );

  Widget panel(Widget child, {Color? color}) => Card(
    color: color,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
  @override
  Widget build(BuildContext context) {
    final recipes = rows('recipes');
    final favorites = recipes.where((r) => r['favorite'] == true).toList();
    final visibleRecipes = favoritesOnly ? favorites : recipes;
    final pages = ['우리 주방', '재료 관리', '내 레시피', '계량 · 이력', 'AI 대화'];
    return Scaffold(
      appBar: AppBar(
        title: Text('한꼬집 · ${pages[tab]}'),
        actions: [
          IconButton(
            onPressed: busy ? null : () => perform(refresh),
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
          ),
          IconButton(
            onPressed: busy ? null : settings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: '서버 연결',
          ),
        ],
      ),
      body: IndexedStack(
        index: tab == 4 ? 1 : 0,
        children: [
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    if (busy) const LinearProgressIndicator(),
                    if (error != null)
                      panel(
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('연결 오류: $error'),
                            const Text('표시된 데이터는 마지막 조회 결과입니다.'),
                            TextButton(
                              onPressed: settings,
                              child: const Text('서버 주소 설정'),
                            ),
                          ],
                        ),
                      ),
                    if (data == null && error == null)
                      const Center(child: CircularProgressIndicator()),
                    if (data != null)
                      ...switch (tab) {
                        0 => [
                          KitchenWelcome(
                            deviceStatus: deviceStatus,
                            onCustom: busy ? null : () => editor(),
                            onAi: () => setState(() => tab = 4),
                            onNavigate: (index) => setState(() => tab = index),
                          ),
                        ],
                        1 => rows('slots').map(slotCard).toList(),
                        2 => [
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              ChoiceChip(
                                label: Text('전체 ${recipes.length}'),
                                selected: !favoritesOnly,
                                selectedColor: const Color(0xff344d3d),
                                labelStyle: TextStyle(
                                  color: !favoritesOnly
                                      ? Colors.white
                                      : const Color(0xff344d3d),
                                ),
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => favoritesOnly = false),
                              ),
                              ChoiceChip(
                                label: Text('★ 즐겨찾기 ${favorites.length}'),
                                selected: favoritesOnly,
                                selectedColor: const Color(0xff344d3d),
                                labelStyle: TextStyle(
                                  color: favoritesOnly
                                      ? Colors.white
                                      : const Color(0xff344d3d),
                                ),
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => favoritesOnly = true),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: busy ? null : () => editor(),
                            icon: const Icon(Icons.add),
                            label: const Text('새 레시피'),
                          ),
                          const SizedBox(height: 12),
                          if (visibleRecipes.isEmpty)
                            emptyPanel(
                              favoritesOnly
                                  ? Icons.star_border_rounded
                                  : Icons.menu_book_outlined,
                              favoritesOnly ? '즐겨찾기한 레시피가 없어요' : '저장한 레시피가 없어요',
                              favoritesOnly
                                  ? '전체 목록에서 자주 쓰는 레시피의 별을 눌러보세요.'
                                  : '직접 만든 배합을 나만의 레시피로 저장해 보세요.',
                            ),
                          ...visibleRecipes.map(recipeCard),
                        ],
                        _ => [
                          Text(deviceStatus),
                          if (rows('jobs').isEmpty)
                            emptyPanel(
                              Icons.scale_outlined,
                              '아직 계량 이력이 없어요',
                              '완료·중단·오류 결과를 이곳에서 확인할 수 있어요.',
                            ),
                          ...rows('jobs').where(isActiveJob).map(jobCard),
                          ...rows('jobs')
                              .where((j) => !isActiveJob(j))
                              .map(jobCard),
                        ],
                      },
                  ],
                ),
              ),
            ),
          ),
          AiDemoChat(
            api: api,
            real: usesArduino,
            onReview: (recipe) => editor(copy(recipe)),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() {
          tab = v;
        }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '홈'),
          NavigationDestination(
            icon: Icon(Icons.kitchen_outlined),
            label: '재료',
          ),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            label: '레시피',
          ),
          NavigationDestination(
            icon: Icon(Icons.scale_outlined),
            label: '계량·이력',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'AI 대화',
          ),
        ],
      ),
    );
  }

  Widget slotCard(Json slot) {
    var availability = slot['available'] == 1 ? '사용 가능' : '보충 필요';
    final atCenter = usesArduino && slot['check_at_center'] == true;
    final percent = slot['remaining_pct'];
    if (usesArduino && slot['has_level_sensor'] == false) {
      availability = '잔량 미측정';
    } else if (atCenter) {
      availability = '중앙에서 확인';
    } else if (usesArduino && slot['material_present'] == null) {
      availability = '센서 확인 불가';
    }
    if (slot['operator_available'] == 0) availability = '사용 중지';
    if (usesArduino && slot['name'] != '' && percent is int) {
      availability += ' · ${atCenter ? '마지막 잔량' : '잔량'} 약 $percent%';
    }
    final foreground = slotColor(slot['id']);
    return panel(
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: IngredientJar(
          color: foreground,
          ingredientName: slot['name'] as String,
          liquid: slot['kind'] == 'liquid',
          registered: slot['name'] != '',
        ),
        title: Text(
          '${slot['name'] == '' ? '미등록' : slot['name']}',
          style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${slot['id']} · ${slot['kind'] == 'liquid' ? '액체' : '분말'} · $availability',
        ),
        trailing: Icon(Icons.edit_outlined, color: foreground),
        onTap: busy ? null : () => editSlot(slot),
      ),
      color: Colors.white,
    );
  }

  Widget recipeCard(Json recipe) {
    final items = (recipe['items'] as List).cast<Json>();
    final total = items.fold<num>(
      0,
      (sum, item) => sum + (item['grams'] as num),
    );
    final custom = recipe['mode'] == 'CUSTOM';
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xffeef2eb),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.menu_book_outlined,
                  size: 28,
                  color: Color(0xff344d3d),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${recipe['name']}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(
                          custom ? Icons.tune : Icons.auto_awesome_outlined,
                          size: 16,
                        ),
                        Text(
                          '${custom
                              ? '직접 배합'
                              : recipe['mode'] == 'AI'
                              ? 'AI 배합'
                              : 'AI 예시 · 데모'} · ${recipe['servings']}인분',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: recipe['favorite'] == true ? '즐겨찾기 해제' : '즐겨찾기',
                icon: Icon(
                  recipe['favorite'] == true
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  color: const Color(0xffa57132),
                ),
                onPressed: busy
                    ? null
                    : () => perform(() async {
                        await api!.call(
                          '/recipes/${recipe['id']}',
                          method: 'PUT',
                          body: {
                            ...recipe,
                            'favorite': recipe['favorite'] != true,
                          },
                        );
                      }),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '재료 ${items.length}개 · 총 ${grams(total)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              // 좁은 화면과 큰 글자 설정에서는 한 열로 전환합니다.
              final singleColumn =
                  constraints.maxWidth < 280 ||
                  MediaQuery.textScalerOf(context).scale(15) > 21;
              final width = singleColumn
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 10) / 2;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: items
                    .map(
                      (item) => SizedBox(
                        width: width,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xfff8f9f5),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  SizedBox(
                                    width: 36,
                                    height: 36,
                                    child: FittedBox(
                                      child: IngredientJar(
                                        color: slotColor(item['slot']),
                                        ingredientName: item['name'] as String,
                                        liquid: item['kind'] == 'liquid',
                                        registered: true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${item['name']}',
                                      style: const TextStyle(fontSize: 15),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${item['slot']} · ${item['kind'] == 'liquid' ? '액체' : '분말'}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  grams(item['grams']),
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff344d3d),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : () => approve(copy(recipe)),
                  icon: const Icon(Icons.scale_outlined),
                  label: const Text('배합 확인 · 계량'),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '레시피 더보기',
                enabled: !busy,
                onSelected: (action) {
                  if (action == 'edit') editor(copy(recipe));
                  if (action == 'delete') deleteRecipe(recipe);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('수정'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('삭제'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget weighingItem(Json item, bool running, String readingLabel) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        IngredientJar(
          color: slotColor(item['slot']),
          ingredientName: item['name'] as String,
          liquid: item['kind'] == 'liquid',
          registered: true,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${item['name']} · ${item['slot']}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '목표 ${grams(item['grams'])} / $readingLabel ${grams(item['actual'])}',
              ),
              Text(
                item['done'] == true
                    ? '완료'
                    : running
                    ? '진행/대기'
                    : '미완료',
              ),
            ],
          ),
        ),
        Icon(
          item['done'] == true
              ? Icons.check_circle_outline
              : Icons.hourglass_empty,
          size: 20,
          color: const Color(0xff687d52),
        ),
      ],
    ),
  );

  Widget jobCard(Json job) {
    final running = isActiveJob(job);
    final real = job['demo'] == false;
    final readingLabel = real ? '실측' : '모의 계량값';
    final items = (job['items'] as List).cast<Json>();
    final target = items.fold<num>(0, (sum, i) => sum + (i['grams'] as num));
    final actual = items.every((i) => i['actual'] is num)
        ? items.fold<num>(0, (sum, i) => sum + (i['actual'] as num))
        : null;
    final (icon, color) = switch (job['status']) {
      'starting' ||
      'running' ||
      'stopping' => (Icons.scale_outlined, const Color(0xff344d3d)),
      'completed' => (Icons.check_circle_outline, const Color(0xff39765b)),
      'stopped' => (Icons.stop_circle_outlined, const Color(0xff98652d)),
      _ => (Icons.error_outline, const Color(0xffa13e32)),
    };
    final current = items.where(
      (i) => real ? i['slot'] == job['current_slot'] : i['done'] != true,
    );
    final phaseText = switch (job['phase']) {
      'taring' => '빈 컵 기준으로 영점 조정 중',
      'homing' => '분말통 이동부 원점 찾는 중',
      'positioning' => '분말통 중앙 이동 중',
      'checking' => 'ToF 센서로 분말 잔량 확인 중',
      'engaging' => '서보로 결합부 연결 중',
      'disengaging' => '배출 정지 후 결합부 복귀 중',
      'settling' => '무게 안정 대기 중',
      _ => null,
    };
    return panel(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: color.withValues(alpha: 0.1),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${job['name']}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      DateTime.fromMillisecondsSinceEpoch(
                        ((job['started'] as num) * 1000).round(),
                      ).toLocal().toString().split('.').first,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${status(job['status'])} · ${real ? '실계량' : '모의 계량'}',
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text('목표 ${grams(target)} / $readingLabel ${grams(actual)}'),
          if (job['error'] case final String reason)
            Text(reason, style: TextStyle(color: color)),
          if (job['stop_confirmed'] == false)
            Text('Arduino의 정지 결과를 확인할 수 없습니다.', style: TextStyle(color: color)),
          if (running) ...[
            const SizedBox(height: 16),
            if (phaseText != null) Text(phaseText),
            if (current.isNotEmpty)
              Text(
                '현재 계량: ${current.first['name']}'
                '${job['live_g'] is num ? ' · ${grams(job['live_g'])}' : ''}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: (job['progress'] as num) / 100),
            Text('${job['progress']}%'),
            ...items.map((i) => weighingItem(i, true, readingLabel)),
          ] else
            ExpansionTile(
              key: PageStorageKey('job-details-${job['id']}'),
              tilePadding: EdgeInsets.zero,
              title: const Text('재료별 상세 결과'),
              leading: const Icon(Icons.receipt_long_outlined),
              children: items
                  .map((i) => weighingItem(i, false, readingLabel))
                  .toList(),
            ),
          if (!running) ...[
            const Text('이력을 레시피로 저장하면 목표 중량이 복사됩니다.'),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => perform(() async {
                          await api!.call(
                            '/jobs/${job['id']}/recipe',
                            method: 'POST',
                            body: {},
                          );
                          message('내 레시피에 저장했어요.');
                        }),
                  child: const Text('내 레시피에 저장'),
                ),
                TextButton(
                  onPressed: busy ? null : () => deleteHistory(job),
                  child: const Text('이력 삭제'),
                ),
              ],
            ),
          ],
          if (running)
            OutlinedButton(
              onPressed: busy || job['status'] == 'stopping'
                  ? null
                  : () => perform(() async {
                      await api!.call(
                        '/jobs/${job['id']}/stop',
                        method: 'POST',
                        body: {},
                      );
                    }),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xffa13e32),
              ),
              child: const Text('계량 중단'),
            ),
        ],
      ),
    );
  }
}

class BlendEditor extends StatefulWidget {
  const BlendEditor({
    super.key,
    required this.api,
    required this.slots,
    this.initial,
  });
  final Api api;
  final List<Json> slots;
  final Json? initial;
  @override
  State<BlendEditor> createState() => _BlendEditorState();
}

class _BlendEditorState extends State<BlendEditor> {
  late final TextEditingController name, servings;
  final dish = TextEditingController();
  final weights = <String, TextEditingController>{};
  late List<Json> identities;
  String taste = 'balanced', mode = 'CUSTOM';
  String? id, error, aiNotice;
  bool busy = false, aiGenerating = false, favorite = false;
  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    name = TextEditingController(text: initial?['name'] ?? '나만의 양념');
    servings = TextEditingController(text: '${initial?['servings'] ?? 2}');
    id = initial?['id'];
    mode = initial?['mode'] ?? 'CUSTOM';
    favorite = initial?['favorite'] == true;
    identities = widget.slots.map(copy).toList();
    for (final s in identities) {
      final matches = (initial?['items'] as List? ?? []).where(
        (i) => i['slot'] == s['id'],
      );
      if (matches.isNotEmpty) {
        final i = matches.first;
        // Preserve stale ingredient identity so saving cannot silently rebind it.
        s.addAll({
          'name': i['name'],
          'kind': i['kind'],
          'revision': i['revision'],
        });
      }
      weights[s['id']] = TextEditingController(
        text: matches.isEmpty ? '' : '${matches.first['grams']}',
      );
    }
  }

  @override
  void dispose() {
    name.dispose();
    servings.dispose();
    dish.dispose();
    for (final c in weights.values) {
      c.dispose();
    }
    super.dispose();
  }

  Json recipe() {
    final count = int.tryParse(servings.text);
    if (name.text.trim().isEmpty ||
        name.text.trim().length > 80 ||
        count == null ||
        count < 1 ||
        count > 20) {
      throw ApiException('이름(1~80자)과 인분(1~20 정수)을 확인하세요.');
    }
    final items = <Json>[];
    for (final s in identities) {
      final text = weights[s['id']]!.text.trim();
      if (text.isEmpty) continue;
      final value = double.tryParse(text);
      if (value == null ||
          !value.isFinite ||
          value < 0 ||
          value > 100 ||
          (value > 0 && value < .1)) {
        throw ApiException('${s['id']}: 0.1~100g을 입력하거나 비워 주세요.');
      }
      if (value == 0) continue;
      final current = widget.slots.firstWhere((v) => v['id'] == s['id']);
      if (s['revision'] != current['revision'] ||
          s['name'] != current['name']) {
        throw ApiException('슬롯이 바뀐 레시피입니다. 현재 재료로 새 배합을 작성하세요.');
      }
      items.add({
        'slot': s['id'],
        'name': s['name'],
        'kind': s['kind'],
        'revision': s['revision'],
        'grams': value,
      });
    }
    if (items.isEmpty ||
        items.fold<double>(0, (sum, i) => sum + (i['grams'] as num)) > 300) {
      throw ApiException('재료를 하나 이상 선택하고 총 300g 이하로 입력하세요.');
    }
    return {
      'name': name.text.trim(),
      'servings': count,
      'mode': mode,
      'favorite': favorite,
      'items': items,
    };
  }

  Future<void> action(
    Future<void> Function() work, {
    bool generatingAi = false,
  }) async {
    if (busy) return;
    setState(() {
      busy = true;
      aiGenerating = generatingAi;
      error = null;
      if (generatingAi) aiNotice = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(() {
          if (generatingAi) {
            aiNotice = '배합을 불러오지 못했어요: $e\n기존 입력은 유지됩니다.';
          } else {
            error = '$e';
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          aiGenerating = false;
        });
      }
    }
  }

  Future<void> suggest() => action(() async {
    final result = await widget.api.call(
      '/suggestions',
      method: 'POST',
      body: {
        'dish': dish.text.trim(),
        'servings': int.tryParse(servings.text),
        'taste': taste,
      },
    );
    if (!mounted) return;
    setState(() {
      aiNotice =
          '${result['notice']}${result['recipe'] == null ? '\n기존 입력은 유지됩니다.' : ''}';
    });
    if (result['recipe'] == null) return;
    final r = result['recipe'] as Json;
    setState(() {
      name.text = r['name'];
      mode = r['mode'] as String;
      id = null;
      favorite = false;
      identities = widget.slots.map(copy).toList();
      for (final c in weights.values) {
        c.clear();
      }
      for (final i in r['items']) {
        final index = identities.indexWhere((s) => s['id'] == i['slot']);
        if (index >= 0) identities[index].addAll(Map<String, dynamic>.from(i));
        weights[i['slot']]!.text = '${i['grams']}';
      }
    });
  }, generatingAi: true);
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('배합 만들기')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'CUSTOM / AI 배합',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const Text(
                '배합 입력 범위는 재료별 0.1~100g, 총 300g 이하입니다.\n실계량은 장치에서 정한 범위를 추가로 확인합니다.',
              ),
              const SizedBox(height: 20),
              TextField(
                controller: name,
                enabled: !busy,
                maxLength: 80,
                decoration: const InputDecoration(labelText: '레시피 이름'),
              ),
              TextField(
                controller: servings,
                enabled: !busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '기준 인분 (1~20)'),
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                title: const Text('AI 배합 제안받기'),
                children: [
                  const Text('등록 재료로 AI가 배합을 제안합니다.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: dish,
                    enabled: !busy,
                    maxLength: 40,
                    decoration: const InputDecoration(labelText: '음식 이름'),
                  ),
                  DropdownButton<String>(
                    value: taste,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 'balanced', child: Text('기본')),
                      DropdownMenuItem(value: 'less-salt', child: Text('덜 짜게')),
                      DropdownMenuItem(value: 'spicy', child: Text('매콤하게')),
                    ],
                    onChanged: busy
                        ? null
                        : (v) => setState(() {
                            taste = v!;
                          }),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : suggest,
                    child: Text(aiGenerating ? '생성 중…' : 'AI 배합 생성'),
                  ),
                  if (aiGenerating)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Flexible(child: Text('AI가 배합을 만들고 있어요…')),
                          ],
                        ),
                      ),
                    )
                  else if (aiNotice != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(aiNotice!),
                      ),
                    ),
                ],
              ),
              ...identities.map(
                (s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      IngredientJar(
                        color: slotColor(s['id']),
                        ingredientName: s['name'] as String?,
                        liquid: s['kind'] == 'liquid',
                        registered: s['name'] != '',
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: weights[s['id']],
                          enabled: !busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText:
                                '${s['id']} · ${s['name'] == '' ? '미등록' : s['name']}',
                            suffixText: 'g',
                          ),
                          onChanged: (_) {
                            mode = 'CUSTOM';
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (busy && !aiGenerating) const LinearProgressIndicator(),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => action(() async {
                        final saved = await widget.api.call(
                          '/recipes${id == null ? '' : '/$id'}',
                          method: id == null ? 'POST' : 'PUT',
                          body: recipe(),
                        );
                        if (mounted && context.mounted) {
                          setState(() {
                            id = saved['id'];
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('레시피를 저장했습니다.')),
                          );
                        }
                      }),
                child: const Text('내 레시피에 저장'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => action(() async {
                        final value = recipe();
                        Navigator.pop(context, value);
                      }),
                child: const Text('배합 확인 · 계량'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
