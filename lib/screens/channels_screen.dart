import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';

import '../socket_service.dart';
import '../storage_service.dart';
import 'channel_chat_screen.dart';

/// Экран управления каналами.
/// Показывает список подписанных каналов, позволяет искать и создавать новые.
class ChannelsScreen extends StatefulWidget {
  final String myUid;
  final String? initialChannelId;  // deep link — сразу открыть этот канал

  const ChannelsScreen({super.key, required this.myUid, this.initialChannelId});

  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

class _ChannelsScreenState extends State<ChannelsScreen> {
  final _socket     = SocketService();
  final _storage    = StorageService();
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _searchResults = [];
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    // Deep link — открыть канал после первого кадра
    if (widget.initialChannelId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openChannel(widget.initialChannelId!));
    }
    _sub = _socket.messages.listen((data) {
      if (!mounted) return;
      final type = data['type'];
      if (type == 'channel_search_results') {
        final raw = data['channels'];
        final List<Map<String, dynamic>> results = (raw is List)
            ? raw.map((e) => e is Map<String, dynamic> ? e : <String, dynamic>{'id': e.toString()}).toList()
            : [];
        setState(() => _searchResults = results);
      }
      if (type == 'channel_created' || type == 'channel_joined') {
        // Сохраняем имя канала из ответа сервера
        final channelId   = data['channel_id'] as String?;
        final channelName = data['channel_name'] as String?;
        if (channelId != null && channelName != null && channelName.isNotEmpty) {
          _storage.setContactDisplayName(channelId, channelName);
        }
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void _openChannel(String channelId) {
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelChatScreen(myUid: widget.myUid, channelId: channelId),
      ),
    );
  }

  void dispose() {
    _sub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _myChannels => _storage
      .getContactsSortedByActivity()
      .where((uid) => _storage.isChannel(uid))
      .toList();

  void _search(String query) {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    _socket.searchChannels(query.trim());
  }

  void _showCreateDialog() {
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text(
          'Создать канал',
          style: GoogleFonts.orbitron(
              fontSize: 14, color: const Color(0xFF00D9FF)),
        ),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Название канала',
            labelStyle: TextStyle(color: Colors.white54),
            filled: true,
            fillColor: Color(0xFF0A0E27),
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D9FF),
                foregroundColor: Colors.black),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final channelId =
                  'ch_${const Uuid().v4().replaceAll('-', '').substring(0, 10)}';
              _socket.createChannel(channelId, name);
              _storage.addContact(channelId, displayName: name);
              // Сохраняем себя как владельца
              _storage.saveSetting('channel_owner_$channelId', widget.myUid);
              if (mounted) setState(() {});
              Navigator.pop(ctx);
            },
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final channels = _myChannels;
    final isSearching = _searchCtrl.text.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0E1A),
        title: Text(
          'Каналы',
          style: GoogleFonts.orbitron(
              color: const Color(0xFF00D9FF), fontSize: 14),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Поиск каналов...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon:
                    const Icon(Icons.search, color: Colors.white38),
                suffixIcon: isSearching
                    ? IconButton(
                        icon: const Icon(Icons.clear,
                            color: Colors.white38, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchResults = []);
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1A1F3C),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
              ),
              onChanged: (v) {
                setState(() {});
                _search(v);
              },
            ),
          ),
        ),
      ),
      body: isSearching
          ? _buildSearchResults()
          : _buildMyChannels(channels),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF00D9FF),
        foregroundColor: Colors.black,
        tooltip: 'Создать канал',
        onPressed: _showCreateDialog,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildMyChannels(List<String> channels) {
    if (channels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.campaign_outlined,
                  color: Colors.white24, size: 64),
              const SizedBox(height: 16),
              Text(
                'Нет каналов',
                style: GoogleFonts.orbitron(
                    color: Colors.white38, fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'Создай канал или найди через поиск',
                style: TextStyle(color: Colors.white24, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: channels.length,
      itemBuilder: (_, i) => _channelTile(channels[i]),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults.isEmpty) {
      return const Center(
        child: Text(
          'Каналы не найдены',
          style: TextStyle(color: Colors.white38),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _searchResults.length,
      itemBuilder: (_, i) {
        final item       = _searchResults[i];
        final id         = item['id']?.toString() ?? item['channel_id']?.toString() ?? '';
        final name       = item['name']?.toString() ?? item['channel_name']?.toString() ?? id;
        final isJoined   = _storage.getContacts().contains(id);

        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: Color(0xFF1A0A3A),
            child: Icon(Icons.campaign, color: Color(0xFFB39DDB)),
          ),
          title: Text(name, style: const TextStyle(color: Colors.white)),
          subtitle: Text(id,
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          trailing: isJoined
              ? const Chip(
                  label: Text('Подписан',
                      style: TextStyle(color: Colors.green, fontSize: 11)),
                  backgroundColor: Colors.transparent,
                )
              : ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00D9FF),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: () {
                    _socket.joinChannel(id);
                    _storage.addContact(id, displayName: name);
                    if (mounted) setState(() {});
                  },
                  child: const Text('Подписаться',
                      style: TextStyle(fontSize: 11)),
                ),
        );
      },
    );
  }

  Widget _channelTile(String channelId) {
    final name     = _storage.getContactDisplayName(channelId);
    final isOwner  = _storage.getSetting('channel_owner_$channelId') == widget.myUid;
    final unread   = _storage.getUnreadCount(channelId);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: const Color(0xFF1A0A3A),
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '#',
          style: const TextStyle(color: Color(0xFFB39DDB), fontWeight: FontWeight.bold),
        ),
      ),
      title: Text(
        name.isNotEmpty ? name : channelId,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        isOwner ? 'Вы — владелец' : 'Подписчик',
        style: TextStyle(
          color: isOwner ? const Color(0xFF00D9FF) : Colors.white38,
          fontSize: 11,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (unread > 0)
            CircleAvatar(
              radius: 10,
              backgroundColor: const Color(0xFF00D9FF),
              child: Text('$unread',
                  style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          IconButton(
            icon: const Icon(Icons.share_outlined, color: Colors.white38, size: 20),
            tooltip: 'Поделиться каналом',
            onPressed: () {
              final channelName = _storage.getContactDisplayName(channelId);
              final link = 'deepdrift://channel/$channelId';
              Clipboard.setData(ClipboardData(text: link));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ссылка на «$channelName» скопирована',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(link,
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    ],
                  ),
                  backgroundColor: const Color(0xFF1A4A2E),
                  duration: const Duration(seconds: 3),
                ),
              );
            },
          ),
        ],
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChannelChatScreen(
              myUid: widget.myUid, channelId: channelId),
        ),
      ),
    );
  }
}
