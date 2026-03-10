import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_config.dart';

/// Пузырёк сообщения с отображением статуса верификации подписи.
///
/// ИЗМЕНЕНИЯ v6:
/// - Отображение иконки верификации подписи (✓ зелёная / ⚠ красная)
/// - Поддержка TTL (исчезающие сообщения) — показывает оставшееся время
/// - Индикатор пересылки (forwarded_from)
class MessageBubble extends StatelessWidget {
  final Map<String, dynamic> message;
  final bool   isMine;
  final String myUid;
  final String chatWith;
  final bool   isGroup;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onForward;
  final Function(String emoji)? onReaction;
  final Map<String, String> reactions;
  final Map<String, dynamic>? replyMessage;

  /// Результат верификации подписи:
  /// - null: подпись не проверялась (нет ключа контакта)
  /// - true: подпись верна
  /// - false: подпись не прошла проверку (⚠️ MITM или повреждение)
  final bool? signatureVerified;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    required this.myUid,
    required this.chatWith,
    this.isGroup = false,
    this.onReply,
    this.onDelete,
    this.onEdit,
    this.onForward,
    this.onReaction,
    this.reactions = const {},
    this.replyMessage,
    this.signatureVerified,
  });

  @override
  Widget build(BuildContext context) {
    final text      = message['text'] as String? ?? '';
    final time      = _formatTime(message['time']);
    final status    = message['status'] as String? ?? '';
    final isEdited  = message['isEdited'] == true;
    final fromUid   = message['from_uid'] as String?;
    final forwarded = message['forwarded_from'] as String?;
    final ttl       = message['ttl_seconds'] as int?;

    return GestureDetector(
      onLongPress: () => _showContextMenu(context),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isMine
                ? const Color(0xFF1A3A5C)
                : const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.only(
              topLeft:     const Radius.circular(16),
              topRight:    const Radius.circular(16),
              bottomLeft:  Radius.circular(isMine ? 16 : 4),
              bottomRight: Radius.circular(isMine ? 4 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Имя отправителя в группе
              if (isGroup && !isMine && fromUid != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    fromUid,
                    style: TextStyle(
                      color: Colors.cyan.shade300,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

              // Индикатор пересылки
              if (forwarded != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.reply, size: 12, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(
                        'Переслано от $forwarded',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ),

              // Reply preview
              if (replyMessage != null)
                Container(
                  padding: const EdgeInsets.all(6),
                  margin: const EdgeInsets.only(bottom: 4),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: Colors.cyan.shade400, width: 2),
                    ),
                    color: Colors.white.withOpacity(0.05),
                  ),
                  child: Text(
                    replyMessage!['text'] as String? ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                ),

              // Текст сообщения
              Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),

              const SizedBox(height: 4),

              // Футер: время + статус + подпись + TTL
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Время
                  Text(
                    time,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                  ),

                  // "изменено"
                  if (isEdited) ...[
                    const SizedBox(width: 4),
                    Text(
                      'ред.',
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
                    ),
                  ],

                  // TTL indicator
                  if (ttl != null && ttl > 0) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.timer, size: 10, color: Colors.orange.shade300),
                    const SizedBox(width: 2),
                    Text(
                      AppConfig.formatTtl(ttl),
                      style: TextStyle(color: Colors.orange.shade300, fontSize: 10),
                    ),
                  ],

                  // Верификация подписи
                  if (!isMine) ...[
                    const SizedBox(width: 4),
                    _buildSignatureIcon(),
                  ],

                  // Статус доставки (для моих сообщений)
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    _buildStatusIcon(status),
                  ],
                ],
              ),

              // Реакции
              if (reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 4,
                    children: _buildReactionChips(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Иконка верификации подписи.
  Widget _buildSignatureIcon() {
    if (signatureVerified == null) {
      // Подпись не проверялась
      return Tooltip(
        message: 'Подпись не проверена',
        child: Icon(Icons.help_outline, size: 12, color: Colors.grey.shade600),
      );
    } else if (signatureVerified == true) {
      return const Tooltip(
        message: 'Подпись верифицирована ✓',
        child: Icon(Icons.verified, size: 12, color: Colors.green),
      );
    } else {
      // signatureVerified == false — КРИТИЧЕСКОЕ ПРЕДУПРЕЖДЕНИЕ
      return const Tooltip(
        message: '⚠️ ПОДПИСЬ НЕ ВЕРНА! Сообщение может быть подделано.',
        child: Icon(Icons.warning, size: 14, color: Colors.red),
      );
    }
  }

  Widget _buildStatusIcon(String status) {
    switch (status) {
      case 'sent':
        return Icon(Icons.check, size: 12, color: Colors.grey.shade500);
      case 'delivered':
        return Icon(Icons.done_all, size: 12, color: Colors.grey.shade500);
      case 'read':
        return const Icon(Icons.done_all, size: 12, color: Colors.cyan);
      case 'failed':
        return const Icon(Icons.error_outline, size: 12, color: Colors.red);
      default:
        return Icon(Icons.schedule, size: 12, color: Colors.grey.shade600);
    }
  }

  List<Widget> _buildReactionChips() {
    // Группируем по эмодзи
    final Map<String, int> counts = {};
    for (final emoji in reactions.values) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }
    return counts.entries.map((e) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '${e.key} ${e.value}',
          style: const TextStyle(fontSize: 12),
        ),
      );
    }).toList();
  }

  void _showContextMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onReply != null)
                ListTile(
                  leading: const Icon(Icons.reply, color: Colors.white70),
                  title: const Text('Ответить', style: TextStyle(color: Colors.white)),
                  onTap: () { Navigator.pop(ctx); onReply!(); },
                ),
              if (onForward != null)
                ListTile(
                  leading: const Icon(Icons.forward, color: Colors.white70),
                  title: const Text('Переслать', style: TextStyle(color: Colors.white)),
                  onTap: () { Navigator.pop(ctx); onForward!(); },
                ),
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white70),
                title: const Text('Копировать', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  Clipboard.setData(ClipboardData(text: message['text'] ?? ''));
                },
              ),
              if (isMine && onEdit != null)
                ListTile(
                  leading: const Icon(Icons.edit, color: Colors.white70),
                  title: const Text('Редактировать', style: TextStyle(color: Colors.white)),
                  onTap: () { Navigator.pop(ctx); onEdit!(); },
                ),
              if (isMine && onDelete != null)
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: const Text('Удалить', style: TextStyle(color: Colors.red)),
                  onTap: () { Navigator.pop(ctx); onDelete!(); },
                ),
              // Реакции
              if (onReaction != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: ['👍', '❤️', '😂', '😮', '😢', '🔥'].map((emoji) {
                      return GestureDetector(
                        onTap: () { Navigator.pop(ctx); onReaction!(emoji); },
                        child: Text(emoji, style: const TextStyle(fontSize: 28)),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  String _formatTime(dynamic raw) {
    try {
      late DateTime dt;
      if (raw is int) {
        dt = DateTime.fromMillisecondsSinceEpoch(raw);
      } else if (raw is String) {
        dt = DateTime.parse(raw);
      } else {
        return '';
      }
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}
