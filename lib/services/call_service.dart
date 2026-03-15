import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../socket_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CallService — управление WebRTC peer connection для голосовых/видео вызовов.
//
// Архитектура:
//   1. Caller создаёт offer SDP → отправляет через WebSocket (call_offer)
//   2. Callee получает offer → создаёт answer SDP → отправляет (call_answer)
//   3. Оба обмениваются ICE-кандидатами через WebSocket (ice_candidate)
//   4. WebRTC устанавливает P2P соединение для медиа
//
// Жизненный цикл:
//   startCall()     → запрашивает разрешения → создаёт offer, шлёт call_offer
//   acceptCall()    → запрашивает разрешения → принимает offer, создаёт answer
//   hangUp()        → завершает вызов, освобождает ресурсы
// ─────────────────────────────────────────────────────────────────────────────

enum CallState {
  idle,
  outgoing,   // ожидание ответа
  incoming,   // входящий звонок
  connecting, // WebRTC handshake
  active,     // разговор
  ended,
}

class CallService {
  static final CallService _instance = CallService._internal();
  factory CallService() => _instance;
  CallService._internal();

  final _socket = SocketService();

  // ── Состояние ──────────────────────────────────────────────────────────────
  CallState _state = CallState.idle;
  CallState get state => _state;

  String? _callId;
  String? _remoteUid;
  String? _myUid;
  String  _callType = 'audio'; // 'audio' | 'video'
  bool get isVideo => _callType == 'video';

  String? get callId    => _callId;
  String? get remoteUid => _remoteUid;

  // ── WebRTC ─────────────────────────────────────────────────────────────────
  RTCPeerConnection? _peerConnection;
  MediaStream?       _localStream;
  MediaStream?       _remoteStream;

  RTCPeerConnection? get peerConnection => _peerConnection;
  MediaStream?       get localStream    => _localStream;
  MediaStream?       get remoteStream   => _remoteStream;

  // ── Управление медиа ──────────────────────────────────────────────────────
  bool _isMuted       = false;
  bool _isSpeakerOn   = false;
  bool _isVideoEnabled = true;

  bool get isMuted       => _isMuted;
  bool get isSpeakerOn   => _isSpeakerOn;
  bool get isVideoEnabled => _isVideoEnabled;

  // ── Буфер ICE-кандидатов (до установления remote description) ──────────────
  final List<RTCIceCandidate> _pendingCandidates = [];

  // ── Таймер ─────────────────────────────────────────────────────────────────
  DateTime? _callStartTime;
  DateTime? get callStartTime => _callStartTime;

  // ── Callbacks ──────────────────────────────────────────────────────────────
  void Function(CallState state)?          onStateChanged;
  void Function(MediaStream stream)?       onRemoteStream;
  void Function(MediaStream stream)?       onLocalStream;
  void Function(String callId, String fromUid, String callType)? onIncomingCall;
  /// Вызывается когда пользователь отказал в разрешении — UI может показать snackbar.
  void Function(String reason)? onPermissionDenied;

  // ── StreamSubscription на сообщения сокета ─────────────────────────────────
  StreamSubscription? _socketSub;

  // ── STUN/TURN серверы ─────────────────────────────────────────────────────
  // Для продакшена: раскомментируй TURN-блок и подставь свои credentials.
  // Без TURN звонки за симметричным NAT (корп. Wi-Fi, некоторые операторы) не пройдут.
  //
  // Рекомендуемые сервисы:
  //   • Cloudflare TURN  — бесплатный тир
  //   • Twilio TURN      — $0.0004/мин
  //   • Свой coturn       — бесплатно, нужен VPS
  static const Map<String, dynamic> _iceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      // ── TURN (раскомментируй для продакшена) ──────────────────────────
      // {
      //   'urls': [
      //     'turn:your-turn-server.com:3478?transport=udp',
      //     'turn:your-turn-server.com:3478?transport=tcp',
      //     'turns:your-turn-server.com:5349?transport=tcp',
      //   ],
      //   'username':   'your-username',
      //   'credential': 'your-credential',
      // },
    ],
  };

  // ═══════════════════════════════════════════════════════════════════════════
  // Разрешения
  // ═══════════════════════════════════════════════════════════════════════════

  /// Запрашивает разрешения на микрофон (+ камеру для видео) и bluetooth.
  /// Возвращает true если все необходимые разрешения получены.
  Future<bool> _requestPermissions({required bool needVideo}) async {
    final permissions = <Permission>[
      Permission.microphone,
      if (needVideo) Permission.camera,
      Permission.bluetoothConnect,
    ];

    final statuses = await permissions.request();

    final micGranted = statuses[Permission.microphone]?.isGranted ?? false;
    final camGranted = needVideo
        ? (statuses[Permission.camera]?.isGranted ?? false)
        : true;

    if (!micGranted) {
      debugPrint('❌ Microphone permission denied');
      onPermissionDenied?.call(needVideo
          ? 'Для звонка нужен доступ к микрофону и камере'
          : 'Для звонка нужен доступ к микрофону');
      return false;
    }

    if (!camGranted) {
      debugPrint('❌ Camera permission denied');
      onPermissionDenied?.call('Для видеозвонка нужен доступ к камере');
      return false;
    }

    // Bluetooth — не критично, звонок работает и без него
    if (statuses[Permission.bluetoothConnect]?.isDenied == true) {
      debugPrint('⚠️ Bluetooth permission denied — headset switching unavailable');
    }

    return true;
  }

  /// Проверяет разрешения без запроса (для UI — показать кнопку или нет).
  Future<bool> hasCallPermissions({bool video = false}) async {
    final mic = await Permission.microphone.isGranted;
    final cam = video ? await Permission.camera.isGranted : true;
    return mic && cam;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Публичный API
  // ═══════════════════════════════════════════════════════════════════════════

  /// Инициализация — вызвать один раз при старте (после подключения к сокету).
  void init(String myUid) {
    _myUid = myUid;
    _socketSub?.cancel();
    _socketSub = _socket.messages.listen(_handleSocketMessage);
  }

  /// Завершение — вызвать при dispose.
  void dispose() {
    _socketSub?.cancel();
    _socketSub = null;
    hangUp();
  }

  /// Начать исходящий вызов.
  /// Возвращает false если разрешения не получены.
  Future<bool> startCall(String targetUid, {String callType = 'audio'}) async {
    if (_state != CallState.idle) {
      debugPrint('📞 Cannot start call: already in state $_state');
      return false;
    }

    // ── Запрос разрешений ────────────────────────────────────────────────
    final granted = await _requestPermissions(needVideo: callType == 'video');
    if (!granted) {
      debugPrint('📞 Call aborted: permissions not granted');
      return false;
    }

    _callId    = DateTime.now().millisecondsSinceEpoch.toString();
    _remoteUid = targetUid;
    _callType  = callType;
    _setState(CallState.outgoing);

    try {
      await _createPeerConnection();
      await _getUserMedia();

      final offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': callType == 'video',
      });
      await _peerConnection!.setLocalDescription(offer);

      _socket.send({
        'type':       'call_offer',
        'target_uid': targetUid,
        'call_id':    _callId,
        'call_type':  callType,
        'sdp':        offer.toMap(),
      });

      debugPrint('📞 Call offer sent to $targetUid (type: $callType)');
      return true;
    } catch (e) {
      debugPrint('❌ startCall error: $e');
      _cleanup();
      return false;
    }
  }

  /// Принять входящий вызов.
  /// Возвращает false если разрешения не получены.
  Future<bool> acceptCall() async {
    if (_state != CallState.incoming || _peerConnection == null) return false;

    // ── Запрос разрешений ────────────────────────────────────────────────
    final granted = await _requestPermissions(needVideo: _callType == 'video');
    if (!granted) {
      debugPrint('📞 Accept aborted: permissions not granted');
      rejectCall(); // не можем принять без микрофона — отклоняем
      return false;
    }

    _setState(CallState.connecting);

    try {
      await _getUserMedia();

      final answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': _callType == 'video',
      });
      await _peerConnection!.setLocalDescription(answer);

      _socket.send({
        'type':       'call_answer',
        'target_uid': _remoteUid,
        'call_id':    _callId,
        'sdp':        answer.toMap(),
      });

      // Flush буферизованные ICE-кандидаты
      _flushPendingCandidates();

      debugPrint('📞 Call accepted, answer sent');
      return true;
    } catch (e) {
      debugPrint('❌ acceptCall error: $e');
      _cleanup();
      return false;
    }
  }

  /// Отклонить входящий вызов.
  void rejectCall() {
    if (_state != CallState.incoming) return;

    _socket.send({
      'type':       'call_reject',
      'target_uid': _remoteUid,
      'call_id':    _callId,
      'reason':     'rejected',
    });

    _cleanup();
    debugPrint('📞 Call rejected');
  }

  /// Завершить вызов (из любого состояния).
  void hangUp() {
    if (_state == CallState.idle || _state == CallState.ended) return;

    if (_remoteUid != null && _callId != null) {
      _socket.send({
        'type':       'call_end',
        'target_uid': _remoteUid,
        'call_id':    _callId,
      });
    }

    _cleanup();
    debugPrint('📞 Call ended');
  }

  // ── Управление медиа ──────────────────────────────────────────────────────

  void toggleMute() {
    if (_localStream == null) return;
    _isMuted = !_isMuted;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    _setState(_state); // trigger UI update
  }

  void toggleSpeaker() {
    _isSpeakerOn = !_isSpeakerOn;
    Helper.setSpeakerphoneOn(_isSpeakerOn);
    _setState(_state);
  }

  void toggleVideo() {
    if (_localStream == null || _callType != 'video') return;
    _isVideoEnabled = !_isVideoEnabled;
    for (final track in _localStream!.getVideoTracks()) {
      track.enabled = _isVideoEnabled;
    }
    _setState(_state);
  }

  void switchCamera() {
    if (_localStream == null || _callType != 'video') return;
    final videoTrack = _localStream!.getVideoTracks().firstOrNull;
    if (videoTrack != null) {
      Helper.switchCamera(videoTrack);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Обработка сигнальных сообщений
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleSocketMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;

    switch (type) {
      case 'call_offer':
        _handleCallOffer(data);
        break;
      case 'call_answer':
        _handleCallAnswer(data);
        break;
      case 'call_reject':
        _handleCallReject(data);
        break;
      case 'call_end':
        _handleCallEnd(data);
        break;
      case 'call_busy':
        _handleCallBusy(data);
        break;
      case 'ice_candidate':
        _handleIceCandidate(data);
        break;
    }
  }

  Future<void> _handleCallOffer(Map<String, dynamic> data) async {
    final fromUid  = data['from_uid'] as String?;
    final callId   = data['call_id'] as String?;
    final callType = data['call_type'] as String? ?? 'audio';
    final sdp      = data['sdp'] as Map<String, dynamic>?;

    if (fromUid == null || callId == null || sdp == null) return;

    // Если уже в вызове — отправляем busy
    if (_state != CallState.idle) {
      _socket.send({
        'type':       'call_busy',
        'target_uid': fromUid,
        'call_id':    callId,
      });
      debugPrint('📞 Sent busy to $fromUid (already in call)');
      return;
    }

    _callId    = callId;
    _remoteUid = fromUid;
    _callType  = callType;

    await _createPeerConnection();

    final description = RTCSessionDescription(sdp['sdp'], sdp['type']);
    await _peerConnection!.setRemoteDescription(description);

    _setState(CallState.incoming);
    onIncomingCall?.call(callId, fromUid, callType);

    debugPrint('📞 Incoming call from $fromUid (type: $callType)');
  }

  Future<void> _handleCallAnswer(Map<String, dynamic> data) async {
    final sdp = data['sdp'] as Map<String, dynamic>?;
    if (sdp == null || _peerConnection == null) return;

    final description = RTCSessionDescription(sdp['sdp'], sdp['type']);
    await _peerConnection!.setRemoteDescription(description);

    _flushPendingCandidates();

    _setState(CallState.connecting);
    debugPrint('📞 Call answer received, connecting...');
  }

  void _handleCallReject(Map<String, dynamic> data) {
    debugPrint('📞 Call rejected by remote');
    _cleanup();
  }

  void _handleCallEnd(Map<String, dynamic> data) {
    debugPrint('📞 Call ended by remote');
    _cleanup();
  }

  void _handleCallBusy(Map<String, dynamic> data) {
    debugPrint('📞 Remote is busy');
    _cleanup();
  }

  Future<void> _handleIceCandidate(Map<String, dynamic> data) async {
    final candidateMap = data['candidate'] as Map<String, dynamic>?;
    if (candidateMap == null) return;

    final candidate = RTCIceCandidate(
      candidateMap['candidate'],
      candidateMap['sdpMid'],
      candidateMap['sdpMLineIndex'],
    );

    if (_peerConnection?.getRemoteDescription() != null) {
      await _peerConnection!.addCandidate(candidate);
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // WebRTC internals
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection(_iceConfig);

    _peerConnection!.onIceCandidate = (candidate) {
      _socket.send({
        'type':       'ice_candidate',
        'target_uid': _remoteUid,
        'call_id':    _callId,
        'candidate':  candidate.toMap(),
      });
    };

    _peerConnection!.onIceConnectionState = (state) {
      debugPrint('📞 ICE state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _callStartTime = DateTime.now();
        _setState(CallState.active);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
                 state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        Future.delayed(const Duration(seconds: 5), () {
          if (_state == CallState.active) {
            debugPrint('📞 ICE disconnect, waiting for recovery...');
          }
        });
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _cleanup();
      }
    };

    _peerConnection!.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        onRemoteStream?.call(_remoteStream!);
        _setState(_state);
      }
    };

    // Fallback для старых версий — onAddStream
    // ignore: deprecated_member_use
    _peerConnection!.onAddStream = (stream) {
      _remoteStream = stream;
      onRemoteStream?.call(stream);
      _setState(_state);
    };
  }

  Future<void> _getUserMedia() async {
    final constraints = <String, dynamic>{
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl':  true,
      },
      'video': _callType == 'video'
          ? {'facingMode': 'user', 'width': 640, 'height': 480}
          : false,
    };

    _localStream = await navigator.mediaDevices.getUserMedia(constraints);
    onLocalStream?.call(_localStream!);

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    // При голосовом вызове — выключаем динамик по умолчанию (к уху)
    if (_callType == 'audio') {
      Helper.setSpeakerphoneOn(false);
      _isSpeakerOn = false;
    }
  }

  void _flushPendingCandidates() {
    for (final c in _pendingCandidates) {
      _peerConnection?.addCandidate(c);
    }
    _pendingCandidates.clear();
  }

  void _setState(CallState newState) {
    _state = newState;
    onStateChanged?.call(newState);
  }

  void _cleanup() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;

    _remoteStream?.dispose();
    _remoteStream = null;

    _peerConnection?.close();
    _peerConnection?.dispose();
    _peerConnection = null;

    _pendingCandidates.clear();
    _callStartTime = null;
    _isMuted       = false;
    _isSpeakerOn   = false;
    _isVideoEnabled = true;

    _callId    = null;
    _remoteUid = null;

    _setState(CallState.ended);

    // Через секунду сбрасываем в idle
    Future.delayed(const Duration(seconds: 1), () {
      if (_state == CallState.ended) {
        _setState(CallState.idle);
      }
    });
  }
}
