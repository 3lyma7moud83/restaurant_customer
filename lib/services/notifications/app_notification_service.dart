import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_firebase_options.dart';
import '../../core/orders/order_status_utils.dart';
import '../../core/realtime/realtime_channel_controller.dart';
import '../../core/services/error_logger.dart';
import '../../core/stability/notification_dedupe_service.dart';
import '../../core/stability/rpc_security_service.dart';
import '../../core/stability/stability_metrics_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/input_focus_guard.dart';
import '../../pages/orders_page.dart';
import '../../pages/order_chat_page.dart';
import '../../pages/order_details_page.dart';
import '../../pages/order_tracking_page.dart';
import '../orders_service.dart';
import '../session_manager.dart';
import 'web_push_bridge.dart';

const Color _androidNotificationLedColor = Color(0xFF2E7D32);
const AndroidNotificationChannel _ordersNotificationChannel =
    AndroidNotificationChannel(
  'orders',
  'Orders',
  description: 'Order updates and delivery alerts.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  showBadge: true,
  enableLights: true,
  ledColor: _androidNotificationLedColor,
);
const AndroidNotificationChannel _messagesNotificationChannel =
    AndroidNotificationChannel(
  'messages',
  'Messages',
  description: 'Chat and customer message notifications.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  showBadge: true,
  enableLights: true,
  ledColor: _androidNotificationLedColor,
);
const AndroidNotificationChannel _generalNotificationChannel =
    AndroidNotificationChannel(
  'general',
  'General',
  description: 'General customer account notifications.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  showBadge: true,
  enableLights: true,
  ledColor: _androidNotificationLedColor,
);
const AndroidNotificationChannel _urgentNotificationChannel =
    AndroidNotificationChannel(
  'urgent',
  'Urgent',
  description: 'Urgent delivery and account notifications.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  showBadge: true,
  enableLights: true,
  ledColor: _androidNotificationLedColor,
);
const AndroidNotificationChannel _legacyHighImportanceNotificationChannel =
    AndroidNotificationChannel(
  'high_importance_channel',
  'Orders',
  description: 'Compatibility channel for server-sent Android order pushes.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  showBadge: true,
  enableLights: true,
  ledColor: _androidNotificationLedColor,
);
const String _androidNotificationIcon = 'ic_stat_notification';
const List<AndroidNotificationChannel> _androidNotificationChannels =
    <AndroidNotificationChannel>[
  _ordersNotificationChannel,
  _messagesNotificationChannel,
  _generalNotificationChannel,
  _urgentNotificationChannel,
  _legacyHighImportanceNotificationChannel,
];
const MethodChannel _androidNotificationSettingsChannel = MethodChannel(
  'restaurant_customer/android_notifications',
);

Future<void> _initializeAndroidLocalNotificationsForBackground(
  FlutterLocalNotificationsPlugin localNotifications,
) async {
  const androidSettings = AndroidInitializationSettings(
    _androidNotificationIcon,
  );
  await localNotifications.initialize(
    const InitializationSettings(android: androidSettings),
    onDidReceiveBackgroundNotificationResponse:
        localNotificationTapBackgroundHandler,
  );
  await _createAndroidNotificationChannels(localNotifications);
}

Future<void> _createAndroidNotificationChannels(
  FlutterLocalNotificationsPlugin localNotifications,
) async {
  final androidPlugin =
      localNotifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin == null) {
    return;
  }

  for (final channel in _androidNotificationChannels) {
    await androidPlugin.createNotificationChannel(channel);
  }
}

NotificationDetails _androidNotificationDetailsForPresentation(
  _AndroidNotificationPresentation presentation,
) {
  return _androidNotificationDetailsForChannel(
    presentation.channel,
    title: presentation.title,
    body: presentation.body,
    tag: presentation.notificationId,
    badgeCount: presentation.badgeCount,
    timestamp: presentation.timestamp,
  );
}

NotificationDetails _androidNotificationDetailsForChannel(
  AndroidNotificationChannel channel, {
  required String title,
  required String body,
  String? tag,
  int? badgeCount,
  DateTime? timestamp,
}) {
  return NotificationDetails(
    android: AndroidNotificationDetails(
      channel.id,
      channel.name,
      channelDescription: channel.description,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: _androidNotificationIcon,
      visibility: NotificationVisibility.public,
      channelShowBadge: true,
      enableLights: true,
      ledColor: _androidNotificationLedColor,
      ledOnMs: 1000,
      ledOffMs: 500,
      ticker: title,
      tag: tag,
      number: badgeCount,
      when: timestamp?.millisecondsSinceEpoch,
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: title,
      ),
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      badgeNumber: badgeCount,
    ),
  );
}

_AndroidNotificationPresentation? _buildAndroidNotificationPresentation(
  RemoteMessage message, {
  required String source,
}) {
  final data = _androidNormalizeMessageData(message);
  final androidNotification = message.notification?.android;
  final rawTitle = message.notification?.title ?? data['title'];
  final rawBody = message.notification?.body ?? data['body'];
  final title = _androidNormalizeBrandingText(
    _androidNormalizeDataValue(rawTitle) ?? '',
  );
  final body = _androidNormalizeBrandingText(
    _androidNormalizeDataValue(rawBody) ?? '',
  );
  if (title.isEmpty || body.isEmpty) {
    _logAndroidNotificationFlow('ERROR', {
      'source': source,
      'error': 'missing_title_or_body',
      'message_id': message.messageId,
      'data': data,
    });
    return null;
  }

  final messageId = _androidNormalizeDataValue(message.messageId) ??
      _androidNormalizeDataValue(data['message_id']) ??
      _androidNormalizeDataValue(data['google.message_id']);
  final notificationId = _androidNormalizeDataValue(data['notification_id']) ??
      messageId ??
      _androidStableDataSignature(data);
  if (notificationId.isEmpty) {
    _logAndroidNotificationFlow('ERROR', {
      'source': source,
      'error': 'missing_notification_id',
      'message_id': message.messageId,
    });
    return null;
  }

  final type = _androidResolveType(data);
  final channel = _androidResolveChannel(
    data,
    type: type,
    remoteChannelId: androidNotification?.channelId,
  );
  final resolvedClickAction = _androidResolveTargetPath(data);
  final originalClickAction = _androidNormalizeTargetPath(data['click_action']);
  final originalDeepLink = _androidNormalizeTargetPath(data['deep_link']);
  final payloadClickAction = originalClickAction ?? resolvedClickAction;
  final payloadDeepLink =
      originalDeepLink ?? originalClickAction ?? resolvedClickAction;
  final timestamp = _androidResolveTimestamp(data, message.sentTime);
  final badgeCount = _androidIntValue(
        data['badge_count'] ?? data['badge'] ?? data['count'],
      ) ??
      androidNotification?.count;
  final sound =
      _androidNormalizeDataValue(data['sound'] ?? androidNotification?.sound) ??
          'default';
  final priority = _androidNormalizeDataValue(data['priority']) ??
      _androidPriorityName(androidNotification?.priority) ??
      'high';
  final image = _androidNormalizeDataValue(
    data['image'] ??
        data['image_url'] ??
        data['picture'] ??
        androidNotification?.imageUrl,
  );

  final payload = <String, String>{
    ...data,
    'title': title,
    'body': body,
    'type': type,
    'notification_type': data['notification_type'] ?? type,
    'event': data['event'] ?? type,
    'notification_id': notificationId,
    if (messageId != null) 'message_id': messageId,
    if (payloadClickAction != null) 'click_action': payloadClickAction,
    if (payloadDeepLink != null) 'deep_link': payloadDeepLink,
    'timestamp': timestamp.toUtc().toIso8601String(),
    if (badgeCount != null) 'badge_count': badgeCount.toString(),
    'sound': sound,
    'priority': priority,
    'channel': _androidNormalizeDataValue(
          data['channel'] ??
              data['channel_id'] ??
              androidNotification?.channelId,
        ) ??
        channel.id,
    if (image != null) 'image': image,
    'android_received_by': 'AppNotificationService',
    'android_delivery_proof': source,
  };

  return _AndroidNotificationPresentation(
    title: title,
    body: body,
    payload: payload,
    notificationId: notificationId,
    messageId: messageId,
    type: type,
    channel: channel,
    timestamp: timestamp,
    badgeCount: badgeCount,
    dedupKey: 'notification:$notificationId',
    localNotificationId: _androidNotificationIdForKey(notificationId),
  );
}

Map<String, String> _androidNormalizeMessageData(RemoteMessage message) {
  final fromData = _androidNormalizeStringData(message.data);
  final fromStringifiedData = _androidNormalizeStringData(
    _androidParseJsonMap(message.data['data']),
  );
  final fromNestedData = _androidNormalizeStringData(
    _androidParseJsonMap(fromStringifiedData['data'] ?? fromData['data']),
  );
  return <String, String>{
    ...fromStringifiedData,
    ...fromNestedData,
    ...fromData,
  };
}

Map<String, dynamic> _androidParseJsonMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  final raw = _androidNormalizeDataValue(value);
  if (raw == null) {
    return const <String, dynamic>{};
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {
    return const <String, dynamic>{};
  }
  return const <String, dynamic>{};
}

Map<String, String> _androidNormalizeStringData(Map<dynamic, dynamic> rawData) {
  final normalized = <String, String>{};
  for (final entry in rawData.entries) {
    final key = entry.key.toString().trim();
    if (key.isEmpty) {
      continue;
    }
    final value = _androidNormalizeDataValue(entry.value);
    if (value == null) {
      continue;
    }
    normalized[key] = value;
  }
  return normalized;
}

String? _androidNormalizeDataValue(Object? raw) {
  if (raw == null) {
    return null;
  }
  var normalized = raw.toString().trim();
  if (normalized.isEmpty || normalized.toLowerCase() == 'null') {
    return null;
  }
  final hasWrappedDoubleQuotes =
      normalized.startsWith('"') && normalized.endsWith('"');
  final hasWrappedSingleQuotes =
      normalized.startsWith("'") && normalized.endsWith("'");
  if (hasWrappedDoubleQuotes || hasWrappedSingleQuotes) {
    normalized = normalized.substring(1, normalized.length - 1).trim();
  }
  if (normalized.isEmpty || normalized.toLowerCase() == 'null') {
    return null;
  }
  return normalized;
}

String _androidNormalizeBrandingText(String value) {
  if (value.isEmpty) {
    return value;
  }
  var normalized = value;
  normalized = normalized.replaceAllMapped(
    RegExp(r'support@delivery-mat3mk\.com', caseSensitive: false),
    (_) => 'support@deliverymat3mk.com',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'delivery-mat3mk', caseSensitive: false),
    (_) => 'Delivery Mat3mk',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'restaurant_(customer|driver|admin)', caseSensitive: false),
    (_) => 'Delivery Mat3mk',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'mat3amak', caseSensitive: false),
    (_) => 'Delivery Mat3mk',
  );
  return normalized;
}

String _androidResolveType(Map<String, String> data) {
  final candidate = _androidNormalizeDataValue(data['type']) ??
      _androidNormalizeDataValue(data['notification_type']) ??
      _androidNormalizeDataValue(data['event']) ??
      _androidNormalizeDataValue(data['status_key']) ??
      _androidNormalizeDataValue(data['status']);
  if (candidate != null) {
    return candidate.toLowerCase();
  }
  if (_androidNormalizeDataValue(data['order_id']) != null) {
    return 'order_status';
  }
  return 'general';
}

AndroidNotificationChannel _androidResolveChannel(
  Map<String, String> data, {
  required String type,
  String? remoteChannelId,
}) {
  final explicit = _androidNormalizeDataValue(
    data['channel'] ?? data['channel_id'] ?? remoteChannelId,
  )?.toLowerCase();
  final normalizedExplicit = switch (explicit) {
    'orders' || 'order' || 'orders-high-priority' => 'orders',
    'messages' || 'message' || 'chat' => 'messages',
    'urgent' || 'high' => 'urgent',
    'high_importance_channel' => 'high_importance_channel',
    'general' => 'general',
    _ => null,
  };
  if (normalizedExplicit != null) {
    return _androidChannelForId(normalizedExplicit);
  }

  final normalizedType = type.toLowerCase();
  final priority = (data['priority'] ?? '').toLowerCase();
  if (priority == 'urgent' ||
      normalizedType.contains('urgent') ||
      normalizedType.contains('priority')) {
    return _urgentNotificationChannel;
  }
  if (normalizedType.contains('chat') ||
      normalizedType.contains('message') ||
      _androidNormalizeDataValue(data['chat_id']) != null) {
    return _messagesNotificationChannel;
  }
  if (normalizedType.contains('order') ||
      normalizedType.contains('delivery') ||
      _androidNormalizeDataValue(data['order_id']) != null) {
    return _ordersNotificationChannel;
  }
  return _generalNotificationChannel;
}

AndroidNotificationChannel _androidChannelForId(String channelId) {
  return switch (channelId) {
    'messages' => _messagesNotificationChannel,
    'general' => _generalNotificationChannel,
    'urgent' => _urgentNotificationChannel,
    'high_importance_channel' => _legacyHighImportanceNotificationChannel,
    _ => _ordersNotificationChannel,
  };
}

String? _androidResolveTargetPath(Map<String, String> data) {
  final orderId = _androidNormalizeDataValue(data['order_id']);
  final trackingPath = orderId == null
      ? null
      : '/?screen=order_tracking&order_id=${Uri.encodeComponent(orderId)}';
  for (final key in const ['click_action', 'link', 'url', 'path', 'route']) {
    final normalized = _androidNormalizeTargetPath(data[key]);
    if (normalized == null) {
      continue;
    }
    return normalized;
  }

  final screen = _androidNormalizeDataValue(data['screen'])?.toLowerCase();
  if (screen != null) {
    final query = <String, String>{'screen': screen};
    if (orderId != null) {
      query['order_id'] = orderId;
    }
    return '/?${Uri(queryParameters: query).query}';
  }

  return trackingPath ?? '/';
}

String? _androidNormalizeTargetPath(Object? candidate) {
  final trimmed = _androidNormalizeDataValue(candidate);
  if (trimmed == null ||
      trimmed.toUpperCase() == 'FLUTTER_NOTIFICATION_CLICK') {
    return null;
  }

  if (RegExp(r'^(?:https?:)?//', caseSensitive: false).hasMatch(trimmed)) {
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isNotEmpty) {
      return null;
    }
  }
  if (RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false).hasMatch(trimmed)) {
    return null;
  }
  if (trimmed.startsWith('/')) {
    return trimmed;
  }
  if (trimmed.startsWith('?') || trimmed.startsWith('#')) {
    return '/$trimmed';
  }
  return '/$trimmed';
}

DateTime _androidResolveTimestamp(
  Map<String, String> data,
  DateTime? sentTime,
) {
  for (final key in const [
    'timestamp',
    'created_at',
    'updated_at',
    'sent_at',
    'pushed_at',
  ]) {
    final parsed = DateTime.tryParse(data[key] ?? '');
    if (parsed != null) {
      return parsed.toUtc();
    }
  }
  return sentTime?.toUtc() ?? DateTime.now().toUtc();
}

String? _androidPriorityName(AndroidNotificationPriority? priority) {
  return priority?.name;
}

int? _androidIntValue(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  final normalized = _androidNormalizeDataValue(value);
  if (normalized == null) {
    return null;
  }
  return int.tryParse(normalized);
}

int _androidNotificationIdForKey(String key) {
  return key.hashCode & 0x7fffffff;
}

String _androidStableDataSignature(Map<String, String> data) {
  if (data.isEmpty) {
    return '';
  }
  final entries = data.entries.toList(growable: false)
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((entry) => '${entry.key}=${entry.value}').join('&');
}

void _logAndroidNotificationFlow(
  String marker,
  Map<String, Object?> payload,
) {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  final normalizedMarker = marker.trim().toUpperCase();
  final safePayload = <String, Object?>{
    'at': DateTime.now().toUtc().toIso8601String(),
    for (final entry in payload.entries)
      if (entry.value != null) entry.key: entry.value,
  };
  try {
    debugPrint(
      'ANDROID_NOTIFICATION_$normalizedMarker ${jsonEncode(safePayload)}',
    );
  } catch (_) {
    debugPrint('ANDROID_NOTIFICATION_$normalizedMarker $safePayload');
  }
}

void _logBootstrapStartup(String message) {
  debugPrint('[bootstrap] $message');
}

class _AndroidNotificationPermissionStatus {
  const _AndroidNotificationPermissionStatus({
    required this.sdkInt,
    required this.notificationsEnabled,
    required this.postNotificationsGranted,
    required this.shouldShowPostNotificationsRationale,
  });

  final int sdkInt;
  final bool notificationsEnabled;
  final bool postNotificationsGranted;
  final bool shouldShowPostNotificationsRationale;

  bool get isAndroid13OrAbove => sdkInt >= 33;
}

class _AndroidNotificationPresentation {
  const _AndroidNotificationPresentation({
    required this.title,
    required this.body,
    required this.payload,
    required this.notificationId,
    required this.messageId,
    required this.type,
    required this.channel,
    required this.timestamp,
    required this.badgeCount,
    required this.dedupKey,
    required this.localNotificationId,
  });

  final String title;
  final String body;
  final Map<String, String> payload;
  final String notificationId;
  final String? messageId;
  final String type;
  final AndroidNotificationChannel channel;
  final DateTime timestamp;
  final int? badgeCount;
  final String dedupKey;
  final int localNotificationId;
}

const String _notificationTokensTable = 'customer_device_tokens';
const String _notificationTokenColumn = 'fcm_token';
const String _notificationTokenConflictColumns = 'user_id,fcm_token';
const String _registerTokenRpc = 'upsert_customer_device_token';
const String _deactivateTokenRpc = 'deactivate_customer_device_token';
const String _installationIdStorageKey =
    'customer_notification_installation_id';
const String _webPermissionPromptRequestedStorageKey =
    'customer_web_notification_permission_requested';
const String _backgroundTapPayloadsStorageKey =
    'customer_pending_notification_tap_payloads';
const int _maxPersistedBackgroundTapPayloads = 10;
const int _maxTokenSyncRetries = 12;
const Duration _foregroundMessageDedupWindow = Duration(seconds: 8);
const Duration _interactionDedupWindow = Duration(seconds: 3);
const Duration _redundantTokenSyncWindow = Duration(seconds: 5);
const Duration _awaitingConfirmationReminderInterval = Duration(minutes: 10);
const String _awaitingConfirmationNotificationTitle = '📦 تم تسليم طلبك';
const String _awaitingConfirmationNotificationBody =
    'يرجى تأكيد استلام الطلب لإكمال الطلب.';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  try {
    await AppNotificationService.ensureFirebaseInitialized();
    _logAndroidNotificationFlow('BACKGROUND', {
      'source': 'firebaseMessagingBackgroundHandler',
      'message_id': message.messageId,
      'notification_id': message.data['notification_id']?.toString(),
      'has_notification': message.notification != null,
    });
  } catch (error, stack) {
    _logAndroidNotificationFlow('ERROR', {
      'source': 'background_initialize_firebase',
      'error': error.toString(),
    });
    await ErrorLogger.logError(
      module: 'notification_service.background.initialize_firebase',
      error: error,
      stack: stack,
    );
    return;
  }
  debugPrint(
    '[FCM][background] title=${message.notification?.title} '
    'body=${message.notification?.body} data=${message.data}',
  );

  _logAndroidNotificationFlow('RECEIVED', {
    'source': 'background',
    'message_id': message.messageId,
    'notification_id': message.data['notification_id']?.toString(),
    'type': message.data['type']?.toString(),
  });

  // Notification-payload messages are displayed by Android itself while the
  // app is backgrounded or killed. Only data-only pushes need local display.
  if (message.notification != null) {
    _logAndroidNotificationFlow('DISPLAYED', {
      'source': 'background_system_notification',
      'display_owner': 'android_system',
      'message_id': message.messageId,
      'notification_id': message.data['notification_id']?.toString(),
      'type': message.data['type']?.toString(),
    });
    return;
  }

  try {
    final presentation = _buildAndroidNotificationPresentation(
      message,
      source: 'background',
    );
    if (presentation == null) {
      return;
    }

    final shouldProcess =
        await NotificationDedupeService.instance.shouldProcess(
      fingerprint: presentation.dedupKey,
      source: 'background_push',
      dedupeWindow: _foregroundMessageDedupWindow,
    );
    if (!shouldProcess) {
      return;
    }

    final localNotifications = FlutterLocalNotificationsPlugin();
    await _initializeAndroidLocalNotificationsForBackground(
      localNotifications,
    );
    await localNotifications.show(
      presentation.localNotificationId,
      presentation.title,
      presentation.body,
      _androidNotificationDetailsForPresentation(presentation),
      payload: jsonEncode(presentation.payload),
    );
    _logAndroidNotificationFlow('DISPLAYED', {
      'source': 'background_data_push',
      'notification_id': presentation.notificationId,
      'message_id': presentation.messageId,
      'channel': presentation.channel.id,
      'type': presentation.type,
    });
  } catch (error, stack) {
    _logAndroidNotificationFlow('ERROR', {
      'source': 'background_display',
      'message_id': message.messageId,
      'error': error.toString(),
    });
    await ErrorLogger.logError(
      module: 'notification_service.background.display',
      error: error,
      stack: stack,
    );
  }
}

@pragma('vm:entry-point')
void localNotificationTapBackgroundHandler(NotificationResponse response) {
  final payload = response.payload?.trim();
  if (payload == null || payload.isEmpty) {
    return;
  }
  _logAndroidNotificationFlow('CLICKED', {
    'source': 'local_notification_background_response',
  });
  unawaited(_persistBackgroundNotificationTapPayload(payload));
}

@pragma('vm:entry-point')
Future<void> _persistBackgroundNotificationTapPayload(String payload) async {
  try {
    final normalized = payload.trim();
    if (normalized.isEmpty) {
      return;
    }

    final preferences = await SharedPreferences.getInstance();
    final existing =
        preferences.getStringList(_backgroundTapPayloadsStorageKey) ??
            const <String>[];
    final next = <String>[
      ...existing,
      normalized,
    ];
    final overflow = next.length - _maxPersistedBackgroundTapPayloads;
    if (overflow > 0) {
      next.removeRange(0, overflow);
    }

    await preferences.setStringList(_backgroundTapPayloadsStorageKey, next);
  } catch (_) {
    // Ignore background-isolate persistence failures.
  }
}

class AppNotificationService with WidgetsBindingObserver {
  AppNotificationService._();

  static final AppNotificationService instance = AppNotificationService._();

  FirebaseMessaging? _messaging;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final Random _random = Random.secure();

  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedAppSubscription;
  Timer? _tokenSyncRetryTimer;
  RealtimeChannelController? _orderEventsChannelController;
  Timer? _webAwaitingConfirmationReminderTimer;

  bool _initialized = false;
  bool _available = false;
  bool _localNotificationsInitialized = false;
  bool _webBridgeInitialized = false;
  bool _webPermissionPromptAttached = false;
  bool _drainInteractionScheduled = false;
  bool _uiReadyForNotificationNavigation = false;
  bool _messagingListenersAttached = false;
  bool _widgetsBindingObserverAttached = false;
  bool _webPermissionPromptRequested = false;
  bool _supabaseBindingsInitialized = false;
  Future<void>? _orderEventSubscriptionSync;
  Future<void>? _supabaseBindingFuture;
  String? _lastKnownToken;
  String? _lastKnownUserId;
  String? _lastSuccessfulTokenSyncSignature;
  String? _installationId;
  String? _orderEventsUserId;
  String? _awaitingConfirmationOrderId;
  String? _awaitingConfirmationStateKey;
  Map<String, String>? _awaitingConfirmationPayload;
  DateTime? _lastSuccessfulTokenSyncAt;
  int _tokenSyncRetryAttempt = 0;
  bool _webPushEndpointUnavailable = false;
  final List<_NotificationTapIntent> _pendingNotificationTaps =
      <_NotificationTapIntent>[];
  final Map<String, DateTime> _recentForegroundMessages = <String, DateTime>{};
  final Map<String, DateTime> _recentInteractionSignatures =
      <String, DateTime>{};

  FirebaseMessaging get _messagingInstance {
    return _messaging ??= FirebaseMessaging.instance;
  }

  SupabaseClient? get _supabaseClientOrNull {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  User? get _currentSupabaseUserOrNull =>
      _supabaseClientOrNull?.auth.currentUser;

  Future<void> onSupabaseReady() async {
    if (!_initialized) {
      await initialize();
    }

    final pendingBinding = _supabaseBindingFuture;
    if (pendingBinding != null) {
      await pendingBinding;
      return;
    }
    if (_supabaseBindingsInitialized) {
      return;
    }

    final client = _supabaseClientOrNull;
    if (client == null) {
      throw StateError(
        'Supabase must be initialized before binding notification auth state.',
      );
    }

    final bindingFuture = _bindSupabaseState(client);
    _supabaseBindingFuture = bindingFuture;
    try {
      await bindingFuture;
    } finally {
      if (identical(_supabaseBindingFuture, bindingFuture)) {
        _supabaseBindingFuture = null;
      }
    }
  }

  void markUiReadyForNotificationNavigation() {
    if (_uiReadyForNotificationNavigation) {
      return;
    }
    _uiReadyForNotificationNavigation = true;
    _logAndroidNotificationFlow('INIT', {
      'stage': 'notification_navigation_ui_ready',
    });
    _scheduleNotificationTapDrain();
  }

  Future<void> _bindSupabaseIfAvailable() async {
    if (_supabaseBindingsInitialized) {
      return;
    }

    final client = _supabaseClientOrNull;
    if (client == null) {
      _logBootstrapStartup('SUPABASE_NOTIFICATION_BINDINGS_DEFERRED');
      return;
    }

    await onSupabaseReady();
  }

  Future<void> _bindSupabaseState(SupabaseClient client) async {
    if (_supabaseBindingsInitialized) {
      return;
    }

    _authSubscription ??= client.auth.onAuthStateChange.listen((event) {
      final user = event.session?.user;
      if (user == null) {
        _lastKnownUserId = null;
        _resetTokenSyncRetry();
        unawaited(_disposeOrderEventSubscription());
        unawaited(_clearAwaitingCustomerConfirmationState());
        return;
      }
      _lastKnownUserId = user.id;
      unawaited(_syncOrderEventSubscriptionForUser(user.id));
      unawaited(syncTokenIfPossible());
    });

    _supabaseBindingsInitialized = true;

    final currentUser = client.auth.currentUser;
    _lastKnownUserId = currentUser?.id;
    if (currentUser == null) {
      debugPrint(
        '[FCM] startup token sync deferred until Supabase authentication is available.',
      );
      return;
    }

    await _syncOrderEventSubscriptionForUser(currentUser.id);
    if (kIsWeb) {
      debugPrint(
        '[FCM] startup token sync skipped on web; permission bootstrap already handles token sync.',
      );
      return;
    }

    final token = await _loadCurrentToken();
    debugPrint('[FCM] startup token: ${_maskToken(token)}');
    _logWebTokenDebug(token, reason: 'startup');
    await _safeSyncToken(token, reason: 'startup');
  }

  static Future<void> ensureFirebaseInitialized() async {
    if (Firebase.apps.isNotEmpty) {
      return;
    }

    if (kIsWeb) {
      final options = _tryResolveFirebaseOptions();
      if (options == null) {
        return;
      }
      await Firebase.initializeApp(options: options);
      return;
    }

    try {
      await Firebase.initializeApp();
      return;
    } catch (_) {
      final options = _tryResolveFirebaseOptions();
      if (options != null) {
        await Firebase.initializeApp(options: options);
        return;
      }
      rethrow;
    }
  }

  static FirebaseOptions? _tryResolveFirebaseOptions() {
    try {
      return AppFirebaseOptions.currentPlatform;
    } catch (_) {
      return null;
    }
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _attachWidgetsBindingObserver();
    await _restoreWebPermissionPromptState();
    _logBootstrapStartup('APP_NOTIFICATION_SERVICE_INIT_START');

    if (kIsWeb) {
      final webConfigError = AppFirebaseOptions.configurationError;
      if (webConfigError != null) {
        debugPrint(
          '[FCM] Firebase configuration is missing or invalid for Web: '
          '$webConfigError',
        );
        return;
      }
    }

    try {
      _logBootstrapStartup('FIREBASE_INIT_START');
      await ensureFirebaseInitialized();
      _logBootstrapStartup('FIREBASE_INITIALIZED');
      await NotificationDedupeService.instance.initialize();
      _messaging = FirebaseMessaging.instance;
      await _messagingInstance.setAutoInitEnabled(true);
      _logAndroidNotificationFlow('INIT', {
        'stage': 'firebase_ready',
      });

      _logBootstrapStartup('PERMISSION_REQUEST_START');
      final permissionGranted = await _requestNotificationPermissions();
      if (permissionGranted) {
        _logBootstrapStartup('PERMISSION_GRANTED');
      }

      if (kIsWeb) {
        await _initializeWebNotificationBridge();
        _logBootstrapStartup('ANDROID_NOTIFICATION_INIT');
      } else {
        _logBootstrapStartup('CHANNEL_CREATION_START');
        await _initializeLocalNotifications();
        _logBootstrapStartup('CHANNELS_CREATED');
        FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandler,
        );
        _logAndroidNotificationFlow('INIT', {
          'stage': 'background_handler_registered',
        });
        _logBootstrapStartup('ANDROID_NOTIFICATION_INIT');
      }

      _logBootstrapStartup('FCM_LISTENERS_REGISTER_START');
      _attachMessagingListeners();
      _logBootstrapStartup('FCM_LISTENERS_REGISTERED');

      _tokenRefreshSubscription = _messagingInstance.onTokenRefresh.listen(
        (token) {
          debugPrint('[FCM] token refreshed: ${_maskToken(token)}');
          _logWebTokenDebug(token, reason: 'token_refresh');
          if (_currentSupabaseUserOrNull == null) {
            _lastKnownToken = token.trim().isEmpty ? _lastKnownToken : token;
            debugPrint(
                '[FCM] token refresh deferred until authenticated login.');
            return;
          }
          unawaited(_safeSyncToken(token, reason: 'token_refresh'));
        },
        onError: (error, stack) async {
          await ErrorLogger.logError(
            module: 'notification_service.token_refresh',
            error: error,
            stack: stack is StackTrace ? stack : null,
          );
        },
      );

      final initialMessage = await _messagingInstance.getInitialMessage();
      if (initialMessage != null) {
        if (kIsWeb) {
          _logIncomingMessage(
            initialMessage,
            source: 'initial_message_web_ignored',
          );
          debugPrint(
            '[FCM][web] initialMessage ignored for notification lifecycle; '
            'web delivery proof must come from firebase-messaging-sw.js push.',
          );
        } else {
          _logAndroidNotificationFlow('TERMINATED', {
            'source': 'firebase_initial_message',
            'message_id': initialMessage.messageId,
            'notification_id':
                initialMessage.data['notification_id']?.toString(),
            'type': initialMessage.data['type']?.toString(),
          });
          unawaited(
            _handleMessageInteraction(
              initialMessage,
              source: 'initial_message',
            ),
          );
        }
      }

      _available = true;
      await _bindSupabaseIfAvailable();

      if (kIsWeb) {
        _queueInitialWebLaunchNotificationTap();
      }
    } catch (error, stack) {
      _logAndroidNotificationFlow('ERROR', {
        'source': 'initialize',
        'error': error.toString(),
      });
      await ErrorLogger.logError(
        module: 'notification_service.initialize',
        error: error,
        stack: stack,
      );
      debugPrint('[FCM] initialization failed: $error');
      rethrow;
    }
  }

  Future<void> syncTokenIfPossible() async {
    if (!_initialized) {
      await initialize();
    }
    if (!_available) {
      return;
    }

    await _bindSupabaseIfAvailable();

    final user = _currentSupabaseUserOrNull;
    if (user == null) {
      debugPrint(
        '[FCM] token sync skipped because no authenticated Supabase user exists.',
      );
      return;
    }

    try {
      final token = await _loadCurrentToken();
      final normalizedToken = token?.trim();
      if (normalizedToken != null &&
          normalizedToken.isNotEmpty &&
          _wasTokenSyncedRecently(
            userId: user.id,
            token: normalizedToken,
          )) {
        debugPrint(
          '[FCM] token sync skipped because the current token was synced recently.',
        );
        _resetTokenSyncRetry();
        return;
      }
      await _safeSyncToken(token, reason: 'manual_sync');
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.sync_token',
        error: error,
        stack: stack,
      );
      _scheduleTokenSyncRetry(reason: 'sync_exception');
    }
  }

  Future<void> deactivateCurrentTokenBeforeSignOut({
    String reason = 'signed_out',
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_available) {
      return;
    }

    await _deactivateCurrentToken(reason);
  }

  Future<String?> _loadCurrentToken() async {
    if (!kIsWeb) {
      return _messagingInstance.getToken();
    }

    final currentPermission = currentWebNotificationPermission();
    if (currentPermission != null && currentPermission != 'granted') {
      _logWebPermissionState(currentPermission, source: 'token_load_guard');
      if (currentPermission == 'default') {
        _scheduleWebPermissionPromptOnFirstGesture();
      }
      debugPrint('[FCM][web] notification permission is not granted.');
      return null;
    }

    await ensureWebMessagingServiceWorkerReady();

    final vapidKey = AppFirebaseOptions.webPushVapidKey;
    if (vapidKey == null || vapidKey.isEmpty) {
      debugPrint(
        '[FCM] FIREBASE_WEB_VAPID_KEY is missing. Web push token generation skipped.',
      );
      return null;
    }

    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final token = await _messagingInstance.getToken(vapidKey: vapidKey);
        final normalized = token?.trim();
        if (normalized != null && normalized.isNotEmpty) {
          _webPushEndpointUnavailable = false;
          debugPrint(
            '[FCM][web] token generated (attempt ${attempt + 1}): '
            '${_maskToken(normalized)}',
          );
          _logWebTokenDebug(
            normalized,
            reason: 'get_token_attempt_${attempt + 1}',
          );
          return normalized;
        }
      } catch (error, stack) {
        if (attempt == 2) {
          if (_isIgnorableWebPushEndpointError(error)) {
            _markWebPushEndpointUnavailable(error);
            return null;
          }
          await ErrorLogger.logError(
            module: 'notification_service.load_current_token.web',
            error: error,
            stack: stack,
          );
          return null;
        }
      }
      await Future<void>.delayed(
        Duration(milliseconds: 250 + (attempt * 250)),
      );
    }

    _logWebTokenDebug(null, reason: 'get_token_failed_after_retries');
    debugPrint('[FCM][web] token generation failed after retries.');
    return null;
  }

  Future<void> dispose() async {
    await _authSubscription?.cancel();
    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedAppSubscription?.cancel();
    await _disposeOrderEventSubscription();
    _resetTokenSyncRetry();
    _cancelWebAwaitingReminderTimer();
    _pendingNotificationTaps.clear();
    _recentForegroundMessages.clear();
    _recentInteractionSignatures.clear();
    _uiReadyForNotificationNavigation = false;
    _messagingListenersAttached = false;
    if (_widgetsBindingObserverAttached) {
      WidgetsBinding.instance.removeObserver(this);
      _widgetsBindingObserverAttached = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_awaitingConfirmationOrderId != null) {
      if (_isAppInForeground) {
        unawaited(_pauseAwaitingCustomerConfirmationReminders());
      } else {
        unawaited(_resumeAwaitingCustomerConfirmationReminders());
      }
    }

    if (state == AppLifecycleState.resumed) {
      if (kIsWeb) {
        _queueInitialWebLaunchNotificationTap();
      }
      unawaited(syncTokenIfPossible());
      final userId = _currentSupabaseUserOrNull?.id;
      if (userId != null && userId.isNotEmpty) {
        if (!kIsWeb) {
          _logAndroidNotificationFlow('INIT', {
            'stage': 'resume_recovery',
            'user_id': userId,
          });
          unawaited(_syncOrderEventSubscriptionForUser(userId));
        }
        unawaited(_syncAwaitingCustomerConfirmationStateFromServer(userId));
      }
    }
  }

  void _attachWidgetsBindingObserver() {
    if (_widgetsBindingObserverAttached) {
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _widgetsBindingObserverAttached = true;
  }

  Future<void> _restoreWebPermissionPromptState() async {
    if (!kIsWeb) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    _webPermissionPromptRequested =
        preferences.getBool(_webPermissionPromptRequestedStorageKey) ?? false;
  }

  Future<void> _persistWebPermissionPromptState() async {
    if (!kIsWeb) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(
      _webPermissionPromptRequestedStorageKey,
      _webPermissionPromptRequested,
    );
  }

  bool get _isAppInForeground {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    final lifecycleForeground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    if (!lifecycleForeground) {
      return false;
    }
    if (kIsWeb) {
      return isWebDocumentVisible();
    }
    return true;
  }

  void _attachMessagingListeners() {
    if (_messagingListenersAttached) {
      return;
    }

    _foregroundSubscription = FirebaseMessaging.onMessage.listen(
      (message) => unawaited(_handleForegroundMessageSafely(message)),
      onError: (Object error, StackTrace stack) {
        unawaited(
          ErrorLogger.logError(
            module: 'notification_service.on_message_stream',
            error: error,
            stack: stack,
          ),
        );
      },
    );
    _openedAppSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) => unawaited(
        _handleMessageInteraction(message, source: 'opened_app'),
      ),
      onError: (Object error, StackTrace stack) {
        unawaited(
          ErrorLogger.logError(
            module: 'notification_service.on_message_opened_app_stream',
            error: error,
            stack: stack,
          ),
        );
      },
    );
    _messagingListenersAttached = true;
    _logAndroidNotificationFlow('INIT', {
      'stage': 'foreground_and_opened_handlers_attached',
    });
    debugPrint(
      '[FCM] FirebaseMessaging listeners attached '
      '(onMessage, onMessageOpenedApp).',
    );
  }

  Future<void> _initializeLocalNotifications() async {
    if (kIsWeb || _localNotificationsInitialized) {
      return;
    }

    _logAndroidNotificationFlow('INIT', {
      'stage': 'local_notifications_start',
      'channels': _androidNotificationChannels.map((c) => c.id).join(','),
    });
    const androidSettings = AndroidInitializationSettings(
      _androidNotificationIcon,
    );
    const iosSettings = DarwinInitializationSettings();

    await _localNotifications.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = _decodeNotificationPayload(response.payload);
        if (payload.isEmpty) {
          return;
        }
        _logAndroidNotificationFlow('CLICKED', {
          'source': 'local_notification_tap',
          'notification_id': payload['notification_id'],
          'message_id': payload['message_id'],
          'type': payload['type'] ?? payload['notification_type'],
        });
        _queueNotificationTap(
          payload,
          source: 'local_notification_tap',
        );
        _scheduleNotificationTapDrain();
      },
      onDidReceiveBackgroundNotificationResponse:
          localNotificationTapBackgroundHandler,
    );

    await _createAndroidNotificationChannels(_localNotifications);
    _localNotificationsInitialized = true;

    final launchDetails =
        await _localNotifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final payload = _decodeNotificationPayload(
        launchDetails?.notificationResponse?.payload,
      );
      if (payload.isNotEmpty) {
        _logAndroidNotificationFlow('TERMINATED', {
          'source': 'local_notification_launch',
          'notification_id': payload['notification_id'],
          'message_id': payload['message_id'],
          'type': payload['type'] ?? payload['notification_type'],
        });
        _queueNotificationTap(
          payload,
          source: 'local_notification_launch',
        );
        _scheduleNotificationTapDrain();
      }
    }
    await _drainPersistedBackgroundNotificationTapPayloads();
    _logAndroidNotificationFlow('INIT', {
      'stage': 'local_notifications_ready',
    });
  }

  Future<void> _initializeWebNotificationBridge() async {
    if (!kIsWeb || _webBridgeInitialized) {
      return;
    }

    await ensureWebMessagingServiceWorkerReady();
    await initializeWebNotificationBridge(
      onNotificationTap: (data) {
        if (data.isEmpty) {
          return;
        }
        _queueNotificationTap(
          data,
          source: 'web_service_worker_click',
        );
        _scheduleNotificationTapDrain();
      },
      onLifecycleEvent: _handleWebNotificationLifecycleEvent,
    );
    _webBridgeInitialized = true;
  }

  void _handleWebNotificationLifecycleEvent(
    String event,
    Map<String, String> data,
    Map<String, dynamic> metadata,
  ) {
    if (!kIsWeb) {
      return;
    }

    final notificationId = _normalizeDataValue(
          data['notification_id'] ?? metadata['notification_id']?.toString(),
        ) ??
        '<missing>';
    final recovered = metadata['recovered'] == true ||
        metadata['recovered']?.toString() == 'true';
    debugPrint(
      '[FCM][web][sw_lifecycle] event=$event '
      'notification_id=$notificationId recovered=$recovered '
      'data=$data meta=$metadata',
    );

    StabilityMetricsService.instance.increment(
      'notification_$event',
      module: 'notification_delivery',
      payload: {
        'source': 'firebase-messaging-sw.js',
        'notification_id': notificationId,
        'message_id': metadata['message_id']?.toString() ?? data['message_id'],
        'recovered': recovered,
      },
    );
  }

  Future<bool> _requestNotificationPermissions() async {
    NotificationSettings? settings;
    if (!kIsWeb) {
      final permissionRequest = _messagingInstance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      settings = await permissionRequest;
    }
    if (settings != null) {
      debugPrint(
        '[FCM] permission status: ${settings.authorizationStatus.name}',
      );
      if (kIsWeb) {
        debugPrint(
          '[FCM][web] firebase permission status: '
          '${settings.authorizationStatus.name}',
        );
      }
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin =
          _localNotifications.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final beforeStatus = await _loadAndroidNotificationPermissionStatus();
      final granted = await androidPlugin?.requestNotificationsPermission();
      final enabled = await androidPlugin?.areNotificationsEnabled();
      final afterStatus = await _loadAndroidNotificationPermissionStatus();
      final effectiveEnabled = enabled ?? afterStatus.notificationsEnabled;

      _logAndroidNotificationFlow('PERMISSION', {
        'source': 'android_post_notifications',
        'firebase_status': settings?.authorizationStatus.name,
        'request_granted': granted,
        'notifications_enabled': enabled,
        'sdk_int': afterStatus.sdkInt,
        'post_notifications_granted': afterStatus.postNotificationsGranted,
        'should_show_rationale':
            afterStatus.shouldShowPostNotificationsRationale,
      });

      if (effectiveEnabled) {
        return true;
      }

      _logBootstrapStartup('PERMISSION_DENIED');
      final shouldOpenSettings = afterStatus.isAndroid13OrAbove
          ? !afterStatus.postNotificationsGranted ||
              !afterStatus.shouldShowPostNotificationsRationale
          : true;
      if (shouldOpenSettings) {
        final opened = await _openAndroidNotificationSettings();
        _logAndroidNotificationFlow('PERMISSION', {
          'source': 'android_post_notifications',
          'status': 'settings_opened',
          'opened': opened,
          'enabled_before_request': beforeStatus.notificationsEnabled,
        });
        if (opened) {
          _logBootstrapStartup('PERMISSION_SETTINGS_OPENED');
        }
      }
      return false;
    }

    if (kIsWeb) {
      if (!supportsWebBrowserNotifications()) {
        debugPrint('[FCM][web] Browser Notification API is not supported.');
        return false;
      }
      final webPermission = currentWebNotificationPermission();
      if (webPermission == null) {
        return false;
      }
      _logWebPermissionState(webPermission, source: 'request_permission');
      debugPrint('[FCM][web] browser permission: $webPermission');
      if (webPermission == 'granted') {
        final refreshedToken = await _loadCurrentToken();
        await _safeSyncToken(
          refreshedToken,
          reason: 'web_permission_granted',
        );
        return true;
      }
      if (webPermission == 'default') {
        _scheduleWebPermissionPromptOnFirstGesture();
      } else if (webPermission == 'denied') {
        debugPrint(
          '[FCM][web] browser permission is denied. Enable notifications '
          'from browser site settings for this origin, then refresh the app '
          'to retry token sync.',
        );
      }
      return false;
    }

    return settings?.authorizationStatus == AuthorizationStatus.authorized;
  }

  Future<_AndroidNotificationPermissionStatus>
      _loadAndroidNotificationPermissionStatus() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const _AndroidNotificationPermissionStatus(
        sdkInt: 0,
        notificationsEnabled: false,
        postNotificationsGranted: false,
        shouldShowPostNotificationsRationale: false,
      );
    }

    final rawStatus = await _androidNotificationSettingsChannel
        .invokeMapMethod<String, dynamic>('getStatus');
    final sdkInt = _androidIntValue(rawStatus?['sdkInt']) ?? 0;
    final notificationsEnabled = rawStatus?['notificationsEnabled'] == true;
    final postNotificationsGranted =
        rawStatus?['postNotificationsGranted'] != false;
    final shouldShowRationale =
        rawStatus?['shouldShowPostNotificationsRationale'] == true;

    return _AndroidNotificationPermissionStatus(
      sdkInt: sdkInt,
      notificationsEnabled: notificationsEnabled,
      postNotificationsGranted: postNotificationsGranted,
      shouldShowPostNotificationsRationale: shouldShowRationale,
    );
  }

  Future<bool> _openAndroidNotificationSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }

    final opened = await _androidNotificationSettingsChannel.invokeMethod<bool>(
      'openSettings',
    );
    return opened ?? false;
  }

  void _scheduleWebPermissionPromptOnFirstGesture({
    bool allowDenied = false,
  }) {
    if (!kIsWeb || _webPermissionPromptAttached) {
      return;
    }

    final permission = currentWebNotificationPermission();
    final shouldAttach = !_webPermissionPromptRequested &&
        (permission == 'default' || (allowDenied && permission == 'denied'));
    if (!shouldAttach) {
      return;
    }

    _webPermissionPromptAttached = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleWebPermissionPointerEvent,
    );
  }

  void _handleWebPermissionPointerEvent(PointerEvent event) {
    if (event is! PointerDownEvent) {
      return;
    }
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleWebPermissionPointerEvent,
    );
    _webPermissionPromptAttached = false;
    unawaited(_requestWebPermissionAfterGesture());
  }

  Future<void> _requestWebPermissionAfterGesture() async {
    if (!kIsWeb) {
      return;
    }

    try {
      if (_webPermissionPromptRequested) {
        return;
      }
      _webPermissionPromptRequested = true;
      await _persistWebPermissionPromptState();
      final permission = await ensureWebNotificationPermission();
      if (permission != null) {
        _logWebPermissionState(permission, source: 'after_gesture');
        debugPrint('[FCM][web] browser permission after gesture: $permission');
      }
      if (permission == 'granted') {
        final refreshedToken = await _loadCurrentToken();
        await _safeSyncToken(
          refreshedToken,
          reason: 'web_permission_after_gesture',
        );
      } else if (permission == 'denied') {
        debugPrint('[FCM][web] browser permission denied after gesture.');
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.request_web_permission_after_gesture',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _syncOrderEventSubscriptionForUser(String userId) async {
    final normalizedUserId = userId.trim();
    final pendingSync = _orderEventSubscriptionSync;
    if (pendingSync != null) {
      await pendingSync;
    }

    final syncCompleter = Completer<void>();
    _orderEventSubscriptionSync = syncCompleter.future;
    if (normalizedUserId.isEmpty) {
      try {
        await _disposeOrderEventSubscription();
        return;
      } finally {
        syncCompleter.complete();
        if (identical(_orderEventSubscriptionSync, syncCompleter.future)) {
          _orderEventSubscriptionSync = null;
        }
      }
    }

    try {
      if (_orderEventsUserId == normalizedUserId &&
          _orderEventsChannelController != null) {
        await _syncAwaitingCustomerConfirmationStateFromServer(
          normalizedUserId,
        );
        return;
      }

      await _disposeOrderEventSubscription();
      _orderEventsUserId = normalizedUserId;
      _orderEventsChannelController = RealtimeChannelController(
        client: Supabase.instance.client,
        topicPrefix: 'customer-order-events-$normalizedUserId',
        onSubscribed: (_) async {
          await _syncAwaitingCustomerConfirmationStateFromServer(
            normalizedUserId,
          );
        },
      );

      _orderEventsChannelController!.subscribe((client, channelName) {
        return client.channel(channelName).onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'orders',
              filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'customer_id',
                value: normalizedUserId,
              ),
              callback: _handleTrackedOrderRealtimeChange,
            );
      });

      await _syncAwaitingCustomerConfirmationStateFromServer(normalizedUserId);
    } finally {
      syncCompleter.complete();
      if (identical(_orderEventSubscriptionSync, syncCompleter.future)) {
        _orderEventSubscriptionSync = null;
      }
    }
  }

  Future<void> _disposeOrderEventSubscription() async {
    _orderEventsUserId = null;
    final controller = _orderEventsChannelController;
    _orderEventsChannelController = null;
    if (controller != null) {
      await controller.dispose();
    }
  }

  Future<void> _syncAwaitingCustomerConfirmationStateFromServer(
    String userId,
  ) async {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return;
    }

    try {
      final order = await OrdersService.getLatestActiveOrder(
        normalizedUserId,
        forceRefresh: true,
      );
      if (order == null ||
          !isAwaitingCustomerConfirmationStatus(order['status'])) {
        await _clearAwaitingCustomerConfirmationState();
        return;
      }
      await _activateAwaitingCustomerConfirmationForOrder(
        order,
        notifyImmediately: false,
        source: 'server_sync',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.sync_awaiting_confirmation_state',
        error: error,
        stack: stack,
      );
    }
  }

  void _handleTrackedOrderRealtimeChange(PostgresChangePayload payload) {
    switch (payload.eventType) {
      case PostgresChangeEvent.delete:
        final deletedOrderId =
            _normalizeDataValue(payload.oldRecord['id']?.toString());
        if (deletedOrderId != null &&
            deletedOrderId == _awaitingConfirmationOrderId) {
          unawaited(_clearAwaitingCustomerConfirmationState());
        }
        return;
      case PostgresChangeEvent.insert:
      case PostgresChangeEvent.update:
        final nextOrder = Map<String, dynamic>.from(payload.newRecord);
        final previousOrder = payload.oldRecord.isEmpty
            ? null
            : Map<String, dynamic>.from(payload.oldRecord);
        unawaited(
          _handleTrackedOrderStateUpdate(
            previousOrder: previousOrder,
            nextOrder: nextOrder,
            source: 'realtime_${payload.eventType.name}',
          ),
        );
        return;
      case PostgresChangeEvent.all:
        return;
    }
  }

  Future<void> _handleTrackedOrderStateUpdate({
    required Map<String, dynamic>? previousOrder,
    required Map<String, dynamic> nextOrder,
    required String source,
  }) async {
    final nextOrderId = OrdersService.idOf(nextOrder);
    if (nextOrderId.isEmpty) {
      return;
    }

    final previousStatus = previousOrder == null
        ? ''
        : OrdersService.normalizedStatusOf(previousOrder);
    final nextStatus = OrdersService.normalizedStatusOf(nextOrder);

    if (nextStatus == awaitingCustomerConfirmationStatus) {
      await _activateAwaitingCustomerConfirmationForOrder(
        nextOrder,
        notifyImmediately: previousStatus != awaitingCustomerConfirmationStatus,
        source: source,
      );
      return;
    }

    if (_awaitingConfirmationOrderId == nextOrderId ||
        previousStatus == awaitingCustomerConfirmationStatus) {
      await _clearAwaitingCustomerConfirmationState();
    }
  }

  Future<void> _activateAwaitingCustomerConfirmationForOrder(
    Map<String, dynamic> order, {
    required bool notifyImmediately,
    required String source,
  }) async {
    final orderId = OrdersService.idOf(order);
    if (orderId.isEmpty) {
      return;
    }

    final nextStateKey = _awaitingConfirmationKeyForOrder(order);
    final stateChanged = _awaitingConfirmationStateKey != nextStateKey ||
        _awaitingConfirmationOrderId != orderId;

    _awaitingConfirmationOrderId = orderId;
    _awaitingConfirmationStateKey = nextStateKey;
    _awaitingConfirmationPayload =
        _buildAwaitingCustomerConfirmationPayload(order);

    if (notifyImmediately && stateChanged) {
      await _showAwaitingCustomerConfirmationNotification(
        payload: _awaitingConfirmationPayload!,
        isReminder: false,
        source: source,
      );
    }

    if (_isAppInForeground) {
      await _pauseAwaitingCustomerConfirmationReminders();
      return;
    }
    await _resumeAwaitingCustomerConfirmationReminders();
  }

  Future<void> _resumeAwaitingCustomerConfirmationReminders() async {
    final orderId = _awaitingConfirmationOrderId;
    final payload = _awaitingConfirmationPayload;
    if (orderId == null || payload == null) {
      return;
    }

    if (kIsWeb) {
      _scheduleNextWebAwaitingReminder();
      return;
    }

    await _localNotifications.cancel(_awaitingNotificationId(orderId));
    await _localNotifications.periodicallyShowWithDuration(
      _awaitingNotificationId(orderId),
      _awaitingConfirmationNotificationTitle,
      _awaitingConfirmationNotificationBody,
      _awaitingConfirmationReminderInterval,
      _awaitingCustomerConfirmationNotificationDetails(),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: _encodeNotificationPayload(payload),
    );
  }

  Future<void> _pauseAwaitingCustomerConfirmationReminders() async {
    final orderId = _awaitingConfirmationOrderId;
    _cancelWebAwaitingReminderTimer();
    if (!kIsWeb && orderId != null) {
      await _localNotifications.cancel(_awaitingNotificationId(orderId));
    }
  }

  Future<void> _clearAwaitingCustomerConfirmationState() async {
    await _pauseAwaitingCustomerConfirmationReminders();
    _awaitingConfirmationOrderId = null;
    _awaitingConfirmationStateKey = null;
    _awaitingConfirmationPayload = null;
  }

  void _scheduleNextWebAwaitingReminder() {
    if (!kIsWeb || _awaitingConfirmationPayload == null) {
      return;
    }
    _cancelWebAwaitingReminderTimer();
    _webAwaitingConfirmationReminderTimer = Timer(
      _awaitingConfirmationReminderInterval,
      () {
        final payload = _awaitingConfirmationPayload;
        if (payload == null || _isAppInForeground) {
          _cancelWebAwaitingReminderTimer();
          return;
        }
        unawaited(
          _showAwaitingCustomerConfirmationNotification(
            payload: payload,
            isReminder: true,
            source: 'web_reminder_timer',
          ),
        );
        _scheduleNextWebAwaitingReminder();
      },
    );
  }

  void _cancelWebAwaitingReminderTimer() {
    _webAwaitingConfirmationReminderTimer?.cancel();
    _webAwaitingConfirmationReminderTimer = null;
  }

  Future<void> _showAwaitingCustomerConfirmationNotification({
    required Map<String, String> payload,
    required bool isReminder,
    required String source,
  }) async {
    final orderId = _normalizeDataValue(payload['order_id']);
    if (orderId == null || orderId.isEmpty) {
      return;
    }

    final title = _awaitingConfirmationNotificationTitle;
    final body = _awaitingConfirmationNotificationBody;
    final notificationId = _awaitingNotificationId(orderId);
    final timestamp = DateTime.now().toUtc();
    final localPayload = <String, String>{
      ...payload,
      'title': title,
      'body': body,
      'type': payload['type'] ?? 'awaiting_customer_confirmation',
      'notification_type':
          payload['notification_type'] ?? 'awaiting_customer_confirmation',
      'event': payload['event'] ?? 'awaiting_customer_confirmation',
      'deep_link': payload['deep_link'] ??
          payload['click_action'] ??
          payload['path'] ??
          '/?screen=order_tracking&order_id=$orderId',
      'timestamp': payload['timestamp'] ?? timestamp.toIso8601String(),
      'badge_count': payload['badge_count'] ?? '1',
      'sound': payload['sound'] ?? 'default',
      'priority': payload['priority'] ?? 'high',
      'channel': payload['channel'] ?? _ordersNotificationChannel.id,
    };

    if (kIsWeb) {
      final shown = await showForegroundWebNotification(
        title: title,
        body: body,
        data: payload,
        tag: 'awaiting-confirmation-$orderId',
      );
      debugPrint(
        '[FCM][web][$source] awaiting confirmation notification shown=$shown '
        'order=$orderId reminder=$isReminder',
      );
      return;
    }

    await _localNotifications.show(
      notificationId,
      title,
      body,
      _awaitingCustomerConfirmationNotificationDetails(
        title: title,
        body: body,
        timestamp: timestamp,
      ),
      payload: _encodeNotificationPayload(localPayload),
    );
    _logAndroidNotificationFlow('DISPLAYED', {
      'source': source,
      'notification_id': localPayload['notification_id'],
      'type': localPayload['type'],
      'channel': localPayload['channel'],
      'reminder': isReminder,
    });
  }

  NotificationDetails _awaitingCustomerConfirmationNotificationDetails({
    String title = _awaitingConfirmationNotificationTitle,
    String body = _awaitingConfirmationNotificationBody,
    DateTime? timestamp,
  }) {
    return _androidNotificationDetailsForChannel(
      _ordersNotificationChannel,
      title: title,
      body: body,
      badgeCount: 1,
      timestamp: timestamp,
    );
  }

  Map<String, String> _buildAwaitingCustomerConfirmationPayload(
    Map<String, dynamic> order,
  ) {
    final orderId = OrdersService.idOf(order);
    final stateKey = _awaitingConfirmationKeyForOrder(order);
    final path = '/?screen=order_tracking&order_id=$orderId';
    return <String, String>{
      'screen': 'order_tracking',
      'order_id': orderId,
      'path': path,
      'status': awaitingCustomerConfirmationStatus,
      'notification_type': 'awaiting_customer_confirmation',
      'notification_id': stateKey,
      'title': _awaitingConfirmationNotificationTitle,
      'body': _awaitingConfirmationNotificationBody,
      'type': 'awaiting_customer_confirmation',
      'event': 'awaiting_customer_confirmation',
      'click_action': path,
      'deep_link': path,
      'badge_count': '1',
      'sound': 'default',
      'priority': 'high',
      'channel': _ordersNotificationChannel.id,
    };
  }

  String _awaitingConfirmationKeyForOrder(Map<String, dynamic> order) {
    return [
      OrdersService.idOf(order),
      OrdersService.normalizedStatusOf(order),
      OrdersService.authoritativeStateVersionOf(order)?.toString() ?? '-',
      OrdersService.orderVersionOf(order)?.toString() ?? '-',
    ].join(':');
  }

  int _awaitingNotificationId(String orderId) {
    return orderId.codeUnits.fold<int>(
          1171,
          (hash, codeUnit) => ((hash * 31) + codeUnit) & 0x7fffffff,
        ) ^
        0x51A1A9;
  }

  void _queueInitialWebLaunchNotificationTap() {
    if (!kIsWeb) {
      return;
    }

    final query = Uri.base.queryParameters;
    final screen = _normalizeDataValue(query['screen']);
    final orderId = _normalizeDataValue(query['order_id']);
    if (screen == null && orderId == null) {
      return;
    }

    final payload = <String, String>{
      for (final entry in query.entries)
        if (_normalizeDataValue(entry.value) != null)
          entry.key: _normalizeDataValue(entry.value)!,
    };
    if (payload.isEmpty) {
      return;
    }

    _queueNotificationTap(payload, source: 'web_launch_url');
    _scheduleNotificationTapDrain();
    clearWebLaunchNotificationQueryParameters();
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    _logIncomingMessage(message, source: 'foreground');
    _logAndroidNotificationFlow('RECEIVED', {
      'source': 'foreground',
      'message_id': message.messageId,
      'notification_id': message.data['notification_id']?.toString(),
      'type': message.data['type']?.toString(),
    });
    if (kIsWeb) {
      debugPrint(
        '[FCM][web][foreground] message treated as data synchronization only; '
        'notification delivery is not recorded until firebase-messaging-sw.js '
        'receives the push event and displays the browser notification.',
      );
      StabilityMetricsService.instance.increment(
        'notification_foreground_message_sync_only',
        module: 'notification_delivery',
        payload: {
          'source': 'FirebaseMessaging.onMessage',
          'message_id': message.messageId,
          'notification_id': message.data['notification_id']?.toString(),
        },
      );
      return;
    }

    if (_isDuplicateForegroundMessage(message)) {
      debugPrint(
        '[FCM][foreground] duplicate message skipped: ${message.messageId}',
      );
      _logAndroidNotificationFlow('RECEIVED', {
        'source': 'foreground',
        'status': 'duplicate_skipped',
        'message_id': message.messageId,
      });
      return;
    }
    final presentation = _buildAndroidNotificationPresentation(
      message,
      source: 'foreground',
    );
    if (presentation == null) {
      return;
    }
    final userId = _currentSupabaseUserOrNull?.id;
    final shouldProcess =
        await NotificationDedupeService.instance.shouldProcess(
      fingerprint: presentation.dedupKey,
      source: 'foreground_push',
      userId: userId,
      dedupeWindow: _foregroundMessageDedupWindow,
    );
    if (!shouldProcess) {
      return;
    }

    await _localNotifications.show(
      presentation.localNotificationId,
      presentation.title,
      presentation.body,
      _androidNotificationDetailsForPresentation(presentation),
      payload: _encodeNotificationPayload(presentation.payload),
    );
    _logAndroidNotificationFlow('DISPLAYED', {
      'source': 'foreground',
      'notification_id': presentation.notificationId,
      'message_id': presentation.messageId,
      'type': presentation.type,
      'channel': presentation.channel.id,
    });
  }

  Future<void> _drainPersistedBackgroundNotificationTapPayloads() async {
    if (kIsWeb) {
      return;
    }

    try {
      final preferences = await SharedPreferences.getInstance();
      final payloads = preferences.getStringList(
            _backgroundTapPayloadsStorageKey,
          ) ??
          const <String>[];
      if (payloads.isEmpty) {
        return;
      }

      await preferences.remove(_backgroundTapPayloadsStorageKey);

      for (final raw in payloads) {
        final payload = _decodeNotificationPayload(raw);
        if (payload.isEmpty) {
          continue;
        }
        _queueNotificationTap(
          payload,
          source: 'local_notification_background_tap',
        );
      }
      _scheduleNotificationTapDrain();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.drain_background_tap_payloads',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _handleForegroundMessageSafely(RemoteMessage message) async {
    try {
      await _handleForegroundMessage(message);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.foreground_message',
        error: error,
        stack: stack,
      );
    }
  }

  void _logIncomingMessage(RemoteMessage message, {required String source}) {
    debugPrint(
      '[FCM][$source] id=${message.messageId} '
      'title=${message.notification?.title} '
      'body=${message.notification?.body} '
      'data=${message.data}',
    );
  }

  Future<void> _handleMessageInteraction(
    RemoteMessage message, {
    required String source,
  }) async {
    _logIncomingMessage(message, source: source);
    if (kIsWeb) {
      debugPrint(
        '[FCM][web][$source] Firebase message interaction ignored for '
        'notification lifecycle; web clicks must originate from '
        'firebase-messaging-sw.js notificationclick.',
      );
      StabilityMetricsService.instance.increment(
        'notification_web_interaction_sync_only',
        module: 'notification_delivery',
        payload: {
          'source': source,
          'message_id': message.messageId,
          'notification_id': message.data['notification_id']?.toString(),
        },
      );
      return;
    }

    final data = _normalizeStringData(message.data);
    if (data.isEmpty) {
      return;
    }
    final userId = _currentSupabaseUserOrNull?.id;
    final interactionFingerprint = _notificationInteractionSignature(
      data,
      messageId: message.messageId,
    );
    final shouldProcess =
        await NotificationDedupeService.instance.shouldProcess(
      fingerprint: interactionFingerprint,
      source: 'interaction_$source',
      userId: userId,
      dedupeWindow: _interactionDedupWindow,
    );
    if (!shouldProcess) {
      return;
    }

    _logAndroidNotificationFlow('CLICKED', {
      'source': source,
      'notification_id': data['notification_id'],
      'message_id': data['message_id'] ?? message.messageId,
      'type': data['type'] ?? data['notification_type'],
    });
    _queueNotificationTap(
      data,
      source: source,
      messageId: message.messageId,
    );
    _scheduleNotificationTapDrain();
  }

  String _notificationInteractionSignature(
    Map<String, String> data, {
    String? messageId,
  }) {
    final notificationId = _normalizeDataValue(data['notification_id']);
    if (notificationId != null) {
      return 'notification_id:$notificationId';
    }
    final dataMessageId = _normalizeDataValue(data['message_id']);
    if (dataMessageId != null) {
      return 'message_id:$dataMessageId';
    }
    final remoteMessageId = _normalizeDataValue(messageId);
    if (remoteMessageId != null) {
      return 'message_id:$remoteMessageId';
    }
    return '${_resolveScreenFromData(data) ?? 'unknown'}:${_stableDataSignature(data)}';
  }

  void _queueNotificationTap(
    Map<String, String> data, {
    required String source,
    String? messageId,
  }) {
    if (data.isEmpty) {
      return;
    }

    final signature = _notificationInteractionSignature(
      data,
      messageId: messageId,
    );

    final now = DateTime.now();
    _recentInteractionSignatures.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _interactionDedupWindow * 4,
    );
    final seenAt = _recentInteractionSignatures[signature];
    if (seenAt != null && now.difference(seenAt) < _interactionDedupWindow) {
      _logAndroidNotificationFlow('CLICKED', {
        'source': source,
        'status': 'duplicate_navigation_skipped',
        'signature': signature,
      });
      return;
    }
    _recentInteractionSignatures[signature] = now;

    _pendingNotificationTaps.add(
      _NotificationTapIntent(
        source: source,
        data: Map<String, String>.from(data),
      ),
    );
  }

  void _scheduleNotificationTapDrain() {
    if (_drainInteractionScheduled) {
      return;
    }
    _drainInteractionScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _drainInteractionScheduled = false;
      unawaited(_drainPendingNotificationTaps());
    });
  }

  Future<void> _drainPendingNotificationTaps() async {
    if (_pendingNotificationTaps.isEmpty) {
      return;
    }

    if (!_uiReadyForNotificationNavigation) {
      Timer(
        const Duration(milliseconds: 250),
        _scheduleNotificationTapDrain,
      );
      return;
    }

    final navigator = SessionManager.navigatorKey.currentState;
    if (navigator == null) {
      Timer(
        const Duration(milliseconds: 250),
        _scheduleNotificationTapDrain,
      );
      return;
    }

    while (_pendingNotificationTaps.isNotEmpty) {
      final intent = _pendingNotificationTaps.removeAt(0);
      final screen = _resolveScreenFromData(intent.data);
      if (screen == null) {
        continue;
      }
      await _navigateToScreen(
        navigator,
        screen: screen,
        data: intent.data,
        source: intent.source,
      );
    }
  }

  Future<void> _navigateToScreen(
    NavigatorState navigator, {
    required String screen,
    required Map<String, String> data,
    required String source,
  }) async {
    final normalizedScreen = screen.trim().toLowerCase();
    final signedInUser = _currentSupabaseUserOrNull;
    if (signedInUser == null) {
      await SessionManager.instance.redirectToLogin();
      return;
    }

    final orderId = _normalizeDataValue(data['order_id']);
    switch (normalizedScreen) {
      case 'order_tracking':
      case 'tracking':
        if (orderId == null) {
          break;
        }
        debugPrint(
          '[FCM][tap:$source] opening OrderTrackingPage order=$orderId.',
        );
        await InputFocusGuard.prepareForUiTransition();
        if (!navigator.mounted) {
          return;
        }
        await navigator.push(
          AppTheme.platformPageRoute<void>(
            builder: (_) => OrderTrackingPage(orderId: orderId),
          ),
        );
        return;
      case 'order_details':
        if (orderId == null) {
          break;
        }
        debugPrint(
          '[FCM][tap:$source] opening OrderDetailsPage order=$orderId.',
        );
        await InputFocusGuard.prepareForUiTransition();
        if (!navigator.mounted) {
          return;
        }
        await navigator.push(
          AppTheme.platformPageRoute<void>(
            builder: (_) => OrderDetailsPage(orderId: orderId),
          ),
        );
        return;
      case 'chat':
      case 'order_chat':
      case 'messages':
      case 'message':
        if (orderId == null) {
          break;
        }
        debugPrint(
          '[FCM][tap:$source] opening OrderChatPage order=$orderId.',
        );
        await InputFocusGuard.prepareForUiTransition();
        if (!navigator.mounted) {
          return;
        }
        await navigator.push(
          AppTheme.platformPageRoute<void>(
            builder: (_) => OrderChatPage(orderId: orderId),
          ),
        );
        return;
      case 'current_order':
      case 'current':
      case 'active_order':
        var targetOrderId = orderId;
        if (targetOrderId == null) {
          final activeOrder = await OrdersService.getLatestActiveOrder(
            signedInUser.id,
            forceRefresh: true,
          );
          if (activeOrder != null) {
            targetOrderId = OrdersService.idOf(activeOrder);
          }
        }
        if (targetOrderId != null && targetOrderId.isNotEmpty) {
          debugPrint(
            '[FCM][tap:$source] opening current OrderTrackingPage order=$targetOrderId.',
          );
          await InputFocusGuard.prepareForUiTransition();
          if (!navigator.mounted) {
            return;
          }
          await navigator.push(
            AppTheme.platformPageRoute<void>(
              builder: (_) => OrderTrackingPage(orderId: targetOrderId!),
            ),
          );
          return;
        }
        debugPrint('[FCM][tap:$source] opening OrdersPage current fallback.');
        await InputFocusGuard.prepareForUiTransition();
        if (!navigator.mounted) {
          return;
        }
        await navigator.push(
          AppTheme.platformPageRoute<void>(
            builder: (_) => const OrdersPage(),
          ),
        );
        return;
      case 'orders':
      case 'order':
      case 'my_orders':
        if (orderId != null) {
          debugPrint(
            '[FCM][tap:$source] opening OrderTrackingPage order=$orderId via orders fallback.',
          );
          await InputFocusGuard.prepareForUiTransition();
          if (!navigator.mounted) {
            return;
          }
          await navigator.push(
            AppTheme.platformPageRoute<void>(
              builder: (_) => OrderTrackingPage(orderId: orderId),
            ),
          );
          return;
        }
        debugPrint('[FCM][tap:$source] opening OrdersPage.');
        await InputFocusGuard.prepareForUiTransition();
        if (!navigator.mounted) {
          return;
        }
        await navigator.push(
          AppTheme.platformPageRoute<void>(
            builder: (_) => const OrdersPage(),
          ),
        );
        return;
      case 'history':
      case 'order_history':
      case 'orders_history':
        debugPrint('[FCM][tap:$source] opening OrdersPage history surface.');
        await InputFocusGuard.prepareForUiTransition();
        if (!navigator.mounted) {
          return;
        }
        await navigator.push(
          AppTheme.platformPageRoute<void>(
            builder: (_) => const OrdersPage(),
          ),
        );
        return;
      default:
        debugPrint('[FCM][tap:$source] unhandled screen="$normalizedScreen".');
        return;
    }
  }

  String? _resolveScreenFromData(Map<String, String> data) {
    final direct = _normalizeDataValue(data['screen']);
    if (direct != null) {
      return direct.toLowerCase();
    }

    for (final key in const [
      'click_action',
      'deep_link',
      'link',
      'url',
      'path',
      'route',
    ]) {
      final candidate = _normalizeDataValue(data[key]);
      if (candidate == null) {
        continue;
      }

      final uri = Uri.tryParse(candidate);
      final screen = _normalizeDataValue(uri?.queryParameters['screen']);
      if (screen != null) {
        return screen.toLowerCase();
      }

      final candidatePath = _normalizeDataValue(uri?.path ?? candidate);
      if (candidatePath == null) {
        continue;
      }
      final normalizedPath = candidatePath.toLowerCase();
      if (normalizedPath.contains('order_chat') ||
          normalizedPath.contains('/chat') ||
          normalizedPath == 'chat') {
        return 'chat';
      }
      if (normalizedPath.contains('order_tracking') ||
          normalizedPath.contains('tracking')) {
        return 'order_tracking';
      }
      if (normalizedPath.contains('order_details')) {
        return 'order_details';
      }
      if (normalizedPath.contains('current_order') ||
          normalizedPath.contains('active_order')) {
        return 'current_order';
      }
      if (normalizedPath.contains('history')) {
        return 'history';
      }
      if (normalizedPath == '/orders' ||
          normalizedPath == 'orders' ||
          normalizedPath.contains('/orders')) {
        return 'orders';
      }
    }

    final typeHint = _normalizeDataValue(data['type']) ??
        _normalizeDataValue(data['notification_type']) ??
        _normalizeDataValue(data['event']);
    if (typeHint != null) {
      final normalizedTypeHint = typeHint.toLowerCase();
      if (normalizedTypeHint.contains('chat') ||
          normalizedTypeHint == 'message' ||
          normalizedTypeHint.contains('order_message') ||
          normalizedTypeHint.contains('customer_message')) {
        return 'chat';
      }
      if (normalizedTypeHint.contains('current_order') ||
          normalizedTypeHint.contains('active_order')) {
        return 'current_order';
      }
      if (normalizedTypeHint.contains('history')) {
        return 'history';
      }
    }
    if (_normalizeDataValue(data['order_id']) != null) {
      return 'order_tracking';
    }
    if (typeHint != null && typeHint.toLowerCase().contains('order')) {
      return 'orders';
    }

    for (final key in const ['order_id', 'order_number', 'notification_id']) {
      if (_normalizeDataValue(data[key]) != null) {
        return 'orders';
      }
    }

    return null;
  }

  Map<String, String> _normalizeStringData(Map<String, dynamic> rawData) {
    final normalized = <String, String>{};
    for (final entry in rawData.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) {
        continue;
      }
      final value = entry.value;
      if (value == null) {
        continue;
      }
      final normalizedValue = _normalizeDataValue(value.toString());
      if (normalizedValue == null) {
        continue;
      }
      normalized[key] = normalizedValue;
    }
    return normalized;
  }

  String? _normalizeDataValue(String? raw) {
    if (raw == null) {
      return null;
    }
    var normalized = raw.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final hasWrappedDoubleQuotes =
        normalized.startsWith('"') && normalized.endsWith('"');
    final hasWrappedSingleQuotes =
        normalized.startsWith("'") && normalized.endsWith("'");
    if (hasWrappedDoubleQuotes || hasWrappedSingleQuotes) {
      normalized = normalized.substring(1, normalized.length - 1).trim();
      if (normalized.isEmpty) {
        return null;
      }
    }
    return normalized;
  }

  bool _isDuplicateForegroundMessage(RemoteMessage message) {
    final now = DateTime.now();
    _recentForegroundMessages.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _foregroundMessageDedupWindow * 4,
    );

    final key = message.messageId?.trim().isNotEmpty == true
        ? 'message_id:${message.messageId!.trim()}'
        : 'fallback:${_notificationTagForMessage(message)}';
    final seenAt = _recentForegroundMessages[key];
    if (seenAt != null &&
        now.difference(seenAt) < _foregroundMessageDedupWindow) {
      return true;
    }
    _recentForegroundMessages[key] = now;
    return false;
  }

  String _notificationTagForMessage(RemoteMessage message) {
    final id = message.messageId?.trim();
    if (id != null && id.isNotEmpty) {
      return id;
    }

    final normalizedData = _normalizeStringData(message.data);
    final title = message.notification?.title ?? normalizedData['title'] ?? '';
    final body = message.notification?.body ?? normalizedData['body'] ?? '';
    return '${title.trim()}|${body.trim()}|${_stableDataSignature(normalizedData)}';
  }

  String _stableDataSignature(Map<String, String> data) {
    if (data.isEmpty) {
      return '';
    }

    final entries = data.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((entry) => '${entry.key}=${entry.value}').join('&');
  }

  String _encodeNotificationPayload(Map<String, String> payload) {
    return jsonEncode(payload);
  }

  Map<String, String> _decodeNotificationPayload(String? payload) {
    final raw = payload?.trim();
    if (raw == null || raw.isEmpty) {
      return const {};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const {};
      }
      return decoded.map(
        (key, value) => MapEntry(
          key.toString(),
          value == null ? '' : value.toString(),
        ),
      )..removeWhere((_, value) => value.trim().isEmpty);
    } catch (_) {
      return const {};
    }
  }

  Future<void> _syncTokenToSupabase(
    String? token, {
    required String reason,
  }) async {
    final normalizedToken = token?.trim();
    if (normalizedToken == null || normalizedToken.isEmpty) {
      debugPrint('[FCM] token sync skipped because no token is available.');
      if (_shouldRetryTokenSyncWhenTokenUnavailable()) {
        _scheduleTokenSyncRetry(reason: 'token_unavailable');
      }
      return;
    }

    final client = _supabaseClientOrNull;
    final user = client?.auth.currentUser;
    if (user == null) {
      if (kIsWeb) {
        debugPrint(
          '[FCM][web] token generated but upload deferred until '
          'authenticated login.',
        );
      }
      debugPrint(
        '[FCM] token sync skipped because no authenticated Supabase user exists.',
      );
      return;
    }

    final previousToken = _lastKnownToken?.trim();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final platformName = _platformName;
    final syncSignature = _tokenSyncSignature(
      userId: user.id,
      platformName: platformName,
      token: normalizedToken,
    );
    if (_wasTokenSyncedRecently(
      userId: user.id,
      token: normalizedToken,
      platformName: platformName,
    )) {
      debugPrint(
        '[FCM] token sync skipped because the same token was synced recently.',
      );
      _resetTokenSyncRetry();
      return;
    }
    final installationId = await _resolveInstallationId();
    final deviceInfo = _buildDeviceInfo(
      installationId: installationId,
      platformName: platformName,
    );
    if (!RpcSecurityService.instance.allowLocalAction(
      'upsert_customer_device_token:${user.id}:$normalizedToken',
      window: const Duration(seconds: 2),
    )) {
      debugPrint(
        '[SECURITY][RPC_REPLAY][${DateTime.now().toUtc().toIso8601String()}] '
        'Skipped duplicated token registration RPC.',
      );
      return;
    }

    try {
      await client!.rpc(
        _registerTokenRpc,
        params: {
          'p_fcm_token': normalizedToken,
          'p_platform': platformName,
          'p_supports_http_v1': true,
          'p_device_info': deviceInfo,
        },
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.register_token_rpc',
        error: error,
        stack: stack,
      );
      await _upsertTokenFallback(
        userId: user.id,
        token: normalizedToken,
        platformName: platformName,
        nowIso: nowIso,
        deviceInfo: deviceInfo,
      );
    }

    _lastKnownToken = normalizedToken;
    _lastKnownUserId = user.id;
    _lastSuccessfulTokenSyncSignature = syncSignature;
    _lastSuccessfulTokenSyncAt = DateTime.now();
    _resetTokenSyncRetry();
    debugPrint(
      '[FCM][$reason] FCM token synced successfully: '
      '${_maskToken(normalizedToken)}',
    );
    if (kIsWeb) {
      debugPrint(
        '[FCM][web] token upload success: ${_maskToken(normalizedToken)}',
      );
    }

    if (previousToken != null &&
        previousToken.isNotEmpty &&
        previousToken != normalizedToken) {
      await _deactivateTokenByValue(
        previousToken,
        reason: 'token_rotated',
      );
    }
  }

  Future<void> _safeSyncToken(
    String? token, {
    required String reason,
  }) async {
    try {
      await _syncTokenToSupabase(token, reason: reason);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.safe_sync_token',
        error: error,
        stack: stack,
      );
      _scheduleTokenSyncRetry(reason: '$reason.failed');
    }
  }

  void _scheduleTokenSyncRetry({
    required String reason,
  }) {
    if (!_available) {
      return;
    }
    if (_currentSupabaseUserOrNull == null) {
      return;
    }
    if (_tokenSyncRetryAttempt >= _maxTokenSyncRetries) {
      debugPrint(
        '[FCM] token sync retry limit reached; last reason=$reason.',
      );
      unawaited(
        ErrorLogger.logError(
          module: 'notification_service.token_sync_retry_limit',
          action: reason,
          error: Exception(
            'Push token sync retry limit reached ($_maxTokenSyncRetries).',
          ),
        ),
      );
      return;
    }
    if (_tokenSyncRetryTimer != null) {
      return;
    }

    final delaySeconds = switch (_tokenSyncRetryAttempt) {
      0 => 2,
      1 => 4,
      2 => 8,
      3 => 12,
      4 => 20,
      _ => 30,
    };
    _tokenSyncRetryAttempt += 1;
    _tokenSyncRetryTimer = Timer(
      Duration(seconds: delaySeconds),
      () {
        _tokenSyncRetryTimer = null;
        unawaited(syncTokenIfPossible());
      },
    );
    debugPrint(
      '[FCM] scheduled token sync retry #$_tokenSyncRetryAttempt '
      'in ${delaySeconds}s (reason: $reason).',
    );
  }

  void _resetTokenSyncRetry() {
    _tokenSyncRetryTimer?.cancel();
    _tokenSyncRetryTimer = null;
    _tokenSyncRetryAttempt = 0;
  }

  bool _shouldRetryTokenSyncWhenTokenUnavailable() {
    if (_currentSupabaseUserOrNull == null) {
      return false;
    }
    if (!kIsWeb) {
      return true;
    }
    if (_webPushEndpointUnavailable) {
      debugPrint(
        '[FCM][web] token retry skipped because the optional push endpoint '
        'is unavailable or misconfigured.',
      );
      return false;
    }

    final permission = currentWebNotificationPermission();
    if (permission == 'granted') {
      return true;
    }

    debugPrint(
      '[FCM][web] token retry skipped until notification permission is granted.',
    );
    return false;
  }

  void _markWebPushEndpointUnavailable(Object error) {
    if (_webPushEndpointUnavailable) {
      return;
    }
    _webPushEndpointUnavailable = true;
    debugPrint(
      '[FCM][web] optional push endpoint unavailable; token generation '
      'skipped. $error',
    );
  }

  bool _isIgnorableWebPushEndpointError(Object error) {
    final normalized = error.toString().toLowerCase();
    return normalized.contains('err_name_not_resolved') ||
        normalized.contains('name_not_resolved') ||
        normalized.contains('name not resolved') ||
        normalized.contains('failed-service-worker-registration') ||
        normalized.contains('failed to register a serviceworker') ||
        normalized.contains('fetching the script');
  }

  Future<void> _upsertTokenFallback({
    required String userId,
    required String token,
    required String platformName,
    required String nowIso,
    required Map<String, dynamic> deviceInfo,
  }) async {
    final client = _supabaseClientOrNull;
    if (client == null) {
      throw StateError(
        'Supabase client is unavailable during notification token fallback upsert.',
      );
    }

    await client.from(_notificationTokensTable).upsert(
      {
        'user_id': userId,
        'fcm_token': token,
        'platform': platformName,
        'supports_http_v1': true,
        'device_info': deviceInfo,
        'is_active': true,
        'last_error': null,
        'last_seen_at': nowIso,
        'updated_at': nowIso,
      },
      onConflict: _notificationTokenConflictColumns,
    );
  }

  Future<void> _deactivateCurrentToken(String reason) async {
    var token = _lastKnownToken?.trim();
    if (token == null || token.isEmpty) {
      token = (await _loadCurrentToken())?.trim();
    }
    if (token == null || token.isEmpty) {
      return;
    }

    await _deactivateTokenByValue(token, reason: reason);
    if (_lastKnownToken == token) {
      _lastKnownToken = null;
    }
    if (_lastSuccessfulTokenSyncSignature != null &&
        _lastSuccessfulTokenSyncSignature!.endsWith('|$token')) {
      _lastSuccessfulTokenSyncSignature = null;
      _lastSuccessfulTokenSyncAt = null;
    }
  }

  Future<void> _deactivateTokenByValue(
    String token, {
    required String reason,
  }) async {
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) {
      return;
    }

    final client = _supabaseClientOrNull;
    final userId = _lastKnownUserId ?? client?.auth.currentUser?.id;
    if (client == null || userId == null) {
      return;
    }

    final nowIso = DateTime.now().toUtc().toIso8601String();
    if (!RpcSecurityService.instance.allowLocalAction(
      'deactivate_customer_device_token:$userId:$normalizedToken:$reason',
      window: const Duration(seconds: 2),
    )) {
      debugPrint(
        '[SECURITY][RPC_REPLAY][${DateTime.now().toUtc().toIso8601String()}] '
        'Skipped duplicated token deactivation RPC.',
      );
      return;
    }
    try {
      await client!.rpc(
        _deactivateTokenRpc,
        params: {
          'p_fcm_token': normalizedToken,
          'p_reason': reason,
        },
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.deactivate_token_rpc',
        error: error,
        stack: stack,
      );
      await client
          .from(_notificationTokensTable)
          .update({
            'is_active': false,
            'last_error': reason,
            'last_seen_at': nowIso,
          })
          .eq('user_id', userId)
          .eq(_notificationTokenColumn, normalizedToken);
    }
  }

  String _tokenSyncSignature({
    required String userId,
    required String platformName,
    required String token,
  }) {
    return '$userId|$platformName|$token';
  }

  bool _wasTokenSyncedRecently({
    required String userId,
    required String token,
    String? platformName,
  }) {
    final lastSuccessfulSyncAt = _lastSuccessfulTokenSyncAt;
    if (lastSuccessfulSyncAt == null) {
      return false;
    }

    final signature = _tokenSyncSignature(
      userId: userId,
      platformName: platformName ?? _platformName,
      token: token,
    );
    return _lastSuccessfulTokenSyncSignature == signature &&
        DateTime.now().difference(lastSuccessfulSyncAt) <
            _redundantTokenSyncWindow;
  }

  Future<String> _resolveInstallationId() async {
    final cached = _installationId?.trim();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final preferences = await SharedPreferences.getInstance();
    final fromStorage =
        preferences.getString(_installationIdStorageKey)?.trim();
    if (fromStorage != null && fromStorage.isNotEmpty) {
      _installationId = fromStorage;
      return fromStorage;
    }

    final generated = _generateInstallationId();
    await preferences.setString(_installationIdStorageKey, generated);
    _installationId = generated;
    return generated;
  }

  String _generateInstallationId() {
    final seed =
        DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(16);
    final randomChunk = List<String>.generate(
      12,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      growable: false,
    ).join();
    return '$seed$randomChunk';
  }

  Map<String, dynamic> _buildDeviceInfo({
    required String installationId,
    required String platformName,
  }) {
    final locale = PlatformDispatcher.instance.locale.toLanguageTag();
    final userAgent = currentWebUserAgent()?.trim();
    final normalizedUserAgent = userAgent?.toLowerCase() ?? '';
    final isSamsung = normalizedUserAgent.contains('samsung');
    final androidMajor = _extractAndroidMajorFromUserAgent(normalizedUserAgent);
    return {
      'app': 'restaurant_customer',
      'installation_id': installationId,
      'platform': platformName,
      'locale': locale,
      'is_web': kIsWeb,
      'supports_http_v1': true,
      'is_samsung': isSamsung,
      'android_major': androidMajor,
      if (userAgent != null && userAgent.isNotEmpty) 'user_agent': userAgent,
    };
  }

  int? _extractAndroidMajorFromUserAgent(String userAgent) {
    if (userAgent.isEmpty) {
      return null;
    }

    final match = RegExp(r'android\s+([0-9]{1,2})').firstMatch(userAgent);
    if (match == null) {
      return null;
    }
    return int.tryParse(match.group(1) ?? '');
  }

  String get _platformName {
    if (kIsWeb) {
      return 'web';
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  String _maskToken(String? token) {
    if (token == null || token.isEmpty) {
      return '<empty>';
    }
    if (token.length <= 12) {
      return token;
    }
    return '${token.substring(0, 6)}...${token.substring(token.length - 6)}';
  }

  void _logWebPermissionState(
    String? permission, {
    required String source,
  }) {
    if (!kIsWeb) {
      return;
    }
    final normalized = (permission ?? 'unknown').trim().toLowerCase();
    if (normalized == 'granted') {
      debugPrint('[FCM][web] permission granted ($source)');
      return;
    }
    if (normalized == 'denied') {
      debugPrint('[FCM][web] permission denied ($source)');
      return;
    }
    debugPrint('[FCM][web] permission default ($source)');
  }

  void _logWebTokenDebug(String? token, {required String reason}) {
    if (!kIsWeb || !kDebugMode) {
      return;
    }

    final normalized = token?.trim();
    if (normalized == null || normalized.isEmpty) {
      debugPrint('[FCM][web][debug][$reason] token=<empty>');
      return;
    }
    debugPrint('[FCM][web][debug][$reason] token(full)=$normalized');
  }
}

class _NotificationTapIntent {
  const _NotificationTapIntent({
    required this.source,
    required this.data,
  });

  final String source;
  final Map<String, String> data;
}
