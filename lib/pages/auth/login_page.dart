import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/error_logger.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/app_components.dart';
import '../../services/google_auth_service.dart';
import '../../services/notifications/app_notification_service.dart';
import '../../services/profile_service.dart';
import '../home_page.dart';

enum _AuthMode { login, register }

enum _AuthAction { none, email, google }

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final SupabaseClient _supabase = Supabase.instance.client;
  final ProfileService _profileService = ProfileService();
  final GoogleAuthService _googleAuthService = GoogleAuthService();

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();
  final FocusNode _nameFocusNode = FocusNode();
  final FocusNode _phoneFocusNode = FocusNode();

  late final AnimationController _introController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..forward();
  late final StreamSubscription<AuthState> _authSubscription =
      _supabase.auth.onAuthStateChange.listen((event) {
    if (event.session?.user != null) {
      unawaited(_finishAuthSuccess());
    }
  });

  _AuthMode _mode = _AuthMode.login;
  _AuthAction _activeAction = _AuthAction.none;
  bool _loading = false;
  bool _navigated = false;
  String? _errorText;
  String? _successText;

  @override
  void dispose() {
    _authSubscription.cancel();
    _introController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    _nameFocusNode.dispose();
    _phoneFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loginWithEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    if (!_isValidEmail(email)) {
      _setFeedback(error: 'اكتب بريد إلكتروني صحيح.');
      return;
    }
    if (password.isEmpty) {
      _setFeedback(error: 'كلمة المرور مطلوبة.');
      return;
    }

    await _runAuthAction(_AuthAction.email, () async {
      await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
      await _profileService.getOrCreateProfile();
      await AppNotificationService.instance.syncTokenIfPossible();
      await _finishAuthSuccess();
    });
  }

  Future<void> _registerWithEmail() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (name.isEmpty) {
      _setFeedback(error: 'اكتب الاسم أولاً.');
      return;
    }
    if (phone.length < 8) {
      _setFeedback(error: 'رقم الهاتف غير صحيح.');
      return;
    }
    if (!_isValidEmail(email)) {
      _setFeedback(error: 'اكتب بريد إلكتروني صحيح.');
      return;
    }
    if (password.isEmpty) {
      _setFeedback(error: 'كلمة المرور مطلوبة.');
      return;
    }

    await _runAuthAction(_AuthAction.email, () async {
      final response = await _supabase.auth.signUp(
        email: email,
        password: password,
        data: {
          'name': name,
          'phone': phone,
        },
      );

      if (response.session == null) {
        if (!mounted) {
          return;
        }
        setState(() {
          _loading = false;
          _mode = _AuthMode.login;
          _successText = 'تم إنشاء الحساب. راجع بريدك ثم سجّل الدخول.';
          _errorText = null;
        });
        return;
      }

      await _profileService.updateProfile(
        name: name,
        phone: phone,
      );
      await AppNotificationService.instance.syncTokenIfPossible();
      await _finishAuthSuccess();
    });
  }

  Future<void> _loginWithGoogle() async {
    await _runAuthAction(_AuthAction.google, () async {
      final result = await _googleAuthService.signIn();
      switch (result.status) {
        case GoogleAuthStatus.cancelled:
          _setFeedback(
              error: result.message ?? 'تم إلغاء تسجيل الدخول عبر Google.');
          return;
        case GoogleAuthStatus.redirecting:
          _setFeedback(
            success: 'جار تحويلك إلى Google لإكمال تسجيل الدخول...',
          );
          return;
        case GoogleAuthStatus.success:
          await AppNotificationService.instance.syncTokenIfPossible();
          await _finishAuthSuccess();
          return;
      }
    });
  }

  Future<void> _runAuthAction(
    _AuthAction action,
    Future<void> Function() actionHandler,
  ) async {
    if (_loading) {
      return;
    }

    setState(() {
      _loading = true;
      _activeAction = action;
      _errorText = null;
      _successText = null;
    });

    try {
      await actionHandler();
    } on AuthException catch (error, stack) {
      await ErrorLogger.logError(
        module: 'login_page.auth_exception',
        error: error,
        stack: stack,
      );
      _setFeedback(error: error.message);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'login_page.auth_action',
        error: error,
        stack: stack,
      );
      _setFeedback(error: error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted && !_navigated) {
        setState(() {
          _loading = false;
          _activeAction = _AuthAction.none;
        });
      }
    }
  }

  Future<void> _finishAuthSuccess() async {
    if (!mounted || _navigated) {
      return;
    }
    _navigated = true;

    if (mounted) {
      setState(() {
        _loading = false;
        _activeAction = _AuthAction.none;
        _errorText = null;
        _successText = 'تم تسجيل الدخول بنجاح.';
      });
    }

    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    navigator.pushAndRemoveUntil(
      AppTheme.platformPageRoute(builder: (_) => const HomePage()),
      (_) => false,
    );
  }

  void _setFeedback({
    String? error,
    String? success,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      _errorText = error;
      _successText = success;
    });
  }

  bool _isValidEmail(String email) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
  }

  @override
  Widget build(BuildContext context) {
    final animation = CurvedAnimation(
      parent: _introController,
      curve: AppTheme.emphasizedCurve,
    );
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          const _LoginBackground(),
          SafeArea(
            child: AnimatedPadding(
              duration: AppTheme.sectionTransitionDuration,
              curve: AppTheme.emphasizedCurve,
              padding: EdgeInsets.only(bottom: bottomInset),
              child: FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(animation),
                  child: LayoutBuilder(
                    builder: (context, viewportConstraints) {
                      return SingleChildScrollView(
                        physics: AppTheme.bouncingScrollPhysics,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: viewportConstraints.maxHeight,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: IconButton(
                                      onPressed: Navigator.of(context).canPop()
                                          ? () => Navigator.of(context).pop()
                                          : null,
                                      icon: const Icon(CupertinoIcons.xmark),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  const _LoginHero(),
                                  const SizedBox(height: 28),
                                  AppCard(
                                    padding: const EdgeInsets.all(22),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        const AppText(
                                          'الدخول إلى حسابك',
                                          role: AppTextRole.title,
                                          align: TextAlign.right,
                                        ),
                                        const SizedBox(height: 8),
                                        AppText(
                                          _mode == _AuthMode.login
                                              ? 'سجّل دخولك بسرعة لمتابعة الطلبات واستقبال الإشعارات.'
                                              : 'أنشئ حسابك بخطوات بسيطة ثم أكمل أول طلبك.',
                                          role: AppTextRole.caption,
                                          align: TextAlign.right,
                                        ),
                                        const SizedBox(height: 18),
                                        Directionality(
                                          textDirection: TextDirection.ltr,
                                          child: CupertinoSlidingSegmentedControl<
                                              _AuthMode>(
                                            groupValue: _mode,
                                            onValueChanged: (nextMode) {
                                              if (_loading ||
                                                  nextMode == null) {
                                                return;
                                              }
                                              setState(() {
                                                _mode = nextMode;
                                                _errorText = null;
                                                _successText = null;
                                              });
                                            },
                                            children: const {
                                              _AuthMode.login: Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 18,
                                                  vertical: 8,
                                                ),
                                                child: Text('تسجيل دخول'),
                                              ),
                                              _AuthMode.register: Padding(
                                                padding: EdgeInsets.symmetric(
                                                  horizontal: 18,
                                                  vertical: 8,
                                                ),
                                                child: Text('حساب جديد'),
                                              ),
                                            },
                                          ),
                                        ),
                                        const SizedBox(height: 20),
                                        if (_mode == _AuthMode.register) ...[
                                          AppInput(
                                            controller: _nameController,
                                            focusNode: _nameFocusNode,
                                            label: 'الاسم',
                                            hint: 'اسمك الكامل',
                                            prefixIcon: CupertinoIcons.person,
                                            textInputAction:
                                                TextInputAction.next,
                                            onSubmitted: (_) =>
                                                _phoneFocusNode.requestFocus(),
                                          ),
                                          const SizedBox(height: 14),
                                          AppInput(
                                            controller: _phoneController,
                                            focusNode: _phoneFocusNode,
                                            label: 'رقم الهاتف',
                                            hint: 'مثال: 01000000000',
                                            prefixIcon: CupertinoIcons.phone,
                                            keyboardType: TextInputType.phone,
                                            textInputAction:
                                                TextInputAction.next,
                                            onSubmitted: (_) =>
                                                _emailFocusNode.requestFocus(),
                                          ),
                                          const SizedBox(height: 14),
                                        ],
                                        AppInput(
                                          controller: _emailController,
                                          focusNode: _emailFocusNode,
                                          label: 'البريد الإلكتروني',
                                          hint: 'name@example.com',
                                          prefixIcon: CupertinoIcons.mail,
                                          keyboardType:
                                              TextInputType.emailAddress,
                                          textInputAction: TextInputAction.next,
                                          onSubmitted: (_) => _passwordFocusNode
                                              .requestFocus(),
                                        ),
                                        const SizedBox(height: 14),
                                        AppInput(
                                          controller: _passwordController,
                                          focusNode: _passwordFocusNode,
                                          label: 'كلمة المرور',
                                          hint: '••••••••',
                                          prefixIcon: CupertinoIcons.lock,
                                          obscureText: true,
                                          textInputAction: TextInputAction.done,
                                          onSubmitted: (_) =>
                                              _mode == _AuthMode.login
                                                  ? _loginWithEmail()
                                                  : _registerWithEmail(),
                                        ),
                                        if (_errorText != null ||
                                            _successText != null) ...[
                                          const SizedBox(height: 16),
                                          _FeedbackBanner(
                                            message:
                                                _errorText ?? _successText!,
                                            isError: _errorText != null,
                                          ),
                                        ],
                                        const SizedBox(height: 18),
                                        AppButton(
                                          label: _mode == _AuthMode.login
                                              ? 'تسجيل الدخول'
                                              : 'إنشاء الحساب',
                                          loading: _loading &&
                                              _activeAction ==
                                                  _AuthAction.email,
                                          onPressed: _mode == _AuthMode.login
                                              ? _loginWithEmail
                                              : _registerWithEmail,
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            const Expanded(child: Divider()),
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                              ),
                                              child: AppText(
                                                'أو',
                                                role: AppTextRole.caption,
                                                color: AppTheme.textMuted,
                                              ),
                                            ),
                                            const Expanded(child: Divider()),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        AppButton(
                                          label: 'المتابعة عبر Google',
                                          variant: AppButtonVariant.secondary,
                                          icon:
                                              const Icon(CupertinoIcons.globe),
                                          loading: _loading &&
                                              _activeAction ==
                                                  _AuthAction.google,
                                          onPressed:
                                              _loading ? null : _loginWithGoogle,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const Padding(
                                padding: EdgeInsets.only(top: 18),
                                child: AppText(
                                  'بالمتابعة أنت توافق على استخدام حسابك لحفظ الطلبات والإشعارات.',
                                  role: AppTextRole.caption,
                                  align: TextAlign.center,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoginBackground extends StatelessWidget {
  const _LoginBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: -120,
          right: -40,
          child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.primary.withValues(alpha: 0.10),
            ),
          ),
        ),
        Positioned(
          left: -80,
          bottom: 120,
          child: Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.035),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoginHero extends StatelessWidget {
  const _LoginHero();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(26),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x10000000),
                  blurRadius: 24,
                  offset: Offset(0, 16),
                ),
              ],
            ),
            child: const Icon(
              CupertinoIcons.bag_fill,
              color: AppTheme.primary,
              size: 34,
            ),
          ),
        ),
        const SizedBox(height: 18),
        const AppText(
          'تجربة دخول أسرع\nوأهدأ',
          role: AppTextRole.hero,
          align: TextAlign.right,
        ),
        const SizedBox(height: 10),
        AppText(
          'واجهة نظيفة، دخول آمن، وتحديثات طلباتك تصل فوراً بمجرد تفعيل الإشعارات.',
          role: AppTextRole.body,
          align: TextAlign.right,
          color: AppTheme.textMuted,
        ),
      ],
    );
  }
}

class _FeedbackBanner extends StatelessWidget {
  const _FeedbackBanner({
    required this.message,
    required this.isError,
  });

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      radius: 22,
      backgroundColor:
          isError ? const Color(0xFFFFF2F0) : const Color(0xFFF2FBF5),
      borderColor: isError ? const Color(0xFFFFD2CC) : const Color(0xFFCDEFD6),
      child: Row(
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: AppText(
              message,
              role: AppTextRole.caption,
              align: TextAlign.right,
              color: isError ? const Color(0xFFB42318) : AppTheme.success,
            ),
          ),
          const SizedBox(width: 10),
          Icon(
            isError
                ? CupertinoIcons.exclamationmark_circle
                : CupertinoIcons.check_mark_circled_solid,
            color: isError ? const Color(0xFFB42318) : AppTheme.success,
            size: 18,
          ),
        ],
      ),
    );
  }
}
