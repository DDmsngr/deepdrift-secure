import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../storage_service.dart';

/// Медиагалерея — отображает все фото и видео из конкретного чата в виде сетки.
class MediaGalleryScreen extends StatelessWidget {
  final String chatWith;
  final String chatName;
  final void Function(String filePath) onOpenImage;

  const MediaGalleryScreen({
    super.key,
    required this.chatWith,
    required this.chatName,
    required this.onOpenImage,
  });

  @override
  Widget build(BuildContext context) {
    final storage = StorageService();
    final media = storage.getMediaMessages(chatWith);

    // Фильтруем только те что имеют локальный файл
    final available = media.where((m) {
      final path = m['filePath'] as String?;
      return path != null && File(path).existsSync();
    }).toList().reversed.toList(); // новые сверху

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(chatName, style: GoogleFonts.orbitron(fontSize: 14)),
            Text('${available.length} медиа', style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        ),
      ),
      body: available.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.photo_library_outlined, color: Colors.white24, size: 64),
                  SizedBox(height: 12),
                  Text('Нет медиафайлов', style: TextStyle(color: Colors.white38, fontSize: 14)),
                ],
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: available.length,
              itemBuilder: (context, index) {
                final item = available[index];
                final path = item['filePath'] as String;
                final type = item['type'] as String? ?? 'image';
                final isVideo = type.contains('video');

                return GestureDetector(
                  onTap: () => onOpenImage(path),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: const Color(0xFF1A1F3C),
                            child: const Icon(Icons.broken_image, color: Colors.white24),
                          ),
                        ),
                      ),
                      if (isVideo)
                        Positioned(
                          bottom: 4, right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(Icons.play_arrow, color: Colors.white, size: 16),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
