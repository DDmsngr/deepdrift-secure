import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../socket_service.dart';
import '../storage_service.dart';

/// Экран информации о канале: имя, описание, фото, подписчики, действия.
class ChannelInfoScreen extends StatefulWidget {
  final String myUid;
  final String channelId;

  const ChannelInfoScreen({super.key, required this.myUid, required this.channelId});

  @override
  State<ChannelInfoScreen> createState() => _ChannelInfoScreenState();
}

class _ChannelInfoScreenState extends State<ChannelInfoScreen> {
  static const String _serverUrl = 'https://deepdrift-backend.onrender.com';

  final _socket  = SocketService();
  final _storage = StorageService();
  final _dio     = Dio();
  final _picker  = ImagePicker();

  StreamSubscription? _sub;

  String _name        = '';
  String _description = '';
  String _ownerUid    = '';
  String _photoId     = '';
  int    _subCount    = 0;
  bool   _isSubscribed = false;
  bool   _isLoading   = true;
  bool   _isUploading = false;

  bool get _isOwner => _ownerUid == widget.myUid;

  @override
  void initState() {
    super.initState();
    _name = _storage.getContactDisplayName(widget.channelId);

    _sub = _socket.messages.listen((data) {
      if (!mounted) return;
      if (data['type'] == 'channel_info_response' && data['channel_id'] == widget.channelId) {
        setState(() {
          _name        = data['channel_name'] as String? ?? _name;
          _description = data['description'] as String? ?? '';
          _ownerUid    = data['owner_uid'] as String? ?? '';
          _photoId     = data['photo_id'] as String? ?? '';
          _subCount    = data['subscriber_count'] as int? ?? 0;
          _isSubscribed = data['is_subscribed'] == true;
          _isLoading   = false;
        });
      }
      if (data['type'] == 'channel_updated' && data['channel_id'] == widget.channelId) {
        _socket.getChannelInfo(widget.channelId);
      }
      if (data['type'] == 'channel_deleted' && data['channel_id'] == widget.channelId) {
        if (mounted) {
          Navigator.of(context).popUntil((r) => r.isFirst);
        }
      }
    });

    _socket.getChannelInfo(widget.channelId);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _editName() {
    final ctrl = TextEditingController(text: _name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Название', style: GoogleFonts.orbitron(fontSize: 14, color: const Color(0xFF00D9FF))),
        content: TextField(
          controller: ctrl, autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(filled: true, fillColor: Color(0xFF0A0E27), border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D9FF), foregroundColor: Colors.black),
            onPressed: () {
              final n = ctrl.text.trim();
              if (n.isNotEmpty) {
                _socket.editChannel(widget.channelId, name: n);
                _storage.setContactDisplayName(widget.channelId, n);
                setState(() => _name = n);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  void _editDescription() {
    final ctrl = TextEditingController(text: _description);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Описание', style: GoogleFonts.orbitron(fontSize: 14, color: const Color(0xFF00D9FF))),
        content: TextField(
          controller: ctrl, autofocus: true, maxLines: 4,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(filled: true, fillColor: Color(0xFF0A0E27), border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D9FF), foregroundColor: Colors.black),
            onPressed: () {
              _socket.editChannel(widget.channelId, description: ctrl.text.trim());
              setState(() => _description = ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickPhoto() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 80);
    if (picked == null) return;

    setState(() => _isUploading = true);
    try {
      final token = StorageService.uploadToken;
      final formData = FormData.fromMap({'file': await MultipartFile.fromFile(picked.path)});
      final response = await _dio.post('$_serverUrl/upload', data: formData,
          options: Options(headers: {if (token != null) 'X-Upload-Token': token}));
      if (response.statusCode == 200) {
        final fileId = response.data['file_id'] as String? ?? '';
        if (fileId.isNotEmpty) {
          _socket.editChannel(widget.channelId, photoId: fileId);
          setState(() => _photoId = fileId);
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _toggleSubscription() {
    if (_isSubscribed) {
      _socket.send({'type': 'leave_channel', 'channel_id': widget.channelId});
      _storage.removeContact(widget.channelId);
      setState(() { _isSubscribed = false; _subCount--; });
    } else {
      _socket.joinChannel(widget.channelId);
      _storage.addContact(widget.channelId, displayName: _name);
      setState(() { _isSubscribed = true; _subCount++; });
    }
  }

  void _deleteChannel() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Удалить канал?', style: TextStyle(color: Colors.red)),
        content: const Text('Канал будет удалён для всех подписчиков. Это действие нельзя отменить.',
            style: TextStyle(color: Colors.white54)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА', style: TextStyle(color: Colors.white38))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(ctx);
              _socket.deleteChannel(widget.channelId);
              _storage.removeContact(widget.channelId);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            child: const Text('УДАЛИТЬ'),
          ),
        ],
      ),
    );
  }

  void _shareLink() {
    final link = 'deepdrift://channel/${widget.channelId}';
    Clipboard.setData(ClipboardData(text: link));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Ссылка скопирована: $link'),
      backgroundColor: const Color(0xFF1A4A2E),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Канал', style: GoogleFonts.orbitron(fontSize: 14)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D9FF)))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Аватар ──────────────────────────────────────────
                Center(
                  child: GestureDetector(
                    onTap: _isOwner ? _pickPhoto : null,
                    child: Stack(
                      children: [
                        _photoId.isNotEmpty
                            ? CircleAvatar(
                                radius: 50,
                                backgroundImage: CachedNetworkImageProvider('$_serverUrl/download/$_photoId'),
                              )
                            : CircleAvatar(
                                radius: 50,
                                backgroundColor: const Color(0xFF1A0A3A),
                                child: Text(
                                  _name.isNotEmpty ? _name[0].toUpperCase() : '#',
                                  style: GoogleFonts.orbitron(fontSize: 36, color: const Color(0xFFB39DDB)),
                                ),
                              ),
                        if (_isOwner)
                          Positioned(right: 0, bottom: 0, child: Container(
                            width: 30, height: 30,
                            decoration: BoxDecoration(
                              color: const Color(0xFF00D9FF), shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF0A0E27), width: 2),
                            ),
                            child: _isUploading
                                ? const Padding(padding: EdgeInsets.all(6), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                : const Icon(Icons.camera_alt, size: 14, color: Colors.black),
                          )),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Имя ─────────────────────────────────────────────
                Center(
                  child: GestureDetector(
                    onTap: _isOwner ? _editName : null,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                      if (_isOwner) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.edit, size: 16, color: Colors.white38)),
                    ]),
                  ),
                ),
                const SizedBox(height: 4),

                // ── ID ──────────────────────────────────────────────
                Center(child: Text(widget.channelId, style: const TextStyle(color: Colors.white24, fontSize: 11))),
                const SizedBox(height: 12),

                // ── Подписчики ──────────────────────────────────────
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(color: const Color(0xFF1A1F3C), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.people, size: 16, color: Color(0xFF00D9FF)),
                      const SizedBox(width: 6),
                      Text('$_subCount подписчик${_subCount == 1 ? '' : _subCount < 5 ? 'а' : 'ов'}',
                          style: const TextStyle(color: Colors.white54, fontSize: 13)),
                    ]),
                  ),
                ),
                const SizedBox(height: 20),

                // ── Описание ────────────────────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xFF1A1F3C), borderRadius: BorderRadius.circular(12)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Text('Описание', style: TextStyle(color: Color(0xFF00D9FF), fontSize: 12, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      if (_isOwner) GestureDetector(
                        onTap: _editDescription,
                        child: const Icon(Icons.edit, size: 14, color: Colors.white38),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Text(
                      _description.isEmpty ? 'Нет описания' : _description,
                      style: TextStyle(color: _description.isEmpty ? Colors.white24 : Colors.white70, fontSize: 14),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),

                // ── Владелец ────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xFF1A1F3C), borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    const Icon(Icons.admin_panel_settings, size: 18, color: Color(0xFF00D9FF)),
                    const SizedBox(width: 10),
                    Text(
                      _isOwner ? 'Вы — владелец' : 'Владелец: ${_storage.getContactDisplayName(_ownerUid)}',
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ]),
                ),
                const SizedBox(height: 24),

                // ── Действия ────────────────────────────────────────
                _actionButton(Icons.share, 'Поделиться ссылкой', const Color(0xFF00D9FF), _shareLink),
                const SizedBox(height: 8),

                if (!_isOwner)
                  _actionButton(
                    _isSubscribed ? Icons.exit_to_app : Icons.add,
                    _isSubscribed ? 'Отписаться' : 'Подписаться',
                    _isSubscribed ? Colors.orange : const Color(0xFF00D9FF),
                    _toggleSubscription,
                  ),

                if (_isOwner) ...[
                  const SizedBox(height: 8),
                  _actionButton(Icons.delete_forever, 'Удалить канал', Colors.red, _deleteChannel),
                ],
              ],
            ),
    );
  }

  Widget _actionButton(IconData icon, String label, Color color, VoidCallback onTap) {
    return Material(
      color: const Color(0xFF1A1F3C),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Text(label, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}
