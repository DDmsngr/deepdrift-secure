import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../socket_service.dart';
import '../storage_service.dart';

/// Полноэкранный просмотр историй в стиле Instagram/WhatsApp.
/// Принимает список историй одного пользователя.
class StoryViewerScreen extends StatefulWidget {
  final String myUid;
  final String ownerUid;
  final List<Map<String, dynamic>> stories;
  final String serverUrl;

  const StoryViewerScreen({
    super.key,
    required this.myUid,
    required this.ownerUid,
    required this.stories,
    this.serverUrl = 'https://deepdrift-backend.onrender.com',
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen>
    with SingleTickerProviderStateMixin {
  final _socket  = SocketService();
  final _storage = StorageService();

  int _currentIndex = 0;
  late AnimationController _progressController;

  static const _storyDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: _storyDuration,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) _nextStory();
      });
    _startStory();
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  void _startStory() {
    if (_currentIndex >= widget.stories.length) {
      Navigator.of(context).pop();
      return;
    }
    // Отправляем "просмотрено"
    final story = widget.stories[_currentIndex];
    final storyId = story['story_id'] as String?;
    if (storyId != null && widget.ownerUid != widget.myUid) {
      _socket.viewStory(storyId);
    }
    _progressController.forward(from: 0);
  }

  void _nextStory() {
    if (_currentIndex < widget.stories.length - 1) {
      setState(() => _currentIndex++);
      _startStory();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _prevStory() {
    if (_currentIndex > 0) {
      setState(() => _currentIndex--);
      _startStory();
    } else {
      _progressController.forward(from: 0);
    }
  }

  void _onTapDown(TapDownDetails details) {
    final w = MediaQuery.of(context).size.width;
    if (details.globalPosition.dx < w * 0.3) {
      _prevStory();
    } else if (details.globalPosition.dx > w * 0.7) {
      _nextStory();
    }
  }

  void _onLongPressStart(LongPressStartDetails _) {
    _progressController.stop();
  }

  void _onLongPressEnd(LongPressEndDetails _) {
    _progressController.forward();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stories.isEmpty) return const SizedBox.shrink();
    final story = widget.stories[_currentIndex];
    final storyType = story['story_type'] as String? ?? 'text';
    final text      = story['text'] as String? ?? '';
    final mediaId   = story['media_id'] as String? ?? '';
    final bgColor   = _parseColor(story['bg_color'] as String? ?? '#1A1F3C');
    final createdAt = story['created_at'] as int? ?? 0;
    final ownerName = _storage.getContactDisplayName(widget.ownerUid);
    final viewers   = (story['viewers'] as List?)?.length ?? 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapDown: _onTapDown,
        onLongPressStart: _onLongPressStart,
        onLongPressEnd: _onLongPressEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Содержимое ──────────────────────────────────────────
            if (storyType == 'image' && mediaId.isNotEmpty)
              CachedNetworkImage(
                imageUrl: '${widget.serverUrl}/download/$mediaId',
                fit: BoxFit.contain,
                placeholder: (_, __) => Container(color: bgColor,
                    child: const Center(child: CircularProgressIndicator(color: Colors.white))),
                errorWidget: (_, __, ___) => Container(color: bgColor,
                    child: const Center(child: Icon(Icons.broken_image, color: Colors.white54, size: 64))),
              )
            else
              // Текстовая история
              Container(
                color: bgColor,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

            // ── Прогресс-бары сверху ────────────────────────────────
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 12, right: 12,
              child: Row(
                children: List.generate(widget.stories.length, (i) {
                  return Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      height: 3,
                      child: i < _currentIndex
                          ? Container(decoration: BoxDecoration(
                              color: Colors.white, borderRadius: BorderRadius.circular(2)))
                          : i == _currentIndex
                              ? AnimatedBuilder(
                                  animation: _progressController,
                                  builder: (_, __) => ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: _progressController.value,
                                      backgroundColor: Colors.white30,
                                      color: Colors.white,
                                      minHeight: 3,
                                    ),
                                  ),
                                )
                              : Container(decoration: BoxDecoration(
                                  color: Colors.white30, borderRadius: BorderRadius.circular(2))),
                    ),
                  );
                }),
              ),
            ),

            // ── Хедер: аватар + имя + время ─────────────────────────
            Positioned(
              top: MediaQuery.of(context).padding.top + 20,
              left: 12, right: 12,
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: const Color(0xFF1A1F3C),
                    child: Text(
                      ownerName.isNotEmpty ? ownerName[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.cyan, fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ownerName,
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                        Text(_timeAgo(createdAt),
                            style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                  // Кнопка закрытия
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 24),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // ── Просмотры (только для своих историй) ────────────────
            if (widget.ownerUid == widget.myUid)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 16,
                left: 0, right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.remove_red_eye, color: Colors.white54, size: 16),
                        const SizedBox(width: 6),
                        Text('$viewers', style: const TextStyle(color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),

            // Текст поверх картинки
            if (storyType == 'image' && text.isNotEmpty)
              Positioned(
                bottom: 80, left: 20, right: 20,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(text,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      textAlign: TextAlign.center),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  String _timeAgo(int ms) {
    if (ms == 0) return '';
    final diff = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (diff.inMinutes < 1) return 'только что';
    if (diff.inMinutes < 60) return '${diff.inMinutes} мин назад';
    return '${diff.inHours} ч назад';
  }
}
