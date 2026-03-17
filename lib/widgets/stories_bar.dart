import 'package:flutter/material.dart';
import '../storage_service.dart';

/// Горизонтальная полоска сторис на HomeScreen (как в Instagram/WhatsApp).
/// Показывает: [+Моя] [Контакт1] [Контакт2] ...
/// Аватары с непросмотренными историями обведены цветным кольцом.
class StoriesBar extends StatelessWidget {
  final String myUid;
  final List<Map<String, dynamic>> stories; // все истории от сервера
  final VoidCallback onCreateStory;
  final void Function(String uid, List<Map<String, dynamic>> userStories) onViewStories;

  const StoriesBar({
    super.key,
    required this.myUid,
    required this.stories,
    required this.onCreateStory,
    required this.onViewStories,
  });

  @override
  Widget build(BuildContext context) {
    final storage = StorageService();

    // Группируем истории по uid
    final Map<String, List<Map<String, dynamic>>> grouped = {};
    for (final s in stories) {
      final uid = s['uid'] as String? ?? '';
      grouped.putIfAbsent(uid, () => []).add(s);
    }

    // Мои истории первыми
    final myStories = grouped.remove(myUid) ?? [];

    // Контакты у которых есть истории, сортируем: непросмотренные первыми
    final otherUids = grouped.keys.toList()
      ..sort((a, b) {
        final aUnseen = grouped[a]!.any((s) => s['viewed_by_me'] != true) ? 0 : 1;
        final bUnseen = grouped[b]!.any((s) => s['viewed_by_me'] != true) ? 0 : 1;
        return aUnseen.compareTo(bUnseen);
      });

    if (myStories.isEmpty && otherUids.isEmpty) {
      // Показываем только кнопку "Моя история"
      return SizedBox(
        height: 90,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [_buildMyStoryButton(context, myStories)],
        ),
      );
    }

    return SizedBox(
      height: 90,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: 1 + otherUids.length,
        itemBuilder: (_, i) {
          if (i == 0) return _buildMyStoryButton(context, myStories);
          final uid = otherUids[i - 1];
          final userStories = grouped[uid]!;
          final hasUnseen = userStories.any((s) => s['viewed_by_me'] != true);
          final name = storage.getContactDisplayName(uid);
          return _buildStoryAvatar(
            context, uid, name, hasUnseen,
            () => onViewStories(uid, userStories),
          );
        },
      ),
    );
  }

  Widget _buildMyStoryButton(BuildContext context, List<Map<String, dynamic>> myStories) {
    final hasMyStories = myStories.isNotEmpty;
    return GestureDetector(
      onTap: hasMyStories
          ? () => onViewStories(myUid, myStories)
          : onCreateStory,
      onLongPress: onCreateStory,
      child: Container(
        width: 64,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: hasMyStories ? const Color(0xFF00D9FF) : Colors.white24,
                      width: hasMyStories ? 2.5 : 1.5,
                    ),
                  ),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: const Color(0xFF1A1F3C),
                    child: Text(
                      'Я',
                      style: TextStyle(
                        color: hasMyStories ? const Color(0xFF00D9FF) : Colors.white54,
                        fontSize: 16, fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                if (!hasMyStories)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D9FF),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF0A0E27), width: 2),
                      ),
                      child: const Icon(Icons.add, size: 12, color: Colors.black),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              hasMyStories ? 'Моя история' : 'Добавить',
              style: const TextStyle(color: Colors.white54, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStoryAvatar(
    BuildContext context,
    String uid,
    String name,
    bool hasUnseen,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          children: [
            Container(
              width: 56, height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: hasUnseen
                    ? const LinearGradient(
                        colors: [Color(0xFF00D9FF), Color(0xFF00FF88), Color(0xFFFF6600)],
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                      )
                    : null,
                border: hasUnseen ? null : Border.all(color: Colors.white24, width: 1.5),
              ),
              padding: const EdgeInsets.all(2.5),
              child: CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFF1A1F3C),
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(color: Color(0xFF00D9FF), fontSize: 18),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name.length > 8 ? '${name.substring(0, 7)}...' : name,
              style: TextStyle(
                color: hasUnseen ? Colors.white : Colors.white54,
                fontSize: 10,
                fontWeight: hasUnseen ? FontWeight.w600 : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
