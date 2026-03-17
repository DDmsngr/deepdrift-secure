import 'dart:io';
import 'package:flutter/material.dart';
import '../models/chat_models.dart';
import 'video_players.dart';
import 'package:url_launcher/url_launcher.dart';

// ─── MessageBubble ─────────────────────────────────────────────────────────────
//
// StatelessWidget: отрисовка одного сообщения.
// Свайп-to-reply реализован внешней _SwipeToReply-обёрткой в ChatScreen.
// Долгое нажатие → onLongPress (контекстное меню с реакциями).
//
class MessageBubble extends StatelessWidget {
  final Map<String, dynamic>         msg;
  final String                       myUid;
  final String?                      playingMessageId;
  final Duration                     voicePosition;
  final Duration                     voiceDuration;
  final Map<String, Set<String>>     reactions;

  final void Function(Map<String, dynamic>)          onLongPress;
  final void Function(Map<String, dynamic>)          onRetryDownload;
  final void Function(Map<String, dynamic>)          onPlayVoice;
  final void Function(Duration position)?            onSeekVoice;
  final void Function(String filePath)               onOpenImage;
  final void Function(String? filePath, String name) onOpenFile;
  final void Function(String msgId, String emoji)    onRemoveReaction;
  final void Function(String url)?                   onDeepLink;
  final String? senderName;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.myUid,
    required this.playingMessageId,
    this.voicePosition = Duration.zero,
    this.voiceDuration = Duration.zero,
    required this.reactions,
    required this.onLongPress,
    required this.onRetryDownload,
    required this.onPlayVoice,
    this.onSeekVoice,
    required this.onOpenImage,
    required this.onOpenFile,
    required this.onRemoveReaction,
    this.onDeepLink,
    this.senderName,
  });

  @override
  Widget build(BuildContext context) {
    final isMe         = msg['from'] == myUid;
    final msgType      = (msg['type'] as String? ?? 'text').toMsgType();
    final msgId        = msg['id']?.toString() ?? '';
    final msgReactions = reactions[msgId] ?? {};
    final isSticker    = (msg['type'] as String? ?? '') == 'sticker';

    return GestureDetector(
      onLongPress: () => onLongPress(msg),
      behavior: HitTestBehavior.opaque,
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              // ── Пузырь (прозрачный для стикеров) ────────────────────
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75),
                padding: isSticker
                    ? const EdgeInsets.symmetric(vertical: 4)
                    : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: isSticker ? null : BoxDecoration(
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
                    if (!isMe && senderName != null) ...[
                      Text(
                        senderName!,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00D9FF),
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    // Forwarded label
                    if (msg['forwardedFrom'] != null) ...[
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.forward, size: 13,
                            color: isMe ? Colors.white70
                                : Colors.cyanAccent.withValues(alpha: 0.8)),
                        const SizedBox(width: 4),
                        Flexible(child: Text(
                          'Переслано от ${msg['forwardedFrom']}',
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
                    if (msg['replyTo'] != null) ...[
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (msg['replyToSender'] != null)
                              Text(
                                msg['replyToSender'] as String,
                                style: const TextStyle(
                                  color: Colors.cyanAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            Text(
                              msg['replyTo'] as String,
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.65),
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Содержимое
                    _buildContent(context, msgType, isMe),
                    const SizedBox(height: 4),

                    // Нижняя строка: edited + время + статус + подпись
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (msg['edited'] == true)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Text('изм.',
                              style: TextStyle(color: Colors.white54,
                                  fontSize: 10,
                                  fontStyle: FontStyle.italic)),
                        ),
                      Text(formatMessageTime(msg['time']),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 11)),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        _buildStatusIcon(msg['status'] as String?),
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
                        onTap: () => onRemoveReaction(msgId, emoji),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A1F3C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: Colors.cyan.withValues(alpha: 0.4)),
                          ),
                          child: Text(emoji,
                              style: const TextStyle(fontSize: 14)),
                        ),
                      ),
                    ).toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Контент ───────────────────────────────────────────────────────────────

  Widget _buildContent(BuildContext context, MsgType msgType, bool isMe) {
    switch (msgType) {
      case MsgType.image:
        return _buildImage();
      case MsgType.voice:
        return _buildVoice(isMe);
      case MsgType.file:
        return _buildFile(isMe);
      case MsgType.video_note:
        return msg['filePath'] != null
            ? VideoNotePlayer(filePath: msg['filePath'] as String)
            : _retryButton(Icons.videocam_rounded, 'Видеокружок');
      case MsgType.video_gallery:
        return msg['filePath'] != null
            ? VideoGalleryPlayer(filePath: msg['filePath'] as String)
            : _retryButton(Icons.video_file_rounded, 'Видео из галереи');
      default:
        final rawType = msg['type'] as String? ?? 'text';
        if (rawType == 'sticker') {
          final text = msg['text'] as String? ?? '';
          // Картиночный стикер: "sticker:ghost/ghost_cool"
          if (text.startsWith('sticker:')) {
            final path = text.substring(8); // "ghost/ghost_cool"
            return Image.asset(
              'assets/stickers/$path.webp',
              width: 128, height: 128,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => Text(text, style: const TextStyle(fontSize: 32)),
            );
          }
          // Эмоджи стикер
          return Text(text, style: const TextStyle(fontSize: 64));
        }
        return _buildTextWithLinks(msg['text'] as String? ?? '');
    }
  }

  // ── Текст со ссылками ────────────────────────────────────────────────────
  // Обычный Text вместо SelectableText — долгое нажатие не конфликтует
  // с контекстным меню. Копирование — через меню действий.

  Widget _buildTextWithLinks(String text) {
    final linkRegex = RegExp(r'(deepdrift://[\S]+|https?://[\S]+)', caseSensitive: false);
    final matches = linkRegex.allMatches(text);

    if (matches.isEmpty) {
      return Text(text,
          style: const TextStyle(color: Colors.white, fontSize: 15));
    }

    // Собираем HTTP(S) ссылки для превью
    final httpUrls = <String>[];

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final m in matches) {
      if (m.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, m.start),
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ));
      }

      final url = m.group(0)!;
      final isDeepLink = url.startsWith('deepdrift://');
      if (!isDeepLink) httpUrls.add(url);

      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: GestureDetector(
          onTap: () async {
            final uri = Uri.tryParse(url);
            if (uri == null) return;
            if (isDeepLink) {
              if (uri.host == 'channel') {
                final channelId = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
                if (channelId != null) onDeepLink?.call(url);
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

    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ));
    }

    // Показываем превью для первой HTTP(S) ссылки
    if (httpUrls.isNotEmpty) {
      final previewUrl = httpUrls.first;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: spans)),
          const SizedBox(height: 6),
          _buildLinkPreview(previewUrl),
        ],
      );
    }

    return Text.rich(TextSpan(children: spans));
  }

  Widget _buildLinkPreview(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return const SizedBox.shrink();
    final domain = uri.host.replaceFirst('www.', '');
    final path = uri.path.length > 1 ? uri.path : '';
    // Очищаем path от лишних символов в конце (пунктуация)
    final cleanPath = path.length > 40 ? '${path.substring(0, 40)}...' : path;

    return GestureDetector(
      onTap: () async {
        if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Favicon через Google API
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(
                'https://www.google.com/s2/favicons?domain=$domain&sz=32',
                width: 24, height: 24,
                errorBuilder: (_, __, ___) => Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: Colors.cyan.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.language, size: 16, color: Colors.cyan),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(domain,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (cleanPath.isNotEmpty)
                    Text(cleanPath,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.open_in_new, size: 14, color: Colors.white.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }

  // ── Изображение ───────────────────────────────────────────────────────────

  Widget _buildImage() {
    final localPath = msg['filePath'] as String?;
    if (localPath != null && File(localPath).existsSync()) {
      return GestureDetector(
        onTap: () => onOpenImage(localPath),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(File(localPath), width: 200, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _imagePlaceholder()),
        ),
      );
    }
    if (msg['mediaData'] != null) {
      final mediaStr = msg['mediaData'] as String;
      if (mediaStr.startsWith('FILE_ID:') &&
          msg['fileExpired'] == true) {
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
      if (msg['fileName'] != null)
        Text(msg['fileName'] as String,
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
    final localPath = msg['filePath'] as String?;
    if ((localPath == null || !File(localPath).existsSync()) &&
        msg['mediaData'] != null) {
      return _retryButton(Icons.mic_rounded, 'Голосовое сообщение');
    }
    final isPlaying   = playingMessageId == msg['id']?.toString();
    final accentColor = isMe ? Colors.white : const Color(0xFF00D9FF);
    final durationSec = msg['duration'] as int?;

    // Прогресс воспроизведения (0..1)
    final progress = isPlaying && voiceDuration.inMilliseconds > 0
        ? (voicePosition.inMilliseconds / voiceDuration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // Время: текущая позиция / общая длительность
    String timeStr;
    if (isPlaying && voiceDuration.inMilliseconds > 0) {
      timeStr = '${_fmtDur(voicePosition)} / ${_fmtDur(voiceDuration)}';
    } else if (durationSec != null) {
      timeStr = '${(durationSec ~/ 60).toString().padLeft(1, '0')}:${(durationSec % 60).toString().padLeft(2, '0')}';
    } else {
      timeStr = msg['fileSize'] != null ? formatFileSize(msg['fileSize']) : '';
    }

    // Волна
    final waveformStr = msg['waveform'] as String?;
    List<double> bars;
    if (waveformStr != null && waveformStr.isNotEmpty) {
      bars = waveformStr.split(',').map((s) => double.tryParse(s) ?? 0.3).toList();
      if (bars.length < 28) bars.addAll(List.filled(28 - bars.length, 0.2));
      if (bars.length > 28) bars = bars.sublist(0, 28);
    } else {
      final seed = (msg['id']?.toString() ?? '0').hashCode;
      bars = List.generate(28, (i) => 0.25 + 0.75 * ((seed * (i + 1) * 2654435761) & 0xFF) / 255.0);
    }

    return GestureDetector(
      onTap: () => onPlayVoice(msg),
      child: SizedBox(
        width: 230,
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Волна с прогрессом (закрашенные столбики до позиции)
                SizedBox(
                  height: 28,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List.generate(bars.length, (i) {
                      final barProgress = i / bars.length;
                      final isPast = isPlaying && barProgress <= progress;
                      return Expanded(
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 0.8),
                          height: 28 * bars[i],
                          decoration: BoxDecoration(
                            color: isPast
                                ? accentColor
                                : accentColor.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                // Ползунок (только при воспроизведении)
                if (isPlaying && voiceDuration.inMilliseconds > 0)
                  SizedBox(
                    height: 18,
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                        activeTrackColor: accentColor,
                        inactiveTrackColor: accentColor.withValues(alpha: 0.2),
                        thumbColor: accentColor,
                      ),
                      child: Slider(
                        value: progress,
                        onChanged: (v) {
                          final pos = Duration(milliseconds: (v * voiceDuration.inMilliseconds).round());
                          onSeekVoice?.call(pos);
                        },
                      ),
                    ),
                  )
                else
                  const SizedBox(height: 4),
                // Время
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isPlaying ? 'Воспроизведение' : 'Голосовое',
                      style: TextStyle(color: accentColor.withValues(alpha: 0.8), fontSize: 10),
                    ),
                    if (timeStr.isNotEmpty)
                      Text(timeStr, style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  ],
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes.toString().padLeft(1, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Файл ──────────────────────────────────────────────────────────────────

  Widget _buildFile(bool isMe) {
    final fileName      = msg['fileName'] as String? ?? 'file';
    final mimeType      = msg['mimeType'] as String?;
    final fileSize      = msg['fileSize'];
    final filePath      = msg['filePath'] as String?;
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
      onTap: () => onRetryDownload(msg),
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
    final statusIndex = msg['signatureStatus'] as int?;
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
