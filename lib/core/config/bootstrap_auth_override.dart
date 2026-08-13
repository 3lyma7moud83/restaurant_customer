class BootstrapAuthOverride {
  const BootstrapAuthOverride({
    required this.email,
    required this.password,
  });

  final String email;
  final String password;

  static BootstrapAuthOverride? fromEnvironment({
    required String email,
    required String password,
  }) {
    final normalizedEmail = email.trim();
    final normalizedPassword = password.trim();
    if (normalizedEmail.isEmpty || normalizedPassword.isEmpty) {
      return null;
    }
    return BootstrapAuthOverride(
      email: normalizedEmail,
      password: normalizedPassword,
    );
  }
}
