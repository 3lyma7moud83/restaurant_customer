// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;

const _webStartupSplashReadyEvent = 'delivery-mat3mk-web-splash-ready';
const _webStartupSplashRemovedEvent = 'delivery-mat3mk-web-splash-removed';

void notifyWebStartupSplashReady() {
  html.window.dispatchEvent(html.Event(_webStartupSplashReadyEvent));
}

Future<void> waitForWebStartupSplashRemoved() async {
  if (html.document.getElementById('app-splash') == null) {
    return;
  }

  final completer = Completer<void>();

  late html.EventListener listener;
  listener = (_) {
    html.window.removeEventListener(_webStartupSplashRemovedEvent, listener);
    if (!completer.isCompleted) {
      completer.complete();
    }
  };

  html.window.addEventListener(_webStartupSplashRemovedEvent, listener);
  return completer.future;
}
