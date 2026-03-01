import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

// ─── Круглый плеер для видео-кружочков (записанных с камеры) ─────────────────
class VideoNotePlayer extends StatefulWidget {
  final String filePath;
  const VideoNotePlayer({super.key, required this.filePath});

  @override
  State<VideoNotePlayer> createState() => _VideoNotePlayerState();
}

class _VideoNotePlayerState extends State<VideoNotePlayer> {
  late VideoPlayerController _controller;
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        _controller.setLooping(true);
        _controller.setVolume(0); // Без звука по умолчанию (как в Telegram)
        if (mounted) setState(() => _isInit = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) {
      return const SizedBox(
        width: 220, height: 220,
        child: DecoratedBox(
          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black26),
          child: Center(child: CircularProgressIndicator(color: Colors.cyan)),
        ),
      );
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          _controller.setVolume(_controller.value.volume == 0 ? 1 : 0);
        });
      },
      child: SizedBox(
        // Фиксируем КВАДРАТ 220×220 — исключает растяжение в овал
        // независимо от maxWidth родительского пузыря.
        width: 220, height: 220,
        child: Stack(
          alignment: Alignment.center,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.3), width: 3),
              ),
              child: ClipOval(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width:  _controller.value.size.width,
                      height: _controller.value.size.height,
                      child:  VideoPlayer(_controller),
                    ),
                  ),
                ),
              ),
            ),
            if (_controller.value.volume > 0)
              const Positioned(
                bottom: 20,
                child: Icon(Icons.volume_up, color: Colors.white, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Прямоугольный плеер для видео из галереи ────────────────────────────────
class VideoGalleryPlayer extends StatefulWidget {
  final String filePath;
  const VideoGalleryPlayer({super.key, required this.filePath});

  @override
  State<VideoGalleryPlayer> createState() => _VideoGalleryPlayerState();
}

class _VideoGalleryPlayerState extends State<VideoGalleryPlayer> {
  late VideoPlayerController _controller;
  bool _isInit    = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.filePath))
      ..initialize().then((_) {
        _controller.setLooping(false);
        if (mounted) setState(() => _isInit = true);
      });
    _controller.addListener(() {
      if (mounted) setState(() => _isPlaying = _controller.value.isPlaying);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 220, height: 140,
          color: Colors.black26,
          child: const Center(child: CircularProgressIndicator(color: Colors.cyan)),
        ),
      );
    }

    return GestureDetector(
      onTap: () {
        setState(() {
          _isPlaying ? _controller.pause() : _controller.play();
        });
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: _controller.value.aspectRatio,
              child: VideoPlayer(_controller),
            ),
            if (!_isPlaying)
              Container(
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(10),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
              ),
            Positioned(
              bottom: 0, left: 0, right: 0,
              child: VideoProgressIndicator(
                _controller,
                allowScrubbing: true,
                colors: const VideoProgressColors(
                  playedColor: Colors.cyan,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.black26,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
