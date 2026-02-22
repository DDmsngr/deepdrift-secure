import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';
import 'dart:convert';
import '../services/crypto_service.dart';

class ChatScreen extends StatefulWidget {
  final String targetUID;
  final String myUID;
  ChatScreen({required this.targetUID, required this.myUID});

  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late IOWebSocketChannel channel;
  final crypto = CryptoService();
  final TextEditingController _msgC = TextEditingController();
  List<Map<String, dynamic>> messages = [];
  dynamic chatKey;

  @override
  void initState() {
    super.initState();
    // В MVP пароль чата фиксирован, в идеале вводится при открытии
    crypto.deriveKey("shared_secret_password").then((key) => chatKey = key);
    
    // Подключаемся к Render или локалке
    channel = IOWebSocketChannel.connect("wss://deepdrift-backend.onrender.com/ws/${widget.myUID}");
    
    channel.stream.listen((event) async {
      var data = jsonDecode(event);
      if (data['payload'] != null) {
        String decrypted = await crypto.decrypt(data['payload'], chatKey);
        setState(() {
          messages.add({"text": decrypted, "isMe": false, "sig": data['fhrg_sig']});
        });
      }
    });
  }

  _send() async {
    if (_msgC.text.isEmpty) return;
    String encrypted = await crypto.encrypt(_msgC.text, chatKey);
    String sig = crypto.generateFHRGSignature(_msgC.text);

    channel.sink.add(jsonEncode({
      "target_uid": widget.targetUID,
      "payload": encrypted,
      "fhrg_sig": sig
    }));

    setState(() {
      messages.add({"text": _msgC.text, "isMe": true});
    });
    _msgC.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF0A0E17),
      appBar: AppBar(title: Text("Chat with ${widget.targetUID}")),
      body: Column(
        children: [
          Expanded(child: ListView.builder(
            itemCount: messages.length,
            itemBuilder: (c, i) => Align(
              alignment: messages[i]['isMe'] ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: EdgeInsets.all(8),
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: messages[i]['isMe'] ? Color(0xFF1A1F3C) : Colors.black,
                  border: Border.all(color: Color(0xFF00F0FF).withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(12)
                ),
                child: Text(messages[i]['text'], style: TextStyle(color: Colors.white)),
              ),
            ),
          )),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(child: TextField(controller: _msgC, style: TextStyle(color: Colors.white))),
                IconButton(icon: Icon(Icons.send, color: Color(0xFF00F0FF)), onPressed: _send)
              ],
            ),
          )
        ],
      ),
    );
  }
}
