import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_firebase_options.dart';
import '../../core/services/error_logger.dart';
import '../../core/stability/notification_dedupe_service.dart';
import '../../core/stability/rpc_security_service.dart';
import '../../core/stability/stability_metrics_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/input_focus_guard.dart';
import '../../pages/orders_page.dart';
import '../session_manager.dart';
import 'web_push_bridge.dart';

const AndroidNotificationChannel _ordersNotificationChannel =
    AndroidNotificationChannel(
  'high_importance_channel',
  'Order Updates',
  description: 'Notifications for order updates and customer alerts.',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);
const String _androidNotificationIcon = 'ic_stat_notification';

const String _notificationTokensTable = 'customer_device_tokens';
const String _notificationTokenColumn = 'fcm_token';
const String _notificationTokenConflictColumns = 'user_id,fcm_token';
const String _registerTokenRpc = 'upsert_customer_device_token';
const String _deactivateTokenRpc = 'deactivate_customer_device_token';
const String _installationIdStorageKey =
    'customer_notification_installation_id';
const String _backgroundTapPayloadsStorageKey =
    'customer_pending_notification_tap_payloads';
const int _maxPersistedBackgroundTapPayloads = 10;
const int _maxTokenSyncRetries = 12;
const Duration _foregroundMessageDedupWindow = Duration(seconds: 8);
const Duration _interactionDedupWindow = Duration(seconds: 3);

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await AppNotificationService.ensureFirebaseInitialized();
  } catch (error, stack) {
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
}

@pragma('vm:entry-point')
void localNotificationTapBackgroundHandler(NotificationResponse response) {
  final payload = response.payload?.trim();
  if (payload == null || payload.isEmpty) {
    return;
  }
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

class AppNotificationService {
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

  bool _initialized = false;
  bool _available = false;
  bool _localNotificationsInitialized = false;
  bool _webBridgeInitialized = false;
  bool _webPermissionPromptAttached = false;
  bool _drainInteractionScheduled = false;
  bool _messagingListenersAttached = false;
  String? _lastKnownToken;
  String? _lastKnownUserId;
  String? _installationId;
  int _tokenSyncRetryAttempt = 0;
  final List<_NotificationTapIntent> _pendingNotificationTaps =
      <_NotificationTapIntent>[];
  final Map<String, DateTime> _recentForegroundMessages = <String, DateTime>{};
  final Map<String, DateTime> _recentInteractionSignatures =
      <String, DateTime>{};

  FirebaseMessaging get _messagingInstance {
    return _messaging ??= FirebaseMessaging.instance;
  }

  static Future<void> ensureFirebaseInitialized() async {
    if (Firebase.apps.isNotEmpty) {
      return;
    }

    final options = AppFirebaseOptions.currentPlatform;
    if (kIsWeb) {
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
      if (options != null) {
        await Firebase.initializeApp(options: options);
        return;
      }
      rethrow;
    }
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

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
      await ensureFirebaseInitialized();
      await NotificationDedupeService.instance.initialize();
      _messaging = FirebaseMessaging.instance;
      await _messagingInstance.setAutoInitEnabled(true);
      if (kIsWeb) {
        await _initializeWebNotificationBridge();
      } else {
        await _initializeLocalNotifications();
        FirebaseMessaging.onBackgroundMessage(
          firebaseMessagingBackgroundHandler,
        );
      }
      _attachMessagingListeners();
      await _requestNotificationPermissions();
      _tokenRefreshSubscription = _messagingInstance.onTokenRefresh.listen(
        (token) {
          debugPrint('[FCM] token refreshed: ${_maskToken(token)}');
          _logWebTokenDebug(token, reason: 'token_refresh');
          if (Supabase.instance.client.auth.currentUser == null) {
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
      _authSubscription =
          Supabase.instance.client.auth.onAuthStateChange.listen((event) {
        final user = event.session?.user;
        if (user == null) {
          _lastKnownUserId = null;
          _resetTokenSyncRetry();
          return;
        }
        _lastKnownUserId = user.id;
        unawaited(syncTokenIfPossible());
      });

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
          unawaited(
            _handleMessageInteraction(
              initialMessage,
              source: 'initial_message',
            ),
          );
        }
      }

      _available = true;
      final currentUser = Supabase.instance.client.auth.currentUser;
      _lastKnownUserId = currentUser?.id;
      if (currentUser == null) {
        debugPrint(
          '[FCM] startup token sync deferred until Supabase authentication is available.',
        );
      } else {
        final token = await _loadCurrentToken();
        debugPrint('[FCM] startup token: ${_maskToken(token)}');
        _logWebTokenDebug(token, reason: 'startup');
        await _safeSyncToken(token, reason: 'startup');
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.initialize',
        error: error,
        stack: stack,
      );
      debugPrint('[FCM] initialization failed: $error');
    }
  }

  Future<void> syncTokenIfPossible() async {
    if (!_initialized) {
      await initialize();
    }
    if (!_available) {
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      debugPrint(
        '[FCM] token sync skipped because no authenticated Supabase user exists.',
      );
      return;
    }

    try {
      final token = await _loadCurrentToken();
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
      final permission = await ensureWebNotificationPermission();
      _logWebPermissionState(
        permission ?? currentPermission,
        source: 'token_load_guard',
      );
      if (permission != 'granted') {
        debugPrint('[FCM][web] notification permission is not granted.');
        return null;
      }
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
    _resetTokenSyncRetry();
    _pendingNotificationTaps.clear();
    _recentForegroundMessages.clear();
    _recentInteractionSignatures.clear();
    _messagingListenersAttached = false;
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
    debugPrint(
      '[FCM] FirebaseMessaging listeners attached '
      '(onMessage, onMessageOpenedApp).',
    );
  }

  Future<void> _initializeLocalNotifications() async {
    if (kIsWeb || _localNotificationsInitialized) {
      return;
    }

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
        _queueNotificationTap(
          payload,
          source: 'local_notification_tap',
        );
        _scheduleNotificationTapDrain();
      },
      onDidReceiveBackgroundNotificationResponse:
          localNotificationTapBackgroundHandler,
    );

    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_ordersNotificationChannel);
    _localNotificationsInitialized = true;

    final launchDetails =
        await _localNotifications.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final payload = _decodeNotificationPayload(
        launchDetails?.notificationResponse?.payload,
      );
      if (payload.isNotEmpty) {
        _queueNotificationTap(
          payload,
          source: 'local_notification_launch',
        );
        _scheduleNotificationTapDrain();
      }
    }
    await _drainPersistedBackgroundNotificationTapPayloads();
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

  Future<void> _requestNotificationPermissions() async {
    NotificationSettings? settings;
    try {
      final permissionRequest = _messagingInstance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      settings = kIsWeb
          ? await permissionRequest.timeout(const Duration(seconds: 12))
          : await permissionRequest;
    } on TimeoutException {
      debugPrint(
        '[FCM][web] permission request timed out while waiting for user action.',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.request_permission',
        error: error,
        stack: stack,
      );
      debugPrint('[FCM] permission request failed: $error');
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
      try {
        await androidPlugin?.requestNotificationsPermission();
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'notification_service.request_android_permission',
          error: error,
          stack: stack,
        );
      }
    }

    if (kIsWeb) {
      if (!supportsWebBrowserNotifications()) {
        debugPrint('[FCM][web] Browser Notification API is not supported.');
        return;
      }
      try {
        final webPermission = await ensureWebNotificationPermission();
        if (webPermission != null) {
          _logWebPermissionState(webPermission, source: 'request_permission');
          debugPrint('[FCM][web] browser permission: $webPermission');
          if (webPermission == 'default') {
            _scheduleWebPermissionPromptOnFirstGesture();
          } else if (webPermission == 'granted') {
            final refreshedToken = await _loadCurrentToken();
            await _safeSyncToken(
              refreshedToken,
              reason: 'web_permission_granted',
            );
          } else if (webPermission == 'denied') {
            debugPrint(
              '[FCM][web] browser permission is denied. Enable notifications '
              'from browser site settings for this origin, then tap once '
              'inside the app to retry token sync.',
            );
            _scheduleWebPermissionPromptOnFirstGesture(allowDenied: true);
          }
        }
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'notification_service.request_web_permission',
          error: error,
          stack: stack,
        );
      }
    }
  }

  void _scheduleWebPermissionPromptOnFirstGesture({
    bool allowDenied = false,
  }) {
    if (!kIsWeb || _webPermissionPromptAttached) {
      return;
    }

    final permission = currentWebNotificationPermission();
    final shouldAttach =
        permission == 'default' || (allowDenied && permission == 'denied');
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
      } else if (permission == 'default') {
        _scheduleWebPermissionPromptOnFirstGesture();
      } else if (permission == 'denied') {
        debugPrint('[FCM][web] browser permission still denied after gesture.');
        _scheduleWebPermissionPromptOnFirstGesture(allowDenied: true);
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.request_web_permission_after_gesture',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    _logIncomingMessage(message, source: 'foreground');
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
      return;
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final fingerprint = _notificationTagForMessage(message);
    final shouldProcess =
        await NotificationDedupeService.instance.shouldProcess(
      fingerprint: fingerprint,
      source: 'foreground_push',
      userId: userId,
      dedupeWindow: _foregroundMessageDedupWindow,
    );
    if (!shouldProcess) {
      return;
    }

    final title = _normalizeBrandingText(
      message.notification?.title ??
          message.data['title']?.toString() ??
          'Delivery Mat3mk',
    );
    final body = _normalizeBrandingText(
      message.notification?.body ?? message.data['body']?.toString() ?? '',
    );
    final data = _normalizeStringData(message.data);

    final localPayload = <String, String>{
      ...data,
      if (!data.containsKey('title')) 'title': title,
      if (!data.containsKey('body')) 'body': body,
    };

    await _localNotifications.show(
      _notificationIdForMessage(message),
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _ordersNotificationChannel.id,
          _ordersNotificationChannel.name,
          channelDescription: _ordersNotificationChannel.description,
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          icon: _androidNotificationIcon,
          visibility: NotificationVisibility.public,
          channelShowBadge: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: _encodeNotificationPayload(localPayload),
    );
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
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final interactionFingerprint = message.messageId?.trim().isNotEmpty == true
        ? 'message_id:${message.messageId!.trim()}'
        : '${_resolveScreenFromData(data) ?? 'unknown'}:${_stableDataSignature(data)}';
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

    _queueNotificationTap(
      data,
      source: source,
      messageId: message.messageId,
    );
    _scheduleNotificationTapDrain();
  }

  void _queueNotificationTap(
    Map<String, String> data, {
    required String source,
    String? messageId,
  }) {
    if (data.isEmpty) {
      return;
    }

    final signature = messageId != null && messageId.trim().isNotEmpty
        ? 'message_id:${messageId.trim()}'
        : '${_resolveScreenFromData(data) ?? 'unknown'}:${_stableDataSignature(data)}';

    final now = DateTime.now();
    _recentInteractionSignatures.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _interactionDedupWindow * 4,
    );
    final seenAt = _recentInteractionSignatures[signature];
    if (seenAt != null && now.difference(seenAt) < _interactionDedupWindow) {
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
        source: intent.source,
      );
    }
  }

  Future<void> _navigateToScreen(
    NavigatorState navigator, {
    required String screen,
    required String source,
  }) async {
    final normalizedScreen = screen.trim().toLowerCase();
    final signedInUser = Supabase.instance.client.auth.currentUser;
    if (signedInUser == null) {
      await SessionManager.instance.redirectToLogin();
      return;
    }

    switch (normalizedScreen) {
      case 'orders':
      case 'order':
      case 'my_orders':
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

    for (final key in const ['click_action', 'link', 'url', 'path']) {
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
      if (normalizedPath == '/orders' ||
          normalizedPath == 'orders' ||
          normalizedPath.contains('/orders')) {
        return 'orders';
      }
    }

    final typeHint = _normalizeDataValue(data['type']) ??
        _normalizeDataValue(data['notification_type']) ??
        _normalizeDataValue(data['event']);
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

  int _notificationIdForMessage(RemoteMessage message) {
    final key = _notificationTagForMessage(message);
    return key.hashCode & 0x7fffffff;
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
      if (Supabase.instance.client.auth.currentUser != null) {
        _scheduleTokenSyncRetry(reason: 'token_unavailable');
      }
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
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
      await Supabase.instance.client.rpc(
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
    if (Supabase.instance.client.auth.currentUser == null) {
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

  Future<void> _upsertTokenFallback({
    required String userId,
    required String token,
    required String platformName,
    required String nowIso,
    required Map<String, dynamic> deviceInfo,
  }) async {
    await Supabase.instance.client.from(_notificationTokensTable).upsert(
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
  }

  Future<void> _deactivateTokenByValue(
    String token, {
    required String reason,
  }) async {
    final normalizedToken = token.trim();
    if (normalizedToken.isEmpty) {
      return;
    }

    final userId =
        _lastKnownUserId ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
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
      await Supabase.instance.client.rpc(
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
      await Supabase.instance.client
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

  String _normalizeBrandingText(String value) {
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
}

class _NotificationTapIntent {
  const _NotificationTapIntent({
    required this.source,
    required this.data,
  });

  final String source;
  final Map<String, String> data;
}
