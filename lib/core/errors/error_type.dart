enum ErrorType {
  network,
  auth,
  validation,
  database,
  permission,
  payment,
  notification,
  map,
  storage,
  realtime,
  timeout,
  parsing,
  unknown,
}

enum ErrorSeverity {
  low,
  medium,
  high,
  critical,
}

ErrorType parseErrorType(String? value) {
  if (value == null || value.trim().isEmpty) {
    return ErrorType.unknown;
  }

  final normalized = value.trim().toLowerCase();
  for (final type in ErrorType.values) {
    if (type.name == normalized) {
      return type;
    }
  }
  return ErrorType.unknown;
}

ErrorSeverity parseErrorSeverity(String? value) {
  if (value == null || value.trim().isEmpty) {
    return ErrorSeverity.medium;
  }

  final normalized = value.trim().toLowerCase();
  for (final severity in ErrorSeverity.values) {
    if (severity.name == normalized) {
      return severity;
    }
  }
  return ErrorSeverity.medium;
}
