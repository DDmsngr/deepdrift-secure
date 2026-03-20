import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../socket_service.dart';
import '../storage_service.dart';
import '../config/app_config.dart';

/// Экран настроек группы в стиле Telegram.
/// Доступен из AppBar чата → ⋮ → Настройки группы (только для админов).
class GroupSettingsScreen extends StatefulWidget {
  final String myUid;
  final String groupId;

  const GroupSettingsScreen({
    super.key,
    required this.myUid,
    required this.groupId,
  });

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  final _socket  = SocketService();
  final _storage = StorageService();

  static const String _serverUrl = AppConfig.httpBaseUrl;

  StreamSubscription? _sub;
  final _dio = Dio();
  final _imagePicker = ImagePicker();

  String _groupName    = '';
  String _description  = '';
  String _photoId      = '';
  List<String> _members = [];
  List<String> _admins  = [];
  bool _onlyAdminsPost   = false;
  bool _onlyAdminsInvite = false;
  bool _isLoading = true;
  bool _isUploadingPhoto = false;

  bool get _isAdmin => _admins.contains(widget.myUid);

  @override
  void initState() {
    super.initState();
    _groupName = _storage.getGroupName(widget.groupId);
    _members   = _storage.getGroupMembers(widget.groupId);

    _sub = _socket.messages.listen((data) {
      if (!mounted) return;
      if (data['type'] == 'group_info_response' && data['group_id'] == widget.groupId) {
        setState(() {
          _groupName  = data['group_name'] as String? ?? _groupName;
          _description = data['description'] as String? ?? '';
          _photoId    = data['photo_id'] as String? ?? '';
          _members    = (data['members'] as List?)?.cast<String>() ?? _members;
          _admins     = (data['admins'] as List?)?.cast<String>() ?? [];
          final settings = data['settings'] as Map<String, dynamic>? ?? {};
          _onlyAdminsPost   = settings['only_admins_post'] == '1';
          _onlyAdminsInvite = settings['only_admins_invite'] == '1';
          _isLoading = false;
        });
      }
      if (data['type'] == 'group_settings_updated' && data['group_id'] == widget.groupId) {
        // Перезапрашиваем инфо
        _socket.send({'type': 'get_group_info', 'group_id': widget.groupId});
      }
    });

    // Запрашиваем полную инфу с сервера
    _socket.send({'type': 'get_group_info', 'group_id': widget.groupId});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _updateSetting(String key, bool value) {
    _socket.send({
      'type': 'update_group_settings',
      'group_id': widget.groupId,
      key: value,
    });
  }

  void _updateGroupInfo({String? name, String? description, String? photoId}) {
    final data = <String, dynamic>{
      'type': 'update_group_info',
      'group_id': widget.groupId,
    };
    if (name != null) data['group_name'] = name;
    if (description != null) data['description'] = description;
    if (photoId != null) data['photo_id'] = photoId;
    _socket.send(data);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1F3C),
        title: Text('Настройки группы', style: GoogleFonts.orbitron(fontSize: 14)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D9FF)))
          : ListView(
              children: [
                // ── Инфо группы ──────────────────────────────────────────
                _buildHeader(),
                const Divider(color: Colors.white12, height: 1),

                // ── Настройки (только для админов) ───────────────────────
                if (_isAdmin) ...[
                  _sectionTitle('Права'),
                  _buildSwitch(
                    'Только админы могут писать',
                    'Участники смогут только читать',
                    _onlyAdminsPost,
                    (v) { setState(() => _onlyAdminsPost = v); _updateSetting('only_admins_post', v); },
                  ),
                  _buildSwitch(
                    'Только админы могут приглашать',
                    'Участники не смогут добавлять людей',
                    _onlyAdminsInvite,
                    (v) { setState(() => _onlyAdminsInvite = v); _updateSetting('only_admins_invite', v); },
                  ),
                  const Divider(color: Colors.white12, height: 1),
                ],

                // ── Участники ────────────────────────────────────────────
                _sectionTitle('Участники (${_members.length})'),
                ..._members.map((uid) => _buildMemberTile(uid)),
                const SizedBox(height: 80),
              ],
            ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Аватар с возможностью смены (для админов)
          GestureDetector(
            onTap: _isAdmin ? _pickGroupPhoto : null,
            child: Stack(
              children: [
                _photoId.isNotEmpty
                    ? CircleAvatar(
                        radius: 40,
                        backgroundImage: CachedNetworkImageProvider(
                          '$_serverUrl/download/$_photoId',
                        ),
                      )
                    : CircleAvatar(
                        radius: 40,
                        backgroundColor: const Color(0xFF0A2A3A),
                        child: Text(
                          _groupName.isNotEmpty ? _groupName[0].toUpperCase() : 'G',
                          style: GoogleFonts.orbitron(fontSize: 28, color: const Color(0xFF00D9FF)),
                        ),
                      ),
                if (_isAdmin)
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      width: 28, height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D9FF),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFF0A0E27), width: 2),
                      ),
                      child: _isUploadingPhoto
                          ? const Padding(
                              padding: EdgeInsets.all(6),
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                            )
                          : const Icon(Icons.camera_alt, size: 14, color: Colors.black),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _isAdmin ? _editGroupName : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_groupName, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                if (_isAdmin) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.edit, size: 16, color: Colors.white38),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _isAdmin ? _editDescription : null,
            child: Text(
              _description.isEmpty ? (_isAdmin ? 'Добавить описание...' : 'Нет описания') : _description,
              style: TextStyle(
                color: _description.isEmpty ? Colors.white24 : Colors.white54,
                fontSize: 13,
                fontStyle: _description.isEmpty ? FontStyle.italic : FontStyle.normal,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Text('ID: ${widget.groupId}', style: const TextStyle(color: Colors.white24, fontSize: 11)),
        ],
      ),
    );
  }

  Future<void> _pickGroupPhoto() async {
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      imageQuality: 80,
    );
    if (picked == null) return;

    setState(() => _isUploadingPhoto = true);
    try {
      final token = StorageService.uploadToken;
      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(picked.path),
      });
      final response = await _dio.post(
        '$_serverUrl/upload',
        data: formData,
        options: Options(headers: {
          if (token != null) 'X-Upload-Token': token,
        }),
      );
      if (response.statusCode == 200) {
        final fileId = response.data['file_id'] as String? ?? '';
        if (fileId.isNotEmpty) {
          _updateGroupInfo(photoId: fileId);
          setState(() => _photoId = fileId);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title, style: const TextStyle(color: Color(0xFF00D9FF), fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildSwitch(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      value: value,
      onChanged: onChanged,
      activeColor: const Color(0xFF00D9FF),
    );
  }

  Widget _buildMemberTile(String uid) {
    final name     = _storage.getContactDisplayName(uid);
    final isAdmin  = _admins.contains(uid);
    final isMe     = uid == widget.myUid;
    final isOnline = _storage.isContactOnline(uid);

    return ListTile(
      leading: Stack(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: const Color(0xFF1A1F3C),
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(color: Color(0xFF00D9FF))),
          ),
          if (isOnline)
            Positioned(right: 0, bottom: 0, child: Container(
              width: 10, height: 10,
              decoration: BoxDecoration(color: Colors.greenAccent, shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF0A0E27), width: 2)),
            )),
        ],
      ),
      title: Row(children: [
        Expanded(child: Text(
          isMe ? '$name (вы)' : name,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        )),
        if (isAdmin)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF00D9FF).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('Админ', style: TextStyle(color: Color(0xFF00D9FF), fontSize: 10)),
          ),
      ]),
      subtitle: Text('ID: $uid', style: const TextStyle(color: Colors.white24, fontSize: 11)),
      onLongPress: (_isAdmin && !isMe) ? () => _showMemberActions(uid, name, isAdmin) : null,
    );
  }

  void _showMemberActions(String uid, String name, bool isAdmin) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1F3C),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(margin: const EdgeInsets.only(top: 10, bottom: 8), width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          if (isAdmin)
            ListTile(
              leading: const Icon(Icons.arrow_downward, color: Colors.orange),
              title: const Text('Снять админа', style: TextStyle(color: Colors.orange)),
              onTap: () {
                Navigator.pop(ctx);
                _socket.send({'type': 'demote_admin', 'group_id': widget.groupId, 'target_uid': uid});
                _socket.send({'type': 'get_group_info', 'group_id': widget.groupId});
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.star, color: Colors.amber),
              title: const Text('Сделать админом', style: TextStyle(color: Colors.amber)),
              onTap: () {
                Navigator.pop(ctx);
                _socket.send({'type': 'promote_admin', 'group_id': widget.groupId, 'target_uid': uid});
                _socket.send({'type': 'get_group_info', 'group_id': widget.groupId});
              },
            ),
          ListTile(
            leading: const Icon(Icons.person_remove, color: Colors.red),
            title: const Text('Исключить из группы', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(ctx);
              _socket.send({'type': 'kick_member', 'group_id': widget.groupId, 'target_uid': uid});
              setState(() => _members.remove(uid));
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  void _editGroupName() {
    final ctrl = TextEditingController(text: _groupName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F3C),
        title: const Text('Название группы', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl, autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(filled: true, fillColor: Color(0xFF0A0E27)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА')),
          ElevatedButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isNotEmpty) {
                _updateGroupInfo(name: name);
                _storage.setContactDisplayName(widget.groupId, name);
                setState(() => _groupName = name);
              }
              Navigator.pop(ctx);
            },
            child: const Text('СОХРАНИТЬ'),
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
        title: const Text('Описание группы', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl, autofocus: true, maxLines: 4,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Введите описание...',
            hintStyle: TextStyle(color: Colors.white38),
            filled: true, fillColor: Color(0xFF0A0E27),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('ОТМЕНА')),
          ElevatedButton(
            onPressed: () {
              _updateGroupInfo(description: ctrl.text.trim());
              setState(() => _description = ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('СОХРАНИТЬ'),
          ),
        ],
      ),
    );
  }
}
