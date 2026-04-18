import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const Color primary = Color(0xFFF28C28);
  static const Color primaryDeep = Color(0xFFE07610);
  static const Color secondary = Color(0xFF1A1A1A);
  static const Color background = Color(0xFFF7F5F1);
  static const Color surface = Colors.white;
  static const Color surfaceMuted = Color(0xFFF2F0EC);
  static const Color border = Color(0xFFE8E3DC);
  static const Color text = Color(0xFF111111);
  static const Color textMuted = Color(0xFF707070);
  static const Color success = Color(0xFF1F8A5B);
  static const List<String> fallbackFonts = <String>[
    'Noto Sans',
    'Noto Sans Arabic',
  ];

  static const Duration microInteractionDuration = Duration(milliseconds: 140);
  static const Duration sectionTransitionDuration = Duration(milliseconds: 220);
  static const Duration pageTransitionDuration = Duration(milliseconds: 320);
  static const Curve emphasizedCurve = Curves.easeOutCubic;

  static const ScrollPhysics bouncingScrollPhysics = BouncingScrollPhysics(
    parent: AlwaysScrollableScrollPhysics(),
  );

  static const ScrollPhysics standardBouncingScrollPhysics =
      BouncingScrollPhysics();

  static ScrollPhysics conditionalScrollPhysics({required bool canScroll}) {
    if (canScroll) {
      return standardBouncingScrollPhysics;
    }
    return const NeverScrollableScrollPhysics();
  }

  static PageRoute<T> platformPageRoute<T>({
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool fullscreenDialog = false,
  }) {
    return CupertinoPageRoute<T>(
      builder: builder,
      settings: settings,
      fullscreenDialog: fullscreenDialog,
    );
  }

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      primary: primary,
      secondary: secondary,
      surface: surface,
      outline: border,
    );

    final base = ThemeData(
      brightness: Brightness.light,
      fontFamily: 'Cairo',
      fontFamilyFallback: fallbackFonts,
      useMaterial3: true,
    );

    final textTheme = base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        color: text,
        fontWeight: FontWeight.w900,
        height: 1.15,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        color: text,
        fontWeight: FontWeight.w800,
        height: 1.2,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        color: text,
        fontWeight: FontWeight.w800,
        height: 1.25,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        color: text,
        fontWeight: FontWeight.w600,
        height: 1.5,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        color: textMuted,
        fontWeight: FontWeight.w600,
        height: 1.45,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w800,
        fontSize: 15,
      ),
    );

    return base.copyWith(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      canvasColor: surface,
      cardColor: surface,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      hoverColor: primary.withValues(alpha: 0.05),
      cupertinoOverrideTheme: const CupertinoThemeData(
        primaryColor: primary,
        scaffoldBackgroundColor: background,
        barBackgroundColor: surface,
        textTheme: CupertinoTextThemeData(
          primaryColor: text,
        ),
      ),
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: const IconThemeData(color: text),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: text,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        hintStyle: const TextStyle(
          color: textMuted,
          fontWeight: FontWeight.w600,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: primary, width: 1.2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: border),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ).copyWith(
          animationDuration: microInteractionDuration,
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return Colors.white.withValues(alpha: 0.12);
            }
            return null;
          }),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size.fromHeight(56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 15,
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primary,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(false),
        trackVisibility: const WidgetStatePropertyAll(false),
        radius: const Radius.circular(999),
        thickness: const WidgetStatePropertyAll(4),
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.dragged)) {
            return primary.withValues(alpha: 0.72);
          }
          return text.withValues(alpha: 0.18);
        }),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _PremiumPageTransitionsBuilder(),
          TargetPlatform.iOS: _PremiumPageTransitionsBuilder(),
          TargetPlatform.macOS: _PremiumPageTransitionsBuilder(),
          TargetPlatform.windows: _PremiumPageTransitionsBuilder(),
          TargetPlatform.linux: _PremiumPageTransitionsBuilder(),
          TargetPlatform.fuchsia: _PremiumPageTransitionsBuilder(),
        },
      ),
    );
  }
}

class _PremiumPageTransitionsBuilder extends PageTransitionsBuilder {
  const _PremiumPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curvedAnimation = CurvedAnimation(
      parent: animation,
      curve: AppTheme.emphasizedCurve,
      reverseCurve: Curves.easeInCubic,
    );
    final fadeAnimation = Tween<double>(
      begin: 0.94,
      end: 1,
    ).animate(curvedAnimation);

    return FadeTransition(
      opacity: fadeAnimation,
      child: CupertinoPageTransition(
        primaryRouteAnimation: curvedAnimation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: false,
        child: child,
      ),
    );
  }
}
