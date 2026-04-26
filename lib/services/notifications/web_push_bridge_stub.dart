typedef WebNotificationTapHandler = void Function(Map<String, String> data);

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

Future<void> initializeWebNotificationBridge({
  required WebNotificationTapHandler onNotificationTap,
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
