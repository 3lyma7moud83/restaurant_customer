// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_util' as js_util;

typedef WebNotificationTapHandler = void Function(Map<String, String> data);
typedef WebNotificationLifecycleHandler = void Function(
  String event,
  Map<String, String> data,
  Map<String, dynamic> metadata,
);

const String _messagingServiceWorkerFileName = 'firebase-messaging-sw.js';

WebNotificationTapHandler? _notificationTapHandler;
WebNotificationLifecycleHandler? _notificationLifecycleHandler;
bool _notificationBridgeInitialized = false;
StreamSubscription<dynamic>? _serviceWorkerMessageSubscription;
StreamSubscription<html.Event>? _onlineSubscription;
StreamSubscription<html.Event>? _visibilitySubscription;

Future<void> ensureWebMessagingServiceWorkerReady() async {
  final serviceWorker = html.window.navigator.serviceWorker;
  if (serviceWorker == null) {
    return;
  }

  final scriptUrl = _resolveMessagingServiceWorkerScriptUrl();
  final scope = _resolveMessagingServiceWorkerScope();

  await _awaitBootstrapServiceWorkerReadyPromise();

  try {
    await serviceWorker.register(
      scriptUrl,
      <String, dynamic>{'scope': scope},
    );
  } catch (_) {
    // Keep going and rely on any existing registration.
    try {
      await serviceWorker.register(_messagingServiceWorkerFileName);
    } catch (_) {
      // Ignore fallback failures and continue with existing registrations.
    }
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

String? currentWebUserAgent() {
  return html.window.navigator.userAgent;
}

Future<void> initializeWebNotificationBridge({
  required WebNotificationTapHandler onNotificationTap,
  WebNotificationLifecycleHandler? onLifecycleEvent,
}) async {
  _notificationTapHandler = onNotificationTap;
  _notificationLifecycleHandler = onLifecycleEvent;
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
    final decoded = _decodeMessage(messageEvent.data);
    final clickPayload = _extractNotificationClickPayload(decoded);
    if (clickPayload.isNotEmpty) {
      _notificationTapHandler?.call(clickPayload);
      return;
    }

    final lifecycle = _extractNotificationLifecyclePayload(decoded);
    if (lifecycle == null) {
      return;
    }
    _notificationLifecycleHandler?.call(
      lifecycle.event,
      lifecycle.data,
      lifecycle.metadata,
    );
    _applyLifecycleSideEffects(lifecycle);
  });

  _onlineSubscription ??= html.window.onOnline.listen((_) {
    unawaited(_requestServiceWorkerRecovery('online'));
  });
  _visibilitySubscription ??= html.document.onVisibilityChange.listen((_) {
    if (html.document.visibilityState == 'visible') {
      unawaited(_requestServiceWorkerRecovery('document_visible'));
    }
  });
  unawaited(_requestServiceWorkerRecovery('bridge_initialized'));
}

Future<bool> showForegroundWebNotification({
  required String title,
  required String body,
  required Map<String, String> data,
  String? tag,
}) async {
  return false;
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
  if (raw is! Map) {
    return const {};
  }

  final type = raw['type']?.toString();
  if (type != 'fcm_notification_click') {
    return const {};
  }

  final rawData = raw['data'];
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

_LifecycleMessage? _extractNotificationLifecyclePayload(dynamic raw) {
  if (raw is! Map) {
    return null;
  }

  final type = raw['type']?.toString();
  if (type != 'fcm_notification_lifecycle') {
    return null;
  }

  final event = raw['event']?.toString().trim();
  if (event == null || event.isEmpty) {
    return null;
  }

  final rawData = raw['data'];
  final data = rawData is Map
      ? rawData.map(
          (key, value) => MapEntry(
            key.toString(),
            value == null ? '' : value.toString(),
          ),
        )
      : <String, String>{};
  data.removeWhere((_, value) => value.trim().isEmpty);

  return _LifecycleMessage(
    event: event,
    data: data,
    metadata: _normalizeMetadata(raw['meta']),
  );
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

Map<String, dynamic> _normalizeMetadata(dynamic raw) {
  if (raw is! Map) {
    return const {};
  }
  return raw.map((key, value) => MapEntry(key.toString(), value));
}

void _applyLifecycleSideEffects(_LifecycleMessage lifecycle) {
  final badgeCount = _intFromMetadata(lifecycle.metadata['badge_count']);
  if (badgeCount != null) {
    _setAppBadge(badgeCount);
  }

  final recovered = lifecycle.metadata['recovered'] == true ||
      lifecycle.metadata['recovered']?.toString() == 'true';
  if (recovered) {
    return;
  }

  if (lifecycle.event == 'displayed') {
    _vibrateIfSupported();
  }
}

void _vibrateIfSupported() {
  try {
    if (!js_util.hasProperty(html.window.navigator, 'vibrate')) {
      return;
    }
    js_util.callMethod<Object?>(
      html.window.navigator,
      'vibrate',
      [
        <int>[200, 100, 200],
      ],
    );
  } catch (_) {
    // Browser vibration support is optional.
  }
}

void _setAppBadge(int count) {
  try {
    if (count > 0 &&
        js_util.hasProperty(html.window.navigator, 'setAppBadge')) {
      js_util.callMethod<Object?>(
        html.window.navigator,
        'setAppBadge',
        [count],
      );
      return;
    }
    if (count == 0 &&
        js_util.hasProperty(html.window.navigator, 'clearAppBadge')) {
      js_util.callMethod<Object?>(
        html.window.navigator,
        'clearAppBadge',
        const [],
      );
    }
  } catch (_) {
    // The Badging API is optional.
  }
}

int? _intFromMetadata(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

Future<void> _requestServiceWorkerRecovery(String reason) async {
  final serviceWorker = html.window.navigator.serviceWorker;
  if (serviceWorker == null) {
    return;
  }

  final message = jsonEncode({
    'type': 'fcm_recovery_request',
    'reason': reason,
  });

  try {
    serviceWorker.controller?.postMessage(message);
  } catch (_) {
    // Fall through to the ready registration path.
  }

  try {
    final registration =
        await serviceWorker.ready.timeout(const Duration(seconds: 8));
    final active = js_util.getProperty<Object?>(registration, 'active');
    if (active != null) {
      js_util.callMethod<Object?>(active, 'postMessage', [message]);
    }
  } catch (_) {
    // Recovery is best-effort and retried on visibility/online events.
  }
}

Future<void> _awaitBootstrapServiceWorkerReadyPromise() async {
  try {
    final readyPromise = js_util.getProperty<Object?>(
      html.window,
      '__fcmServiceWorkerReady',
    );
    if (readyPromise == null) {
      return;
    }
    await js_util
        .promiseToFuture<Object?>(readyPromise)
        .timeout(const Duration(seconds: 8));
  } catch (_) {
    // Keep going and register from Dart side.
  }
}

String _resolveMessagingServiceWorkerScriptUrl() {
  final fromMeta = _stringFromBootstrapMeta('scriptUrl');
  if (fromMeta != null && fromMeta.isNotEmpty) {
    return fromMeta;
  }
  return Uri.base.resolve(_messagingServiceWorkerFileName).toString();
}

String _resolveMessagingServiceWorkerScope() {
  final fromMeta = _stringFromBootstrapMeta('scope');
  if (fromMeta != null && fromMeta.isNotEmpty) {
    return fromMeta;
  }

  final basePath = Uri.base.path;
  if (basePath.isEmpty) {
    return '/';
  }
  if (basePath.endsWith('/')) {
    return basePath;
  }

  final lastSlash = basePath.lastIndexOf('/');
  if (lastSlash < 0) {
    return '/';
  }
  final normalized = basePath.substring(0, lastSlash + 1);
  return normalized.isEmpty ? '/' : normalized;
}

String? _stringFromBootstrapMeta(String key) {
  try {
    final meta = js_util.getProperty<Object?>(
      html.window,
      '__fcmServiceWorkerMeta',
    );
    if (meta == null) {
      return null;
    }
    final value = js_util.getProperty<Object?>(meta, key);
    if (value == null) {
      return null;
    }
    final normalized = value.toString().trim();
    if (normalized.isEmpty) {
      return null;
    }
    return normalized;
  } catch (_) {
    return null;
  }
}

class _LifecycleMessage {
  const _LifecycleMessage({
    required this.event,
    required this.data,
    required this.metadata,
  });

  final String event;
  final Map<String, String> data;
  final Map<String, dynamic> metadata;
}
