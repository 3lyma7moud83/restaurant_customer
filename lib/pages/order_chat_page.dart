import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import '../core/ui/app_snackbar.dart';
import '../core/ui/input_focus_guard.dart';
import '../services/session_manager.dart';

class OrderChatPage extends StatefulWidget {
  final String orderId;

  const OrderChatPage({super.key, required this.orderId});

  @override
  State<OrderChatPage> createState() => _OrderChatPageState();
}

class _OrderChatPageState extends State<OrderChatPage> {
  final _controller = TextEditingController();
  final _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> messages = [];
  final Set<String> _messageIds = <String>{};
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _listenRealtime();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    if (_channel != null) {
      unawaited(_disposeChannel());
    }
    super.dispose();
  }

  //================================
  // load old messages
  //================================
  Future<void> _load() async {
    try {
      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _supabase
            .from("order_messages")
            .select('id, sender_id, message, created_at')
            .eq("order_id", widget.orderId)
            .order("created_at"),
        requireSession: true,
      );
      if (res == null || !mounted) return;

      final nextMessages = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

      _messageIds
        ..clear()
        ..addAll(
          nextMessages
              .map((m) => m['id']?.toString() ?? '')
              .where((id) => id.isNotEmpty),
        );

      setState(() => messages = nextMessages);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_chat_page.load',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _toast(ErrorLogger.userMessage);
      }
    }
  }

  //================================
  // realtime
  //================================
  void _listenRealtime() {
    _channel = _supabase
        .channel("chat-${widget.orderId}")
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'order_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'order_id',
            value: widget.orderId,
          ),
          callback: (payload) {
            if (!mounted) return;
            final newMsg = Map<String, dynamic>.from(payload.newRecord);
            final id = newMsg['id']?.toString() ?? '';
            if (id.isEmpty || _messageIds.contains(id)) return;
            _messageIds.add(id);
            setState(() {
              messages.add(newMsg);
            });
          },
        )
        .subscribe();
  }

  //================================
  // send
  //================================
  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;

    try {
      final sent = await SessionManager.instance.runWithValidSession<bool>(
        () async {
          await _supabase.from("order_messages").insert({
            "order_id": widget.orderId,
            "sender_id": userId,
            "message": text,
          });
          return true;
        },
        requireSession: true,
      );
      if (sent != true) {
        return;
      }

      _controller.clear();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_chat_page.send',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _toast(ErrorLogger.userMessage);
      }
    }
  }

  Future<void> _disposeChannel() async {
    try {
      await _supabase.removeChannel(_channel!);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_chat_page.disposeChannel',
        error: error,
        stack: stack,
      );
    }
  }

  void _toast(String message) {
    AppSnackBar.show(context, message: message);
  }

  //================================
  // UI
  //================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("الشات")),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: messages.length,
              itemBuilder: (_, i) {
                final msg = messages[i];

                final userId = _supabase.auth.currentUser?.id;
                final mine = userId != null && msg["sender_id"] == userId;

                return Align(
                  alignment:
                      mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.all(6),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: mine ? Colors.green : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text((msg["message"] ?? '').toString()),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onTapOutside: (_) => InputFocusGuard.dismiss(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _send,
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }
}
