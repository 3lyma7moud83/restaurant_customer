import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/ui/app_snackbar.dart';
import '../core/ui/input_focus_guard.dart';
import '../services/session_manager.dart';

@visibleForTesting
List<Map<String, dynamic>> mergeOrderChatMessages(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> next,
) {
  final byId = <String, Map<String, dynamic>>{
    for (final message in current)
      if ((message['id']?.toString() ?? '').isNotEmpty)
        message['id'].toString(): message,
  };
  for (final message in next) {
    final id = message['id']?.toString() ?? '';
    if (id.isNotEmpty) {
      byId[id] = message;
    }
  }

  final merged = byId.values.toList(growable: false)
    ..sort((a, b) {
      final createdAt = (a['created_at']?.toString() ?? '').compareTo(
        b['created_at']?.toString() ?? '',
      );
      if (createdAt != 0) {
        return createdAt;
      }
      return (a['id']?.toString() ?? '').compareTo(b['id']?.toString() ?? '');
    });
  return merged;
}

class OrderChatPage extends StatefulWidget {
  const OrderChatPage({super.key, required this.orderId});

  final String orderId;

  @override
  State<OrderChatPage> createState() => _OrderChatPageState();
}

class _OrderChatPageState extends State<OrderChatPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _supabase = Supabase.instance.client;
  final Set<String> _messageIds = <String>{};
  static const int _pageSize = 50;

  late final RealtimeChannelController _chatChannelController;
  List<Map<String, dynamic>> messages = [];
  bool _loadingOlderMessages = false;
  bool _hasOlderMessages = true;
  int _loadedMessagePages = 0;

  @override
  void initState() {
    super.initState();
    _chatChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'order-chat-${widget.orderId}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          await _load();
        }
      },
    );
    _listenRealtime();
    unawaited(_load());
    _scrollController.addListener(_maybeLoadOlderMessages);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController
      ..removeListener(_maybeLoadOlderMessages)
      ..dispose();
    unawaited(_chatChannelController.dispose());
    super.dispose();
  }

  Future<void> _load({bool loadOlder = false}) async {
    if (loadOlder && (_loadingOlderMessages || !_hasOlderMessages)) {
      return;
    }
    if (loadOlder) {
      _loadingOlderMessages = true;
    }
    try {
      final page = loadOlder ? _loadedMessagePages : 0;
      final from = page * _pageSize;
      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _supabase
            .from('order_messages')
            .select('id, sender_id, message, created_at')
            .eq('order_id', widget.orderId)
            .order('created_at', ascending: false)
            .order('id', ascending: false)
            .range(from, from + _pageSize - 1),
        requireSession: true,
      );
      if (res == null || !mounted) {
        return;
      }

      final nextMessages = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);

      final merged = mergeOrderChatMessages(messages, nextMessages);
      _messageIds.addAll(
        merged.map((m) => m['id']?.toString() ?? '').where(
              (id) => id.isNotEmpty,
            ),
      );
      _loadedMessagePages = loadOlder ? _loadedMessagePages + 1 : 1;
      _hasOlderMessages = nextMessages.length == _pageSize;
      setState(() => messages = merged);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'order_chat_page.load',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _toast(ErrorLogger.userMessage);
      }
    } finally {
      _loadingOlderMessages = false;
    }
  }

  void _maybeLoadOlderMessages() {
    if (!_scrollController.hasClients ||
        _scrollController.position.extentBefore > 120) {
      return;
    }
    unawaited(_load(loadOlder: true));
  }

  void _listenRealtime() {
    _chatChannelController.subscribe((client, channelName) {
      return client.channel(channelName).onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'order_messages',
            filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'order_id',
              value: widget.orderId,
            ),
            callback: (payload) {
              if (!mounted) {
                return;
              }
              final newMsg = Map<String, dynamic>.from(payload.newRecord);
              final id = newMsg['id']?.toString() ?? '';
              if (id.isEmpty || _messageIds.contains(id)) {
                return;
              }
              final merged = mergeOrderChatMessages(messages, [newMsg]);
              _messageIds.add(id);
              setState(() {
                messages = merged;
              });
            },
          );
    });
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      return;
    }

    try {
      final sent = await SessionManager.instance.runWithValidSession<bool>(
        () async {
          await _supabase.from('order_messages').insert({
            'order_id': widget.orderId,
            'sender_id': userId,
            'message': text,
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

  void _toast(String message) {
    AppSnackBar.show(context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الشات')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: messages.length,
              itemBuilder: (_, i) {
                final msg = messages[i];

                final userId = _supabase.auth.currentUser?.id;
                final mine = userId != null && msg['sender_id'] == userId;

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
                    child: Text((msg['message'] ?? '').toString()),
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
          ),
        ],
      ),
    );
  }
}
