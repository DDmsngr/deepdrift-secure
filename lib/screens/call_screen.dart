import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:audioplayers/audioplayers.dart';

import '../services/call_service.dart';
import '../storage_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CallScreen — экран голосового / видео вызова.
//
// Два режима открытия:
//   1. Исходящий: CallScreen(myUid, targetUid, callType, isIncoming: false)
//      → автоматически вызывает startCall()
//   2. Входящий:  CallScreen(myUid, targetUid, callType, isIncoming: true)
//      → показывает UI «Входящий звонок» с кнопками Accept / Reject
// ─────────────────────────────────────────────────────────────────────────────

class CallScreen extends StatefulWidget {
  final String myUid;
  final String targetUid;
  final String callType; // 'audio' | 'video'
  final bool   isIncoming;

  const CallScreen({
    super.key,
    required this.myUid,
    required this.targetUid,
    this.callType  = 'audio',
    this.isIncoming = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _callService = CallService();
  final _storage     = StorageService();

  final _localRenderer  = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  final _tonePlayer     = AudioPlayer();

  Timer?   _durationTimer;
  Duration _callDuration = Duration.zero;
  String   _statusText   = '';
  bool     _showControls = true;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _setupCallbacks();

    if (widget.isIncoming) {
      _statusText = 'Входящий звонок...';
      _playTone('ringtone.wav');
    } else {
      _statusText = 'Вызов...';
      _playTone('ringback.wav');
      _initiateCall();
    }
  }

  Future<void> _playTone(String asset) async {
    try {
      await _tonePlayer.setReleaseMode(ReleaseMode.loop);
      await _tonePlayer.play(AssetSource(asset), volume: 0.8);
    } catch (e) {
      debugPrint('🔊 Tone play error: $e');
    }
  }

  Future<void> _stopTone() async {
    try {
      await _tonePlayer.stop();
    } catch (_) {}
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  /// Начинает исходящий вызов. Если разрешения не получены — закрывает экран.
  Future<void> _initiateCall() async {
    final success = await _callService.startCall(
      widget.targetUid,
      callType: widget.callType,
    );
    if (!success && mounted) {
      Navigator.of(context).pop();
    }
  }

  void _setupCallbacks() {
    _callService.onStateChanged = (state) {
      if (!mounted) return;
      setState(() {
        switch (state) {
          case CallState.outgoing:
            _statusText = 'Вызов...';
            break;
          case CallState.incoming:
            _statusText = 'Входящий звонок...';
            break;
          case CallState.connecting:
            _statusText = 'Соединение...';
            _stopTone();
            break;
          case CallState.active:
            _statusText = '';
            _stopTone();
            _startDurationTimer();
            break;
          case CallState.ended:
            _statusText = 'Вызов завершён';
            _stopTone();
            _durationTimer?.cancel();
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted) Navigator.of(context).pop();
            });
            break;
          case CallState.idle:
            break;
        }
      });
    };

    _callService.onLocalStream = (stream) {
      if (mounted) setState(() => _localRenderer.srcObject = stream);
    };

    _callService.onRemoteStream = (stream) {
      if (mounted) setState(() => _remoteRenderer.srcObject = stream);
    };

    _callService.onPermissionDenied = (reason) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(reason),
          backgroundColor: Colors.red.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
    };
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _callDuration = Duration.zero;
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _callDuration += const Duration(seconds: 1);
        });
      }
    });
  }

  String _formatDuration(Duration d) {
    final hours   = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _stopTone();
    _tonePlayer.dispose();
    _callService.onStateChanged    = null;
    _callService.onLocalStream     = null;
    _callService.onRemoteStream    = null;
    _callService.onPermissionDenied = null;
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _onAccept() async {
    _stopTone();
    final success = await _callService.acceptCall();
    if (!success && mounted) {
      Navigator.of(context).pop();
    }
  }

  void _onReject() {
    _stopTone();
    _callService.rejectCall();
    if (mounted) Navigator.of(context).pop();
  }

  void _onHangUp() {
    _stopTone();
    _callService.hangUp();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // UI
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final displayName = _storage.getContactDisplayName(widget.targetUid);
    final isVideo     = widget.callType == 'video';
    final isActive    = _callService.state == CallState.active;
    final isIncoming  = _callService.state == CallState.incoming;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E27),
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          children: [
            // ── Фон / видео ──────────────────────────────────────────────
            if (isVideo && _remoteRenderer.srcObject != null)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              )
            else
              _buildAudioBackground(displayName),

            // ── Локальное видео (PiP) ────────────────────────────────────
            if (isVideo && isActive && _localRenderer.srcObject != null)
              Positioned(
                top: MediaQuery.of(context).padding.top + 16,
                right: 16,
                width: 100,
                height: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),

            // ── Информация о вызове ──────────────────────────────────────
            if (_showControls)
              Positioned(
                top: MediaQuery.of(context).padding.top + 24,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    Text(
                      displayName,
                      style: GoogleFonts.orbitron(
                        fontSize: 22,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (isActive)
                      Text(
                        _formatDuration(_callDuration),
                        style: const TextStyle(color: Colors.white70, fontSize: 16),
                      )
                    else
                      Text(
                        _statusText,
                        style: const TextStyle(color: Colors.cyan, fontSize: 14),
                      ),
                  ],
                ),
              ),

            // ── Кнопки управления ────────────────────────────────────────
            if (_showControls)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 40,
                left: 0,
                right: 0,
                child: isIncoming
                    ? _buildIncomingControls()
                    : _buildActiveControls(isVideo),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioBackground(String displayName) {
    final isActive = _callService.state == CallState.active;

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A0E27), Color(0xFF1A1F3C), Color(0xFF0A0E27)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Пульсирующий аватар при вызове
            AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              padding: EdgeInsets.all(isActive ? 0 : 8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: isActive
                    ? null
                    : Border.all(color: Colors.cyan.withValues(alpha: 0.3), width: 2),
              ),
              child: CircleAvatar(
                radius: 60,
                backgroundColor: const Color(0xFF1A1F3C),
                child: Text(
                  displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                  style: GoogleFonts.orbitron(fontSize: 40, color: Colors.cyan),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Кнопки для входящего вызова: Accept / Reject
  Widget _buildIncomingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildCircleButton(
          icon: Icons.call_end,
          color: Colors.red,
          size: 64,
          onTap: _onReject,
          label: 'Отклонить',
        ),
        _buildCircleButton(
          icon: widget.callType == 'video' ? Icons.videocam : Icons.call,
          color: Colors.green,
          size: 64,
          onTap: _onAccept,
          label: 'Принять',
        ),
      ],
    );
  }

  /// Кнопки во время активного вызова: Mute, Speaker, Video, HangUp
  Widget _buildActiveControls(bool isVideo) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildCircleButton(
              icon: _callService.isMuted ? Icons.mic_off : Icons.mic,
              color: _callService.isMuted ? Colors.red : Colors.white24,
              onTap: () => setState(() => _callService.toggleMute()),
              label: _callService.isMuted ? 'Вкл. микр.' : 'Выкл. микр.',
            ),
            _buildCircleButton(
              icon: _callService.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
              color: _callService.isSpeakerOn ? Colors.cyan : Colors.white24,
              onTap: () => setState(() => _callService.toggleSpeaker()),
              label: 'Динамик',
            ),
            if (isVideo) ...[
              _buildCircleButton(
                icon: _callService.isVideoEnabled ? Icons.videocam : Icons.videocam_off,
                color: _callService.isVideoEnabled ? Colors.white24 : Colors.red,
                onTap: () => setState(() => _callService.toggleVideo()),
                label: 'Камера',
              ),
              _buildCircleButton(
                icon: Icons.switch_camera,
                color: Colors.white24,
                onTap: () => _callService.switchCamera(),
                label: 'Перевернуть',
              ),
            ],
          ],
        ),
        const SizedBox(height: 28),
        _buildCircleButton(
          icon: Icons.call_end,
          color: Colors.red,
          size: 64,
          onTap: _onHangUp,
          label: 'Завершить',
        ),
      ],
    );
  }

  Widget _buildCircleButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    String? label,
    double size = 52,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
        ],
      ],
    );
  }
}
