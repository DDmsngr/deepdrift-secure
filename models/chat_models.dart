import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ─── Типы сообщений ───────────────────────────────────────────────────────────
enum MsgType { text, image, voice, file, video_note, video_gallery }

extension MsgTypeStr on String {
  MsgType toMsgType() {
    switch (this) {
      case 'image':         return MsgType.image;
      case 'voice':         return MsgType.voice;
      case 'file':          return MsgType.file;
      case 'video_note':    return MsgType.video_note;
      case 'video_gallery': return MsgType.video_gallery;
      default:              return MsgType.text;
    }
  }
}

// ─── Статус верификации подписи ───────────────────────────────────────────────
enum SignatureStatus { unknown, valid, invalid }

// ─── Форматирование ───────────────────────────────────────────────────────────

String formatMessageTime(dynamic timestamp) {
  if (timestamp == null) return '';
  final dt = timestamp is int
      ? DateTime.fromMillisecondsSinceEpoch(timestamp)
      : DateTime.tryParse(timestamp.toString()) ?? DateTime.now();
  return DateFormat.Hm().format(dt);
}

String formatLastSeen(int timestamp) {
  if (timestamp == 0) return 'offline';
  final dt   = DateTime.fromMillisecondsSinceEpoch(timestamp);
  final now  = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1)    return 'только что';
  if (diff.inMinutes < 60)   return '${diff.inMinutes} мин назад';
  if (dt.day == now.day)     return 'сегодня в ${DateFormat.Hm().format(dt)}';
  if (dt.day == now.day - 1) return 'вчера в ${DateFormat.Hm().format(dt)}';
  return DateFormat('dd MMM, HH:mm').format(dt);
}

String formatFileSize(dynamic sizeRaw) {
  final size = sizeRaw is int ? sizeRaw : int.tryParse(sizeRaw.toString()) ?? 0;
  if (size < 1024)           return '$size B';
  if (size < 1024 * 1024)   return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatRecordingTime(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String extensionForType(MsgType type, String? fileName) {
  if (fileName != null && fileName.contains('.')) return '.${fileName.split('.').last}';
  switch (type) {
    case MsgType.image:         return '.jpg';
    case MsgType.voice:         return '.m4a';
    case MsgType.video_note:    return '.mp4';
    case MsgType.video_gallery: return '.mp4';
    default:                    return '';
  }
}

String mimeTypeFromExtension(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  const mimes = {
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt': 'text/plain',  'zip': 'application/zip',
    'rar': 'application/x-rar-compressed', 'mp3': 'audio/mpeg',
    'mp4': 'video/mp4',   'mov': 'video/quicktime',
    'png': 'image/png',   'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'gif': 'image/gif',
  };
  return mimes[ext] ?? 'application/octet-stream';
}

IconData iconForMime(String? mimeType) {
  if (mimeType == null)                                             return Icons.attach_file;
  if (mimeType.startsWith('image/'))                               return Icons.image;
  if (mimeType.startsWith('audio/'))                               return Icons.audio_file;
  if (mimeType.startsWith('video/'))                               return Icons.video_file;
  if (mimeType.contains('pdf'))                                    return Icons.picture_as_pdf;
  if (mimeType.contains('word') || mimeType.contains('msword'))    return Icons.description;
  if (mimeType.contains('excel') || mimeType.contains('spreadsheet')) return Icons.table_chart;
  if (mimeType.contains('zip') || mimeType.contains('rar'))        return Icons.folder_zip;
  return Icons.attach_file;
}
