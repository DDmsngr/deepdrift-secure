import 'package:flutter/material.dart';
import '../services/identity_service.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String myUID = "...";
  List<String> contacts = [];
  final idService = IdentityService();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  _loadData() async {
    final uid = await idService.getMyUID();
    final list = await idService.getContacts();
    setState(() {
      myUID = uid;
      contacts = list;
    });
  }

  _addNewChat() {
    TextEditingController _c = TextEditingController();
    showDialog(context: context, builder: (c) => AlertDialog(
      title: Text("New Chat (Enter UIN)"),
      content: TextField(controller: _c, keyboardType: TextInputType.number),
      actions: [
        TextButton(onPressed: () async {
          await idService.saveContact(_c.text);
          Navigator.pop(context);
          _loadData();
        }, child: Text("Add"))
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF0A0E17),
      appBar: AppBar(title: Text("DeepDrift UIN: $myUID"), backgroundColor: Color(0xFF1A1F3C)),
      body: ListView.builder(
        itemCount: contacts.length,
        itemBuilder: (c, i) => ListTile(
          leading: CircleAvatar(child: Text("ID")),
          title: Text(contacts[i], style: TextStyle(color: Colors.white)),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => ChatScreen(targetUID: contacts[i], myUID: myUID))),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addNewChat,
        child: Icon(Icons.message),
        backgroundColor: Color(0xFF00F0FF),
      ),
    );
  }
}
