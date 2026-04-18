import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/config/app_firebase_options.dart';
import '../../core/services/error_logger.dart';

const AndroidNotificationChannel _ordersNotificationChannel =
    AndroidNotificationChannel(
  'orders-high-priority',
  'Order Updates',
  description: 'Notifications for order updates and customer alerts.',
  importance: Importance.high,
);

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

class AppNotificationService {
  AppNotificationService._();

  static final AppNotificationService instance = AppNotificationService._();

  FirebaseMessaging? _messaging;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<AuthState>? _authSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedAppSubscription;

  bool _initialized = false;
  bool _available = false;
  String? _lastKnownToken;

  FirebaseMessaging get _messagingInstance {
    return _messaging ??= FirebaseMessaging.instance;
  }

  static Future<void> ensureFirebaseInitialized() async {
    if (Firebase.apps.isNotEmpty) {
      return;
    }

    final options = AppFirebaseOptions.currentPlatform;
    if (options == null) {
      return;
    }

    await Firebase.initializeApp(options: options);
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    final options = AppFirebaseOptions.currentPlatform;
    if (options == null) {
      debugPrint(
        '[FCM] Firebase configuration is missing. Notification services are disabled.',
      );
      return;
    }

    if (kIsWeb) {
      try {
        await ensureFirebaseInitialized();
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'notification_service.initialize.web',
          error: error,
          stack: stack,
        );
      }

      debugPrint(
        '[FCM] Web runtime detected. firebase_messaging listeners are skipped.',
      );
      _available = false;
      return;
    }

    try {
      await ensureFirebaseInitialized();
      _messaging = FirebaseMessaging.instance;
      await _initializeLocalNotifications();
      await _requestNotificationPermissions();

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      _foregroundSubscription = FirebaseMessaging.onMessage.listen(
        (message) => unawaited(_handleForegroundMessage(message)),
      );
      _openedAppSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) => _logIncomingMessage(message, source: 'opened_app'),
      );
      _tokenRefreshSubscription = _messagingInstance.onTokenRefresh.listen(
        (token) {
          _lastKnownToken = token;
          debugPrint('[FCM] token refreshed: ${_maskToken(token)}');
          unawaited(_syncTokenToSupabase(token));
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
          Supabase.instance.client.auth.onAuthStateChange.listen(
        (event) {
          if (event.session?.user != null) {
            unawaited(syncTokenIfPossible());
          } else {
            unawaited(_deactivateCurrentToken('signed_out'));
          }
        },
      );

      final initialMessage = await _messagingInstance.getInitialMessage();
      if (initialMessage != null) {
        _logIncomingMessage(initialMessage, source: 'initial_message');
      }

      final token = await _messagingInstance.getToken();
      _lastKnownToken = token;
      debugPrint('[FCM] startup token: ${_maskToken(token)}');
      await _syncTokenToSupabase(token);

      _available = true;
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
    if (kIsWeb) {
      return;
    }

    if (!_initialized) {
      await initialize();
    }
    if (!_available) {
      return;
    }

    try {
      final token = await _messagingInstance.getToken();
      _lastKnownToken = token;
      await _syncTokenToSupabase(token);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.sync_token',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> dispose() async {
    await _authSubscription?.cancel();
    await _tokenRefreshSubscription?.cancel();
    await _foregroundSubscription?.cancel();
    await _openedAppSubscription?.cancel();
  }

  Future<void> _initializeLocalNotifications() async {
    if (kIsWeb) {
      return;
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();

    await _localNotifications.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    final androidPlugin =
        _localNotifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(_ordersNotificationChannel);
  }

  Future<void> _requestNotificationPermissions() async {
    final settings = await _messagingInstance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    debugPrint(
      '[FCM] permission status: ${settings.authorizationStatus.name}',
    );
  }

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    _logIncomingMessage(message, source: 'foreground');

    if (kIsWeb) {
      return;
    }

    final title = message.notification?.title ??
        message.data['title']?.toString() ??
        'إشعار جديد';
    final body =
        message.notification?.body ?? message.data['body']?.toString() ?? '';

    await _localNotifications.show(
      message.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _ordersNotificationChannel.id,
          _ordersNotificationChannel.name,
          channelDescription: _ordersNotificationChannel.description,
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  void _logIncomingMessage(RemoteMessage message, {required String source}) {
    debugPrint(
      '[FCM][$source] id=${message.messageId} '
      'title=${message.notification?.title} '
      'body=${message.notification?.body} '
      'data=${message.data}',
    );
  }

  Future<void> _syncTokenToSupabase(String? token) async {
    final normalizedToken = token?.trim();
    if (normalizedToken == null || normalizedToken.isEmpty) {
      debugPrint('[FCM] token sync skipped because no token is available.');
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
      await Supabase.instance.client.from('user_push_tokens').upsert(
        {
          'user_id': user.id,
          'token': normalizedToken,
          'platform': defaultTargetPlatform.name,
          'device_label': kIsWeb ? 'web' : defaultTargetPlatform.name,
          'is_active': true,
          'last_error': null,
          'last_seen_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'token',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.sync_token_to_supabase',
        error: error,
        stack: stack,
      );
    }
  }

  Future<void> _deactivateCurrentToken(String reason) async {
    final token = _lastKnownToken?.trim();
    if (token == null || token.isEmpty) {
      return;
    }

    try {
      await Supabase.instance.client.from('user_push_tokens').update({
        'is_active': false,
        'last_error': reason,
        'last_seen_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('token', token);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'notification_service.deactivate_token',
        error: error,
        stack: stack,
      );
    }
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
}
