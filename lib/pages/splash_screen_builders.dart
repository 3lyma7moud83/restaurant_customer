import 'package:flutter/material.dart';

typedef SplashDestinationBuilder<T> = Widget Function(
  BuildContext context,
  T result,
);

typedef SplashErrorBuilder = Widget Function(
  BuildContext context,
  Object error,
  StackTrace stackTrace,
);
