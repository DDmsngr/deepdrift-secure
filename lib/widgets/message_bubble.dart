import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/chat_models.dart';
import 'video_players.dart';
import 'package:url_launcher/url_launcher.dart';

// ─── MessageBubble ─────────────────────────────────────────────────────────────
//
// StatefulWidget с поддержкой свайпа справа налево → ответить.
// Остальная логика делегируется в ChatScreen через колбэки.
//
class MessageBubble extends StatefulWidget {
  final Map<String, dynamic>         msg;
  final String                       myUid;
  final String?                      playingMessageId;
  final Map<String, Set<String>>     reactions;

  final void Function(Map<String, dynamic>)          onLongPress;
  final void Function(Map<String, dynamic>)          onRetryDownload;
  final void Function(Map<String, dynamic>)          onPlayVoice;
  final void Function(String filePath)               onOpenImage;
  final void Function(String? filePath, String name) onOpenFile;
  final void Function(String msgId, String emoji)    onRemoveReaction;
  final void Function(Map<String, dynamic>)?         onReply;   // ← свайп-ответ
  final void Function(String url)?                     onDeepLink; // deepdrift:// ссылки
  final String? senderName; // имя отправителя для групповых сообщений

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
    this.onReply,
    this.onDeepLink,
    this.senderName,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {

  // ── Свайп-to-reply (справа налево) ────────────────────────────────────────
  double _dragOffset    = 0.0;
  bool   _replyFired    = false;

  static const double _triggerAt   = 64.0;   // порог активации
  static const double _maxDrag     = 80.0;   // максимальный сдвиг
  static const double _iconShowAt  = 16.0;   // с какого смещения видна иконка

  late AnimationController _snapCtrl;
  late Animation<double>   _snapAnim;

  @override
  void initState() {
    super.initState();
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250));
    _snapAnim = const AlwaysStoppedAnimation(0);
    _snapCtrl.addListener(() {
      if (mounted) setState(() => _dragOffset = _snapAnim.value);
    });
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (d.primaryDelta == null || d.primaryDelta! > 0) return; // только ←
    final next = (_dragOffset + d.primaryDelta!).clamp(-_maxDrag, 0.0);
    setState(() => _dragOffset = next);

    if (!_replyFired && next <= -_triggerAt) {
      _replyFired = true;
      HapticFeedback.mediumImpact();
    }
  }

  void _onDragEnd(DragEndDetails _) {
    if (_replyFired) widget.onReply?.call(widget.msg);
    _replyFired = false;

    _snapAnim = Tween<double>(begin: _dragOffset, end: 0).animate(
      CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));
    _snapCtrl.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final isMe         = widget.msg['from'] == widget.myUid;
    final msgType      = (widget.msg['type'] as String? ?? 'text').toMsgType();
    final msgId        = widget.msg['id']?.toString() ?? '';
    final msgReactions = widget.reactions[msgId] ?? {};

    // Прогресс свайпа 0→1 (для анимации иконки)
    final swipePct = ((-_dragOffset - _iconShowAt) / (_triggerAt - _iconShowAt))
        .clamp(0.0, 1.0);

    return GestureDetector(
      onLongPress: () => widget.onLongPress(widget.msg),
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd:    _onDragEnd,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // ── Иконка ответа (справа, появляется при свайпе) ────────────────
          if (_dragOffset < -_iconShowAt)
            Positioned(
              right: 10,
              top: 0, bottom: 0,
              child: Center(
                child: Opacity(
                  opacity: swipePct,
                  child: Transform.scale(
                    scale: 0.5 + 0.5 * swipePct,
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D9FF)
                            .withValues(alpha: 0.15 + 0.2 * swipePct),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF00D9FF)
                              .withValues(alpha: 0.4 + 0.6 * swipePct),
                          width: 1.5,
                        ),
                      ),
                      child: Icon(Icons.reply_rounded,
                          color: Color.lerp(
                              const Color(0xFF00D9FF).withValues(alpha: 0.5),
                              const Color(0xFF00D9FF),
                              swipePct),
                          size: 18),
                    ),
                  ),
                ),
              ),
            ),

          // ── Bubble со смещением ────────────────────────────────────────────
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
                child: Column(
                  crossAxisAlignment:
                      isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    // ── Пузырь ─────────────────────────────────────────────
                    Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
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
                            blurRadius: 4, offset: const Offset(0, 2)),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Имя отправителя в групповых сообщениях
                          if (!isMe && widget.senderName != null) ...[
                            Text(
                              widget.senderName!,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF00D9FF),
                              ),
                            ),
                            const SizedBox(height: 2),
                          ],
                          // Forwarded label
                          if (widget.msg['forwardedFrom'] != null) ...[
                            Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.forward, size: 13,
                                  color: isMe ? Colors.white70
                                      : Colors.cyanAccent.withValues(alpha: 0.8)),
                              const SizedBox(width: 4),
                              Flexible(child: Text(
                                'Переслано от ${widget.msg['forwardedFrom']}',
                                style: TextStyle(fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                    color: isMe ? Colors.white70
                                        : Colors.cyanAccent.withValues(alpha: 0.8)),
                                maxLines: 1, overflow: TextOverflow.ellipsis,
                              )),
                            ]),
                            const SizedBox(height: 4),
                          ],

                          // Reply preview
                          if (widget.msg['replyTo'] != null) ...[
                            Container(
                              padding: const EdgeInsets.all(8),
                              margin:  const EdgeInsets.only(bottom: 6),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.25),
                                borderRadius: BorderRadius.circular(8),
                                border: const Border(
                                    left: BorderSide(
                                        color: Colors.cyanAccent, width: 3)),
                              ),
                              child: Text(
                                widget.msg['replyTo'] as String,
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.65),
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic),
                                maxLines: 2, overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],

                          // Содержимое
                          _buildContent(msgType, isMe),
                          const SizedBox(height: 4),

                          // Нижняя строка: edited + время + статус + подпись
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            if (widget.msg['edited'] == true)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Text('изм.',
                                    style: TextStyle(color: Colors.white54,
                                        fontSize: 10,
                                        fontStyle: FontStyle.italic)),
                              ),
                            Text(formatMessageTime(widget.msg['time']),
                                style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 11)),
                            if (isMe) ...[
                              const SizedBox(width: 4),
                              _buildStatusIcon(
                                  widget.msg['status'] as String?),
                            ],
                            if (!isMe) ...[
                              const SizedBox(width: 4),
                              _buildSignatureIcon(context),
                            ],
                          ]),
                        ],
                      ),
                    ),

                    // Реакции
                    if (msgReactions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 4,
                          children: msgReactions.map((emoji) =>
                            GestureDetector(
                              onTap: () =>
                                  widget.onRemoveReaction(msgId, emoji),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1A1F3C),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: Colors.cyan
                                          .withValues(alpha: 0.4)),
                                ),
                                child: Text(emoji,
                                    style:
                                        const TextStyle(fontSize: 14)),
                              ),
                            )).toList(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Контент ───────────────────────────────────────────────────────────────

  Widget _buildContent(MsgType msgType, bool isMe) {
    switch (msgType) {
      case MsgType.image:
        return _buildImage();
      case MsgType.voice:
        return _buildVoice(isMe);
      case MsgType.file:
        return _buildFile(isMe);
      case MsgType.video_note:
        return widget.msg['filePath'] != null
            ? VideoNotePlayer(filePath: widget.msg['filePath'] as String)
            : _retryButton(Icons.videocam_rounded, 'Видеокружок');
      case MsgType.video_gallery:
        return widget.msg['filePath'] != null
            ? VideoGalleryPlayer(filePath: widget.msg['filePath'] as String)
            : _retryButton(Icons.video_file_rounded, 'Видео из галереи');
      default:
        return _buildTextWithLinks(widget.msg['text'] as String? ?? '');
    }
  }

  // ── Текст со ссылками ────────────────────────────────────────────────────

  Widget _buildTextWithLinks(String text) {
    // Ищем deepdrift:// и https?:// ссылки
    final linkRegex = RegExp(r'(deepdrift://[\S]+|https?://[\S]+)', caseSensitive: false);
    final matches = linkRegex.allMatches(text);

    if (matches.isEmpty) {
      return SelectableText(text,
          style: const TextStyle(color: Colors.white, fontSize: 15));
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final m in matches) {
      // Текст до ссылки
      if (m.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, m.start),
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ));
      }

      final url = m.group(0)!;
      final isDeepLink = url.startsWith('deepdrift://');

      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () async {
            final uri = Uri.tryParse(url);
            if (uri == null) return;
            if (isDeepLink) {
              // Обрабатываем внутри приложения
              if (uri.host == 'channel') {
                final channelId = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
                if (channelId != null) widget.onDeepLink?.call(url);
              }
            } else {
              if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          child: Text(
            isDeepLink ? '🔗 Открыть канал' : url,
            style: TextStyle(
              color: isDeepLink ? const Color(0xFF00D9FF) : Colors.lightBlueAccent,
              fontSize: 15,
              decoration: TextDecoration.underline,
              decorationColor: isDeepLink ? const Color(0xFF00D9FF) : Colors.lightBlueAccent,
            ),
          ),
        ),
      ));

      lastEnd = m.end;
    }

    // Остаток текста
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ));
    }

    return Text.rich(TextSpan(children: spans));
  }

  // ── Изображение ───────────────────────────────────────────────────────────

  Widget _buildImage() {
    final localPath = widget.msg['filePath'] as String?;
    if (localPath != null && File(localPath).existsSync()) {
      return GestureDetector(
        onTap: () => widget.onOpenImage(localPath),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(File(localPath), width: 200, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _imagePlaceholder()),
        ),
      );
    }
    if (widget.msg['mediaData'] != null) {
      final mediaStr = widget.msg['mediaData'] as String;
      if (mediaStr.startsWith('FILE_ID:') &&
          widget.msg['fileExpired'] == true) {
        return _expiredPlaceholder();
      }
      return _retryButton(Icons.image_rounded, 'Изображение');
    }
    return _imagePlaceholder();
  }

  Widget _imagePlaceholder() => Container(
    width: 200, height: 120,
    decoration: BoxDecoration(color: Colors.black26,
        borderRadius: BorderRadius.circular(8)),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const Icon(Icons.broken_image, color: Colors.white38, size: 40),
      if (widget.msg['fileName'] != null)
        Text(widget.msg['fileName'] as String,
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
    ]),
  );

  Widget _expiredPlaceholder() => Container(
    width: 200, height: 80,
    decoration: BoxDecoration(color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12)),
    child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(Icons.timer_off_outlined, color: Colors.white24, size: 28),
      SizedBox(height: 4),
      Text('Файл удалён с сервера',
          style: TextStyle(color: Colors.white24, fontSize: 11)),
    ]),
  );

  // ── Голосовое ─────────────────────────────────────────────────────────────

  Widget _buildVoice(bool isMe) {
    final localPath = widget.msg['filePath'] as String?;
    if ((localPath == null || !File(localPath).existsSync()) &&
        widget.msg['mediaData'] != null) {
      return _retryButton(Icons.mic_rounded, 'Голосовое сообщение');
    }
    final isPlaying   = widget.playingMessageId == widget.msg['id']?.toString();
    final accentColor = isMe ? Colors.white : const Color(0xFF00D9FF);
    final durationSec = widget.msg['duration'] as int?;
    final durationStr = durationSec != null
        ? '${(durationSec ~/ 60).toString().padLeft(1, '0')}:${(durationSec % 60).toString().padLeft(2, '0')}'
        : null;

    // Генерируем псевдо-волну из id сообщения (детерминировано, выглядит живо)
    final seed = (widget.msg['id']?.toString() ?? '0').hashCode;
    final bars = List.generate(28, (i) {
      final h = 0.25 + 0.75 * ((seed * (i + 1) * 2654435761) & 0xFF) / 255.0;
      return h;
    });

    return GestureDetector(
      onTap: () => widget.onPlayVoice(widget.msg),
      child: SizedBox(
        width: 220,
        child: Row(children: [
          // Кнопка play/pause
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: accentColor.withValues(alpha: 0.5)),
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: accentColor, size: 24,
            ),
          ),
          const SizedBox(width: 8),
          // Волна + время
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Псевдо-волна
                SizedBox(
                  height: 28,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: bars.map((h) {
                      return Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 0.8),
                          height: 28 * h,
                          decoration: BoxDecoration(
                            color: isPlaying
                                ? accentColor
                                : accentColor.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isPlaying ? 'Воспроизведение...' : 'Голосовое',
                      style: TextStyle(
                        color: accentColor.withValues(alpha: 0.8),
                        fontSize: 10,
                      ),
                    ),
                    if (durationStr != null)
                      Text(
                        durationStr,
                        style: const TextStyle(color: Colors.white54, fontSize: 10),
                      )
                    else if (widget.msg['fileSize'] != null)
                      Text(
                        formatFileSize(widget.msg['fileSize']),
                        style: const TextStyle(color: Colors.white54, fontSize: 10),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  // ── Файл ──────────────────────────────────────────────────────────────────

  Widget _buildFile(bool isMe) {
    final fileName      = widget.msg['fileName'] as String? ?? 'file';
    final mimeType      = widget.msg['mimeType'] as String?;
    final fileSize      = widget.msg['fileSize'];
    final filePath      = widget.msg['filePath'] as String?;
    final fileAvailable = filePath != null && File(filePath).existsSync();

    return GestureDetector(
      onTap: () => widget.onOpenFile(filePath, fileName),
      child: Container(
        constraints: const BoxConstraints(minWidth: 180),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: (isMe ? Colors.white : Colors.cyan)
                  .withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: Colors.cyan.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(iconForMime(mimeType),
                color: Colors.cyanAccent, size: 26),
          ),
          const SizedBox(width: 10),
          Flexible(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(fileName,
                  style: const TextStyle(color: Colors.white, fontSize: 13,
                      fontWeight: FontWeight.w600),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              if (fileSize != null)
                Text(formatFileSize(fileSize),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11)),
              Text(
                fileAvailable ? 'Нажми чтобы открыть' : 'Файл недоступен',
                style: TextStyle(
                    color: fileAvailable
                        ? Colors.cyanAccent
                        : Colors.white30,
                    fontSize: 11),
              ),
            ],
          )),
        ]),
      ),
    );
  }

  // ── Retry кнопка ─────────────────────────────────────────────────────────

  Widget _retryButton(IconData icon, String label) {
    return GestureDetector(
      onTap: () => widget.onRetryDownload(widget.msg),
      child: Container(
        width: 180,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.cyan.withValues(alpha: 0.4)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.cyan, size: 28),
          const SizedBox(width: 10),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
              const Text('Нажми для загрузки',
                  style: TextStyle(color: Colors.cyan, fontSize: 11)),
            ],
          )),
          const Icon(Icons.download_rounded, color: Colors.cyan, size: 20),
        ]),
      ),
    );
  }

  // ── Статус доставки ───────────────────────────────────────────────────────

  Widget _buildStatusIcon(String? status) {
    switch (status) {
      case 'read':      return const Icon(Icons.done_all,      size: 14, color: Colors.cyanAccent);
      case 'delivered': return const Icon(Icons.done_all,      size: 14, color: Colors.white54);
      case 'sent':      return const Icon(Icons.check,         size: 14, color: Colors.white54);
      case 'pending':   return const Icon(Icons.access_time,   size: 14, color: Colors.white38);
      case 'failed':    return const Icon(Icons.error_outline,  size: 14, color: Colors.redAccent);
      default:          return const SizedBox.shrink();
    }
  }

  // ── Ed25519 иконка верификации ────────────────────────────────────────────

  Widget _buildSignatureIcon(BuildContext context) {
    final statusIndex = widget.msg['signatureStatus'] as int?;
    final status = statusIndex != null
        ? SignatureStatus.values[statusIndex]
        : SignatureStatus.unknown;

    final (icon, color, tooltip) = switch (status) {
      SignatureStatus.valid   => (Icons.lock,          Colors.greenAccent, 'Подпись верна'),
      SignatureStatus.invalid => (Icons.warning_amber, Colors.orange,      'Подпись неверна — возможна подмена'),
      SignatureStatus.unknown => (Icons.lock_clock,    Colors.white24,     'Подпись не проверена'),
    };

    return GestureDetector(
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tooltip),
        backgroundColor:
            status == SignatureStatus.invalid ? Colors.orange : Colors.blueGrey,
        duration: const Duration(seconds: 3),
      )),
      child: Icon(icon, size: 12, color: color),
    );
  }
}
