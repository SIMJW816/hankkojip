import 'package:flutter/material.dart';

/// 재료명이 바뀌어도 슬롯별 뚜껑 색상을 유지합니다.
Color slotColor(Object? slot) => switch (slot) {
  'P1' => const Color(0xff895017),
  'P2' => const Color(0xff3d682b),
  'P3' => const Color(0xff70458b),
  'P4' => const Color(0xff993e32),
  'L1' => const Color(0xff285f91),
  'L2' => const Color(0xff226b63),
  _ => const Color(0xff344d3d),
};

/// 내용물은 재료 등록 여부만 나타내며 실제 잔량을 표시하지 않습니다.
class IngredientJar extends StatelessWidget {
  const IngredientJar({
    super.key,
    required this.color,
    this.ingredientName,
    required this.liquid,
    required this.registered,
  });

  final Color color;
  final String? ingredientName;
  final bool liquid;
  final bool registered;

  @override
  Widget build(BuildContext context) {
    final isSoySauce = ingredientName?.trim() == '간장';
    final contentsColor = isSoySauce ? const Color(0xff825137) : color;
    final bodyWidth = liquid ? 30.0 : 42.0;
    return ExcludeSemantics(
      child: SizedBox(
        width: 56,
        height: 56,
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Positioned(
              top: liquid ? 12 : 10,
              bottom: 1,
              width: bodyWidth,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xfffffdf8),
                  border: Border.all(
                    color: const Color(0xffc9c5b8),
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(liquid ? 8 : 10),
                ),
                padding: const EdgeInsets.all(3),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: registered
                      ? Container(
                          height: 27,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: contentsColor.withValues(
                              alpha: isSoySauce ? 0.35 : 0.22,
                            ),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Icon(
                            liquid ? Icons.water_drop_rounded : Icons.grain,
                            size: 18,
                            color: contentsColor,
                          ),
                        )
                      : null,
                ),
              ),
            ),
            Positioned(
              top: liquid ? 3 : 5,
              width: liquid ? 23 : 48,
              height: liquid ? 12 : 10,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: Colors.black.withValues(alpha: 0.12),
                  ),
                ),
                margin: const EdgeInsets.only(bottom: 1),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 2,
                    margin: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    color: Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
