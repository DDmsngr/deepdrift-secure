import 'package:flutter/material.dart';

/// Встроенные стикер-паки. Каждый стикер — это Unicode emoji-комбинация
/// или текстовый стикер (большой размер). Не требует сервера и интернета.
///
/// Использование в chat_screen:
///   _showStickerPicker() → выбор → _sendMessage(text: sticker, messageType: 'sticker')
///
/// В message_bubble: если type == 'sticker' — рендерим текст большим шрифтом (64px)
/// без пузыря.

class StickerPicker extends StatefulWidget {
  final void Function(String sticker, String packName) onStickerSelected;

  const StickerPicker({super.key, required this.onStickerSelected});

  @override
  State<StickerPicker> createState() => _StickerPickerState();
}

class _StickerPickerState extends State<StickerPicker> {
  int _activePackIndex = 0;

  static const _packs = <_StickerPack>[
    _StickerPack('😀 Эмоции', [
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂',
      '🙂', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗',
      '🤗', '🤭', '🤫', '🤔', '😏', '😬', '🤥', '😌',
      '😴', '🥱', '😎', '🤓', '🧐', '🥳', '🤯', '😱',
      '😤', '😡', '🤬', '😈', '👿', '💀', '👻', '🤡',
    ]),
    _StickerPack('❤️ Сердца', [
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
      '🤎', '💔', '❤️‍🔥', '❤️‍🩹', '💖', '💗', '💓', '💞',
      '💕', '💘', '💝', '💟', '🫶', '🤟', '🤙', '💪',
    ]),
    _StickerPack('🐱 Животные', [
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
      '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐧',
      '🦅', '🦋', '🐛', '🐝', '🐢', '🐍', '🦎', '🐙',
      '🦈', '🐬', '🐳', '🐠', '🦩', '🦜', '🐓', '🦔',
    ]),
    _StickerPack('🍕 Еда', [
      '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓',
      '🍒', '🍑', '🥭', '🍍', '🍕', '🍔', '🌭', '🍟',
      '🌮', '🌯', '🍣', '🍱', '🍩', '🎂', '🧁', '☕',
      '🍺', '🍷', '🥂', '🧋', '🥤', '🍵', '🧃', '🍾',
    ]),
    _StickerPack('✨ Символы', [
      '✨', '⭐', '🌟', '💫', '🔥', '💥', '🎉', '🎊',
      '🏆', '🥇', '🎯', '🎁', '🎈', '🎀', '🎮', '🕹️',
      '🎵', '🎶', '🎤', '📱', '💻', '🔒', '🔑', '💡',
      '⚡', '🌈', '☀️', '🌙', '⛈️', '❄️', '🌊', '🍀',
    ]),
    _StickerPack('👋 Жесты', [
      '👍', '👎', '👊', '✊', '🤛', '🤜', '👏', '🙌',
      '👐', '🤲', '🤝', '🙏', '✌️', '🤞', '🤟', '🤘',
      '🤙', '👈', '👉', '👆', '👇', '☝️', '👋', '🤚',
      '✋', '🖖', '👌', '🤌', '🖕', '💪', '🦾', '✍️',
    ]),
  ];

  @override
  Widget build(BuildContext context) {
    final pack = _packs[_activePackIndex];
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.35,
      child: Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36, height: 4,
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          // Tabs
          SizedBox(
            height: 40,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _packs.length,
              itemBuilder: (_, i) {
                final isActive = i == _activePackIndex;
                final icon = _packs[i].stickers.first;
                return GestureDetector(
                  onTap: () => setState(() => _activePackIndex = i),
                  child: Container(
                    width: 44, height: 36,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: isActive ? const Color(0xFF00D9FF).withValues(alpha: 0.15) : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border: isActive
                          ? Border.all(color: const Color(0xFF00D9FF).withValues(alpha: 0.4))
                          : null,
                    ),
                    child: Center(child: Text(icon, style: TextStyle(fontSize: isActive ? 22 : 18))),
                  ),
                );
              },
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          // Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: pack.stickers.length,
              itemBuilder: (_, i) {
                final sticker = pack.stickers[i];
                return GestureDetector(
                  onTap: () => widget.onStickerSelected(sticker, pack.name),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(child: Text(sticker, style: const TextStyle(fontSize: 32))),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StickerPack {
  final String name;
  final List<String> stickers;
  const _StickerPack(this.name, this.stickers);
}
