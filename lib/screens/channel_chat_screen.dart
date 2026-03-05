import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';

import '../socket_service.dart';
import '../storage_service.dart';

/// Экран чата канала.
/// Владелец может публиковать сообщения; подписчики только читают.
class ChannelChatScreen extends StatefulWidget {
  final String myUid;
  final String channelId;

  const ChannelChatScreen({
    super.key,
    required this.myUid,
    required this.channelId,
  });

  @override
  State<ChannelChatScreen> createState() => _ChannelChatScreenState();
}

class _ChannelChatScreenState extends State<ChannelChatScreen> {
  final _socket     = SocketService();
  final _storage    = StorageService();
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();

  final List<Map<String, dynamic>> _messages = [];
  final Set<String> _messageIds = {};

  StreamSubscription? _sub;

  bool get _isOwner =>
      _storage.getSetting('channel_owner_${widget.channelId}') == widget.myUid;

  @override
  void initState() {
    super.initState();

    // Load stored messages
    final stored = _storage.getHistory(widget.channelId);
    for (final m in stored) {
      final id = m['id']?.toString();
      if (id != null && !_messageIds.contains(id)) {
        _messages.add(m);
        _messageIds.add(id);
      }
    }

    _sub = _socket.messages.listen((data) {
      if (!mounted) return;
      if (data['type'] == 'channel_message' &&
          data['channel_id'] == widget.channelId) {
        final msgId = data['id']?.toString() ?? const Uuid().v4();
        if (_messageIds.contains(msgId)) return;

        final msg = {
          'id':   msgId,
          'text': data['text'] as String? ?? '',
          'from': data['from_uid'] as String? ?? 'unknown',
          'time': data['time'] ?? DateTime.now().millisecondsSinceEpoch,
          'isMe': data['from_uid'] == widget.myUid,
        };
        setState(() {
          _messages.add(msg);
          _messageIds.add(msgId);
        });
        _storage.saveMessage(widget.channelId, msg);
        _scrollToBottom();

        // Play received sound
        SystemSound.play(SystemSoundType.alert);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || !_isOwner) return;

    final msgId = const Uuid().v4();
    _socket.sendChannelMessage(widget.channelId, text, msgId);

    // Play sent sound
    SystemSound.play(SystemSoundType.click);

    final msg = {
      'id':   msgId,
      'text': text,
      'from': widget.myUid,
      'time': DateTime.now().millisecondsSinceEpoch,
      'isMe': true,
    };

    setState(() {
      _messages.add(msg);
      _messageIds.add(msgId);
      _msgCtrl.clear();
    });
    _storage.saveMessage(widget.channelId, msg);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final channelName = _storage.getContactDisplayName(widget.channelId);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF1A0A3A),
              child: Text(
                channelName.isNotEmpty ? channelName[0].toUpperCase() : '#',
                style: const TextStyle(
                    color: Color(0xFFB39DDB), fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channelName.isNotEmpty ? channelName : widget.channelId,
                    style: GoogleFonts.orbitron(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _isOwner ? 'Вы — владелец' : 'Только чтение',
                    style: TextStyle(
                      fontSize: 10,
                      color: _isOwner ? Colors.green : Colors.white38,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.campaign_outlined,
                            color: Colors.white24, size: 48),
                        const SizedBox(height: 12),
                        Text(
                          'Нет публикаций',
                          style: GoogleFonts.orbitron(
                              color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (_, i) => _buildBubble(_messages[i]),
                  ),
          ),
          _isOwner ? _buildInput() : _buildReadOnlyFooter(),
        ],
      ),
    );
  }

  Widget _buildBubble(Map<String, dynamic> msg) {
    final isMe = msg['isMe'] as bool? ?? false;
    final text = msg['text'] as String? ?? '';
    final time = msg['time'] as int? ?? 0;
    final dt   = DateTime.fromMillisecondsSinceEpoch(time);
    final timeStr =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isMe
                ? const Color(0xFF00D9FF).withValues(alpha: 0.15)
                : const Color(0xFF1A1F3C),
            borderRadius: BorderRadius.only(
              topLeft:     const Radius.circular(16),
              topRight:    const Radius.circular(16),
              bottomLeft:  Radius.circular(isMe ? 16 : 4),
              bottomRight: Radius.circular(isMe ? 4 : 16),
            ),
            border: Border.all(
              color: isMe
                  ? const Color(0xFF00D9FF).withValues(alpha: 0.3)
                  : Colors.white12,
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(text,
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 4),
              Text(timeStr,
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInput() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1F3C),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _msgCtrl,
              style: const TextStyle(color: Colors.white),
              maxLines: null,
              decoration: InputDecoration(
                hintText: 'Сообщение канала...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF0A0E27),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: const Color(0xFF00D9FF),
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: _send,
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.send, color: Colors.black, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1F3C),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.lock_outline, size: 14, color: Colors.white38),
          SizedBox(width: 8),
          Text(
            'Только владелец может публиковать в этом канале',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
