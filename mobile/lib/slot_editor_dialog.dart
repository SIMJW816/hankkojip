import 'package:flutter/material.dart';

class SlotEditorDialog extends StatefulWidget {
  const SlotEditorDialog({super.key, required this.slot});

  final Map<String, dynamic> slot;

  @override
  State<SlotEditorDialog> createState() => _SlotEditorDialogState();
}

class _SlotEditorDialogState extends State<SlotEditorDialog> {
  late final name = TextEditingController(text: widget.slot['name']);
  late bool available = [
    1,
    true,
  ].contains(widget.slot['operator_available'] ?? widget.slot['available']);

  @override
  void dispose() {
    // 닫기 애니메이션까지 TextField가 사용하는 컨트롤러를 유지합니다.
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('${widget.slot['id']} 재료 수정'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: name,
          maxLength: 30,
          decoration: const InputDecoration(labelText: '재료 이름 (빈칸: 미등록)'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            widget.slot.containsKey('operator_available') ? '사용 허용' : '사용 가능',
          ),
          value: available,
          onChanged: (value) => setState(() => available = value),
        ),
        const Text('재료 이름을 변경하면 기존 레시피를 다시 확인해야 합니다.'),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, {
          'name': name.text.trim(),
          'available': available,
        }),
        child: const Text('저장'),
      ),
    ],
  );
}
