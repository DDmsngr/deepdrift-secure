import 'dart:io';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:dio/dio.dart';
import '../socket_service.dart';
import '../storage_service.dart';

/// Экран создания истории — текст с цветным фоном или фото с подписью.
class CreateStoryScreen extends StatefulWidget {
  final String myUid;

  const CreateStoryScreen({super.key, required this.myUid});

  @override
  State<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends State<CreateStoryScreen> {
  static const String SERVER_HTTP_URL = 'https://deepdrift-backend.onrender.com';

  final _socket  = SocketService();
  final _textCtrl = TextEditingController();
  final _dio     = Dio();

  File?  _selectedImage;
  bool   _isUploading = false;
  int    _bgColorIndex = 0;

  static const _bgColors = [
    Color(0xFF1A1F3C), // тёмно-синий
    Color(0xFF2D1B69), // фиолетовый
    Color(0xFF1B4332), // зелёный
    Color(0xFF6B2737), // бордовый
    Color(0xFF0D4C73), // морской
    Color(0xFFBF4F28), // оранжевый
    Color(0xFF1A1A2E), // почти чёрный
    Color(0xFF3D0C02), // тёмно-красный
  ];

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1080,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _selectedImage = File(picked.path));
    }
  }

  Future<void> _takePhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1080,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _selectedImage = File(picked.path));
    }
  }

  Future<void> _postStory() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty && _selectedImage == null) return;

    setState(() => _isUploading = true);

    try {
      String mediaId = '';

      // Если есть фото — загружаем на сервер (без шифрования для сторис)
      if (_selectedImage != null) {
        final token = StorageService.uploadToken;
        final formData = FormData.fromMap({
          'file': await MultipartFile.fromFile(_selectedImage!.path),
        });
        final response = await _dio.post(
          '$SERVER_HTTP_URL/upload',
          data: formData,
          options: Options(headers: {
            if (token != null) 'X-Upload-Token': token,
          }),
        );
        if (response.statusCode == 200) {
          mediaId = response.data['file_id'] as String? ?? '';
        }
      }

      final bg = _bgColors[_bgColorIndex];
      final bgHex = '#${bg.red.toRadixString(16).padLeft(2, '0')}${bg.green.toRadixString(16).padLeft(2, '0')}${bg.blue.toRadixString(16).padLeft(2, '0')}';
      _socket.postStory(
        storyType: _selectedImage != null ? 'image' : 'text',
        text:      text,
        mediaId:   mediaId,
        bgColor:   bgHex,
      );

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _selectedImage != null ? Colors.black : _bgColors[_bgColorIndex],
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text('Новая история', style: GoogleFonts.orbitron(fontSize: 14)),
        actions: [
          if (_isUploading)
            const Center(child: Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
            ))
          else
            TextButton(
              onPressed: _postStory,
              child: const Text('ОПУБЛИКОВАТЬ',
                  style: TextStyle(color: Colors.cyan, fontWeight: FontWeight.bold, fontSize: 13)),
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ── Превью изображения или фон ──────────────────────────────
          if (_selectedImage != null)
            Image.file(_selectedImage!, fit: BoxFit.contain)
          else
            Container(color: _bgColors[_bgColorIndex]),

          // ── Текстовое поле по центру ───────────────────────────────
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: TextField(
                controller: _textCtrl,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: _selectedImage != null ? 18 : 28,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: _selectedImage != null ? 'Добавь подпись...' : 'Напиши что-нибудь...',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 24),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),

          // ── Панель снизу ───────────────────────────────────────────
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 16,
            left: 16, right: 16,
            child: Row(
              children: [
                // Выбор фото
                _circleButton(Icons.photo_library, 'Галерея', _pickImage),
                const SizedBox(width: 12),
                _circleButton(Icons.camera_alt, 'Камера', _takePhoto),
                const Spacer(),
                // Цвет фона (только для текста)
                if (_selectedImage == null) ...[
                  const Text('Фон:', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(width: 8),
                  ..._bgColors.asMap().entries.map((e) {
                    final isActive = e.key == _bgColorIndex;
                    return GestureDetector(
                      onTap: () => setState(() => _bgColorIndex = e.key),
                      child: Container(
                        width: isActive ? 28 : 22,
                        height: isActive ? 28 : 22,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: e.value,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isActive ? Colors.white : Colors.white24,
                            width: isActive ? 2 : 1,
                          ),
                        ),
                      ),
                    );
                  }),
                ],
                // Удалить фото
                if (_selectedImage != null) ...[
                  _circleButton(Icons.delete_outline, 'Убрать', () {
                    setState(() => _selectedImage = null);
                  }),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleButton(IconData icon, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
