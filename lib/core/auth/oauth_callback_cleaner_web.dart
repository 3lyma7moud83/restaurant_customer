// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;

const _authQueryKeys = <String>{
  'code',
  'state',
  'error',
  'error_code',
  'error_description',
};

bool hasOAuthCallbackParameters() {
  final uri = Uri.base;
  return _authQueryKeys.any(uri.queryParameters.containsKey) ||
      uri.fragment.contains('access_token') ||
      uri.fragment.contains('error_description');
}

String cleanOAuthRedirectUrl() {
  final uri = Uri.base;
  return uri.replace(
      queryParameters: const <String, String>{}, fragment: '').toString();
}

void clearOAuthCallbackParameters() {
  final uri = Uri.base;
  if (!hasOAuthCallbackParameters()) {
    return;
  }

  final nextQuery = Map<String, String>.from(uri.queryParameters)
    ..removeWhere((key, _) => _authQueryKeys.contains(key));
  final nextUri = uri.replace(
    queryParameters: nextQuery.isEmpty ? null : nextQuery,
    fragment: '',
  );

  html.window.history
      .replaceState(null, html.document.title, nextUri.toString());
}
