import 'dart:io';
import 'package:flutter/material.dart';
import '../models/chat_models.dart';
import 'video_players.dart';

// ─── MessageBubble ────────────────────────────────────────────────────────────
//
// Самодостаточный StatelessWidget. Не знает ни о ChatScreen, ни о сервисах.
// Всё необходимое получает через явные параметры и колбэки.
// Это делает виджет легко тестируемым и переиспользуемым.
//
class MessageBubble extends StatelessWidget {
  final Map<String, dynamic>  msg;
  final String                myUid;
  final String?               playingMessageId;
  final Map<String, Set<String>> reactions;

  // Колбэки → делегируем действия в ChatScreen
  final void Function(Map<String, dynamic>)         onLongPress;
  final void Function(Map<String, dynamic>)         onRetryDownload;
  final void Function(Map<String, dynamic>)         onPlayVoice;
  final void Function(String filePath)              onOpenImage;
  final void Function(String? filePath, String name) onOpenFile;
  final void Function(String msgId, String emoji)   onRemoveReaction;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.myUid,
    required this.playingMessageId,
    required this.reactions,
    required this.onLongPress,
    required this.onRetryDownload,
    required this.onPlayVoice,
    required this.onOpenImage,
    required this.onOpenFile,
    required this.onRemoveReaction,
  });

  @override
  Widget build(BuildContext context) {
    final isMe      = msg['from'] == myUid;
    final msgType   = (msg['type'] as String? ?? 'text').toMsgType();
    final msgId     = msg['id']?.toString() ?? '';
    final msgReactions = reactions[msgId] ?? {};

    return GestureDetector(
      onLongPress: () => onLongPress(msg),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
          child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // ── Пузырь ───────────────────────────────────────────────────
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  gradient: isMe
                      ? const LinearGradient(
                          colors: [Color(0xFF00D4FF), Color(0xFF0099CC)])
                      : null,
                  color: isMe ? null : const Color(0xFF1A1F3C),
                  borderRadius: BorderRadius.only(
                    topLeft:     const Radius.circular(12),
                    topRight:    const Radius.circular(12),
                    bottomLeft:  Radius.circular(isMe ? 12 : 2),
                    bottomRight: Radius.circular(isMe ? 2 : 12),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Forwarded label
                    if (msg['forwardedFrom'] != null) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.forward,
                              size: 13,
                              color: isMe
                                  ? Colors.white70
                                  : Colors.cyanAccent.withValues(alpha: 0.8)),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Переслано от ${msg['forwardedFrom']}',
                              style: TextStyle(
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                color: isMe
                                    ? Colors.white70
                                    : Colors.cyanAccent.withValues(alpha: 0.8),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],

                    // Reply preview
                    if (msg['replyTo'] != null) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin:  const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(8),
                          border: const Border(
                            left: BorderSide(color: Colors.cyanAccent, width: 3)),
                        ),
                        child: Text(
                          msg['replyTo'] as String,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],

                    // Содержимое
                    _buildContent(msgType, isMe),
                    const SizedBox(height: 4),

                    // Нижняя строка: edited + время + статус + подпись
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg['edited'] == true)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Text(
                              'изм.',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 10,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        Text(
                          formatMessageTime(msg['time']),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 11,
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 4),
                          _buildStatusIcon(msg['status'] as String?),
                        ],
                        if (!isMe) ...[
                          const SizedBox(width: 4),
                          _buildSignatureIcon(context),
                        ],
                      ],
                    ),
                  ],
                ),
              ),

              // Реакции
              if (msgReactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: msgReactions.map((emoji) => GestureDetector(
                      onTap: () => onRemoveReaction(msgId, emoji),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1F3C),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.cyan.withValues(alpha: 0.4)),
                        ),
                        child: Text(emoji, style: const TextStyle(fontSize: 14)),
                      ),
                    )).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Выбор типа контента ───────────────────────────────────────────────────

  Widget _buildContent(MsgType msgType, bool isMe) {
    switch (msgType) {
      case MsgType.image:
        return _buildImage();
      case MsgType.voice:
        return _buildVoice(isMe);
      case MsgType.file:
        return _buildFile(isMe);
      case MsgType.video_note:
        return (msg['filePath'] != null)
            ? VideoNotePlayer(filePath: msg['filePath'] as String)
            : _retryButton(Icons.videocam_rounded, 'Видеокружок');
      case MsgType.video_gallery:
        return (msg['filePath'] != null)
            ? VideoGalleryPlayer(filePath: msg['filePath'] as String)
            : _retryButton(Icons.video_file_rounded, 'Видео из галереи');
      default:
        return Text(
          msg['text'] as String? ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 15),
        );
    }
  }

  // ── Изображение ───────────────────────────────────────────────────────────

  Widget _buildImage() {
    final localPath = msg['filePath'] as String?;
    if (localPath != null && File(localPath).existsSync()) {
      return GestureDetector(
        onTap: () => onOpenImage(localPath),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            File(localPath),
            width: 200,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _imagePlaceholder(),
          ),
        ),
      );
    }
    if (msg['mediaData'] != null) return _retryButton(Icons.image_rounded, 'Изображение');
    return _imagePlaceholder();
  }

  Widget _imagePlaceholder() => Container(
    width: 200, height: 120,
    decoration: BoxDecoration(
      color: Colors.black26, borderRadius: BorderRadius.circular(8)),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.broken_image, color: Colors.white38, size: 40),
        if (msg['fileName'] != null)
          Text(msg['fileName'] as String,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ],
    ),
  );

  // ── Голосовое ─────────────────────────────────────────────────────────────

  Widget _buildVoice(bool isMe) {
    final localPath = msg['filePath'] as String?;
    if ((localPath == null || !File(localPath).existsSync()) &&
        msg['mediaData'] != null) {
      return _retryButton(Icons.mic_rounded, 'Голосовое сообщение');
    }
    final isPlaying = playingMessageId == msg['id']?.toString();
    return GestureDetector(
      onTap: () => onPlayVoice(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isPlaying ? Icons.pause_circle : Icons.play_circle,
            color: isMe ? Colors.white : Colors.cyanAccent,
            size: 36,
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Голосовое',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
              if (msg['fileSize'] != null)
                Text(
                  formatFileSize(msg['fileSize']),
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Файл ──────────────────────────────────────────────────────────────────

  Widget _buildFile(bool isMe) {
    final fileName = msg['fileName'] as String? ?? 'file';
    final mimeType = msg['mimeType'] as String?;
    final fileSize = msg['fileSize'];
    final filePath = msg['filePath'] as String?;
    final fileAvailable = filePath != null && File(filePath).existsSync();

    return GestureDetector(
      onTap: () => onOpenFile(filePath, fileName),
      child: Container(
        constraints: const BoxConstraints(minWidth: 180),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: (isMe ? Colors.white : Colors.cyan).withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.cyan.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(iconForMime(mimeType), color: Colors.cyanAccent, size: 26),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fileName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (fileSize != null)
                    Text(formatFileSize(fileSize),
                        style: const TextStyle(color: Colors.white54, fontSize: 11)),
                  Text(
                    fileAvailable ? 'Нажми чтобы открыть' : 'Файл недоступен',
                    style: TextStyle(
                      color: fileAvailable ? Colors.cyanAccent : Colors.white30,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Кнопка повторной загрузки ─────────────────────────────────────────────

  Widget _retryButton(IconData icon, String label) {
    return GestureDetector(
      onTap: () => onRetryDownload(msg),
      child: Container(
        width: 180,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.cyan.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.cyan, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(color: Colors.white, fontSize: 13)),
                  const Text('Нажми для загрузки',
                      style: TextStyle(color: Colors.cyan, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.download_rounded, color: Colors.cyan, size: 20),
          ],
        ),
      ),
    );
  }

  // ── Иконка статуса доставки ───────────────────────────────────────────────

  Widget _buildStatusIcon(String? status) {
    switch (status) {
      case 'read':      return const Icon(Icons.done_all,     size: 14, color: Colors.cyanAccent);
      case 'delivered': return const Icon(Icons.done_all,     size: 14, color: Colors.white54);
      case 'sent':      return const Icon(Icons.check,        size: 14, color: Colors.white54);
      case 'pending':   return const Icon(Icons.access_time,  size: 14, color: Colors.white38);
      case 'failed':    return const Icon(Icons.error_outline, size: 14, color: Colors.redAccent);
      default:          return const SizedBox.shrink();
    }
  }

  // ── Иконка верификации Ed25519-подписи ────────────────────────────────────

  Widget _buildSignatureIcon(BuildContext context) {
    final statusIndex = msg['signatureStatus'] as int?;
    final status = statusIndex != null
        ? SignatureStatus.values[statusIndex]
        : SignatureStatus.unknown;

    final (icon, color, tooltip) = switch (status) {
      SignatureStatus.valid   => (Icons.lock,         Colors.greenAccent, 'Подпись верна'),
      SignatureStatus.invalid => (Icons.warning_amber, Colors.orange,     'Подпись неверна — возможна подмена'),
      SignatureStatus.unknown => (Icons.lock_clock,   Colors.white24,     'Подпись ещё не проверена'),
    };

    return GestureDetector(
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tooltip),
          backgroundColor:
              status == SignatureStatus.invalid ? Colors.orange : Colors.blueGrey,
          duration: const Duration(seconds: 3),
        ),
      ),
      child: Icon(icon, size: 12, color: color),
    );
  }
}
