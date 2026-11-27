import 'package:flutter/material.dart';

import 'ingredient_jar.dart';

/// 웹의 크림색·초록색과 양념통 모티프를 사용하는 홈 소개 카드입니다.
class KitchenWelcome extends StatelessWidget {
  const KitchenWelcome({
    super.key,
    required this.onNavigate,
    required this.onCustom,
    required this.onAi,
    required this.deviceStatus,
  });

  final ValueChanged<int> onNavigate;
  final VoidCallback? onCustom;
  final VoidCallback onAi;
  final String deviceStatus;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xffebece3),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '한꼬집 · 나의 주방',
              style: TextStyle(
                color: Color(0xff687d52),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '오늘의 양념,\n한꼬집으로',
              style: TextStyle(
                fontSize: 30,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: Color(0xff344d3d),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '등록한 재료로 나만의 배합을 준비해 보세요.',
              style: TextStyle(fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 16),
            const _KitchenArt(),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: onCustom,
                  icon: const Icon(Icons.add),
                  label: const Text('직접 배합하기'),
                ),
                OutlinedButton.icon(
                  onPressed: onAi,
                  icon: const Icon(Icons.chat_bubble_outline),
                  label: const Text('AI 배합'),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 20),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _menuButton(Icons.kitchen_outlined, '재료 관리', 1)),
          const SizedBox(width: 12),
          Expanded(child: _menuButton(Icons.menu_book_outlined, '내 레시피', 2)),
        ],
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _menuButton(Icons.scale_outlined, '제조 이력', 3)),
          const SizedBox(width: 12),
          Expanded(child: _menuButton(Icons.chat_bubble_outline, 'AI 대화', 4)),
        ],
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xfffaf0e8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          deviceStatus,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: Color(0xff895039),
          ),
        ),
      ),
    ],
  );
  Widget _menuButton(IconData icon, String label, int index) => OutlinedButton(
    onPressed: () => onNavigate(index),
    style: OutlinedButton.styleFrom(
      backgroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      side: const BorderSide(color: Color(0xffe6e7df)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 28),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15),
        ),
      ],
    ),
  );
}

/// 장식용 그림이며 실제 슬롯의 등록 상태나 잔량을 나타내지 않습니다.
class _KitchenArt extends StatelessWidget {
  const _KitchenArt();

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Center(
      child: SizedBox(
        width: 240,
        height: 94,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              bottom: 4,
              child: Container(
                width: 220,
                height: 24,
                decoration: const BoxDecoration(
                  color: Color(0xffdce1d1),
                  borderRadius: BorderRadius.all(Radius.elliptical(110, 12)),
                ),
              ),
            ),
            const Positioned(
              left: 15,
              top: 8,
              child: IngredientJar(
                color: Color(0xffb77735),
                liquid: false,
                registered: true,
              ),
            ),
            const Positioned(
              left: 77,
              top: 0,
              child: IngredientJar(
                color: Color(0xff648d4e),
                liquid: false,
                registered: true,
              ),
            ),
            const Positioned(
              right: 17,
              top: 5,
              child: IngredientJar(
                color: Color(0xff3d9589),
                liquid: true,
                registered: true,
              ),
            ),
            Positioned(
              bottom: 5,
              child: Container(
                width: 70,
                height: 29,
                decoration: BoxDecoration(
                  color: const Color(0xfffffdf8),
                  border: Border.all(
                    color: const Color(0xffc9c5b8),
                    width: 1.5,
                  ),
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(30),
                    top: Radius.circular(4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
