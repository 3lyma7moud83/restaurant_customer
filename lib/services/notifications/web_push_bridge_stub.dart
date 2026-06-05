typedef WebNotificationTapHandler = void Function(Map<String, String> data);
typedef WebNotificationLifecycleHandler = void Function(
  String event,
  Map<String, String> data,
  Map<String, dynamic> metadata,
);

Future<void> ensureWebMessagingServiceWorkerReady() async {}

Future<String?> ensureWebNotificationPermission() async {
  return null;
}

String? currentWebNotificationPermission() {
  return null;
}

bool supportsWebBrowserNotifications() {
  return false;
}

bool isWebDocumentVisible() {
  return true;
}

String? currentWebUserAgent() {
  return null;
}

Future<void> initializeWebNotificationBridge({
  required WebNotificationTapHandler onNotificationTap,
  WebNotificationLifecycleHandler? onLifecycleEvent,
}) async {}

Future<bool> showForegroundWebNotification({
  required String title,
  required String body,
  required Map<String, String> data,
  String? tag,
}) async {
  return false;
}

void clearWebLaunchNotificationQueryParameters() {}
