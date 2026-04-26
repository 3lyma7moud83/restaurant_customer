// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

typedef WebNotificationTapHandler = void Function(Map<String, String> data);

WebNotificationTapHandler? _notificationTapHandler;
bool _notificationBridgeInitialized = false;
StreamSubscription<dynamic>? _serviceWorkerMessageSubscription;

Future<void> ensureWebMessagingServiceWorkerReady() async {
  final serviceWorker = html.window.navigator.serviceWorker;
  if (serviceWorker == null) {
    return;
  }

  try {
    await serviceWorker.register('firebase-messaging-sw.js');
  } catch (_) {
    // Keep going and rely on any existing registration.
  }

  try {
    await serviceWorker.ready.timeout(const Duration(seconds: 8));
  } catch (_) {
    // Token generation can still succeed when SW ready times out in slow browsers.
  }
}

Future<String?> ensureWebNotificationPermission() async {
  if (!html.Notification.supported) {
    return null;
  }

  final currentPermission = html.Notification.permission;
  if (currentPermission == 'granted' || currentPermission == 'denied') {
    return currentPermission;
  }

  try {
    return await html.Notification.requestPermission()
        .timeout(const Duration(seconds: 12));
  } on TimeoutException {
    return currentPermission;
  } catch (_) {
    return currentPermission;
  }
}

String? currentWebNotificationPermission() {
  if (!html.Notification.supported) {
    return null;
  }
  return html.Notification.permission;
}

bool supportsWebBrowserNotifications() {
  return html.Notification.supported;
}

bool isWebDocumentVisible() {
  return html.document.visibilityState == 'visible';
}

Future<void> initializeWebNotificationBridge({
  required WebNotificationTapHandler onNotificationTap,
}) async {
  _notificationTapHandler = onNotificationTap;
  if (_notificationBridgeInitialized) {
    return;
  }
  _notificationBridgeInitialized = true;

  final serviceWorker = html.window.navigator.serviceWorker;
  if (serviceWorker == null) {
    return;
  }

  _serviceWorkerMessageSubscription ??=
      serviceWorker.onMessage.listen((html.MessageEvent messageEvent) {
    final payload = _extractNotificationClickPayload(messageEvent.data);
    if (payload.isEmpty) {
      return;
    }
    _notificationTapHandler?.call(payload);
  });
}

Future<bool> showForegroundWebNotification({
  required String title,
  required String body,
  required Map<String, String> data,
  String? tag,
}) async {
  if (!html.Notification.supported) {
    return false;
  }
  if (html.Notification.permission != 'granted') {
    return false;
  }

  try {
    await ensureWebMessagingServiceWorkerReady();
    final registration = await html.window.navigator.serviceWorker?.ready;
    if (registration != null) {
      final options = <String, dynamic>{
        'body': body,
        'icon': '/icons/Icon-192.png',
        'badge': '/icons/Icon-192.png',
        if (tag != null && tag.trim().isNotEmpty) 'tag': tag,
        if (data.isNotEmpty) 'data': data,
        'requireInteraction': true,
        'renotify': true,
      };
      await (registration as dynamic).showNotification(title, options);
      return true;
    }
  } catch (_) {
    // Fallback to direct Notification API if service worker path fails.
  }

  try {
    final notification = html.Notification(
      title,
      body: body,
      icon: '/icons/Icon-192.png',
      tag: tag,
    );
    notification.onClick.listen((_) {
      notification.close();
      _notificationTapHandler?.call(data);
    });
    return true;
  } catch (_) {
    return false;
  }
}

void clearWebLaunchNotificationQueryParameters() {
  final uri = Uri.base;
  if (uri.queryParameters.isEmpty) {
    return;
  }

  final nextQuery = Map<String, String>.from(uri.queryParameters);
  final removedScreen = nextQuery.remove('screen') != null;
  final removedClickAction = nextQuery.remove('click_action') != null;
  if (!removedScreen && !removedClickAction) {
    return;
  }

  final nextUri = Uri(
    path: uri.path.isEmpty ? '/' : uri.path,
    queryParameters: nextQuery.isEmpty ? null : nextQuery,
    fragment: uri.fragment.isEmpty ? null : uri.fragment,
  );
  html.window.history
      .replaceState(null, html.document.title, nextUri.toString());
}

Map<String, String> _extractNotificationClickPayload(dynamic raw) {
  final decoded = _decodeMessage(raw);
  if (decoded is! Map) {
    return const {};
  }

  final type = decoded['type']?.toString();
  if (type != 'fcm_notification_click') {
    return const {};
  }

  final rawData = decoded['data'];
  if (rawData is! Map) {
    return const {};
  }

  return rawData.map(
    (key, value) => MapEntry(
      key.toString(),
      value == null ? '' : value.toString(),
    ),
  )..removeWhere((_, value) => value.trim().isEmpty);
}

dynamic _decodeMessage(dynamic value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
  }
  return value;
}
