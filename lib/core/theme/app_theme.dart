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
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFDC2626);

  /// Semantic colors that are not represented directly by [ColorScheme].
  /// Keeping these here prevents feature widgets from guessing dark surfaces.
  static AppThemeColors colorsOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppThemeColors>() ??
        (theme.brightness == Brightness.dark
            ? AppThemeColors.dark
            : AppThemeColors.light);
  }

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
      extensions: const <ThemeExtension<dynamic>>[
        AppThemeColors.light,
      ],
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
      drawerTheme: const DrawerThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: Color(0xFFFFE7CC),
        surfaceTintColor: Colors.transparent,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: textMuted,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceMuted,
        selectedColor: const Color(0xFFFFE7CC),
        disabledColor: surfaceMuted,
        side: const BorderSide(color: border),
        labelStyle: const TextStyle(color: text, fontWeight: FontWeight.w700),
        secondaryLabelStyle:
            const TextStyle(color: text, fontWeight: FontWeight.w700),
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

  static ThemeData dark() {
    const darkSurface = Color(0xFF211F1D);
    const darkBackground = Color(0xFF171513);
    const darkBorder = Color(0xFF47423D);
    const darkText = Color(0xFFECE7E1);
    const darkMuted = Color(0xFFB8B0A8);
    const darkSurfaceMuted = Color(0xFF2B2825);
    const darkPrimary = Color(0xFFFFA24A);
    const onDarkPrimary = Color(0xFF321A05);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
      primary: darkPrimary,
      onPrimary: onDarkPrimary,
      secondary: Color(0xFFFFB66B),
      onSecondary: Color(0xFF321B06),
      surface: darkSurface,
      onSurface: darkText,
      surfaceContainerLowest: darkBackground,
      surfaceContainerLow: Color(0xFF1D1B19),
      surfaceContainer: darkSurface,
      surfaceContainerHigh: darkSurfaceMuted,
      surfaceContainerHighest: Color(0xFF35312D),
      outline: darkBorder,
      outlineVariant: Color(0xFF36322F),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'Cairo',
      fontFamilyFallback: fallbackFonts,
      useMaterial3: true,
    );
    final textTheme = base.textTheme
        .apply(
          bodyColor: darkText,
          displayColor: darkText,
        )
        .copyWith(
          bodyMedium: base.textTheme.bodyMedium?.copyWith(color: darkMuted),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            color: onDarkPrimary,
            fontWeight: FontWeight.w800,
          ),
        );
    return base.copyWith(
      extensions: const <ThemeExtension<dynamic>>[
        AppThemeColors.dark,
      ],
      colorScheme: scheme,
      scaffoldBackgroundColor: darkBackground,
      canvasColor: darkSurface,
      cardColor: darkSurface,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: const IconThemeData(color: darkText),
      primaryIconTheme: const IconThemeData(color: darkText),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkText,
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: darkText,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
        iconTheme: IconThemeData(color: darkText),
        actionsIconTheme: IconThemeData(color: darkText),
      ),
      dividerTheme: const DividerThemeData(color: darkBorder),
      cardTheme: const CardThemeData(
        color: darkSurface,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
          side: BorderSide(color: Color(0xFF302D2A)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurfaceMuted,
        hintStyle: const TextStyle(color: darkMuted),
        labelStyle: const TextStyle(color: darkMuted),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: darkPrimary, width: 1.2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: Color(0xFF36322F)),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: const BorderSide(color: darkBorder),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: darkSurface,
        modalBackgroundColor: darkSurface,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: darkSurfaceMuted,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: darkText,
          fontFamily: 'Cairo',
          fontSize: 20,
          fontWeight: FontWeight.w800,
        ),
        contentTextStyle: TextStyle(
          color: darkMuted,
          fontFamily: 'Cairo',
          height: 1.45,
        ),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: darkSurface,
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: darkSurface,
        indicatorColor: Color(0xFF5A3718),
        surfaceTintColor: Colors.transparent,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: darkSurface,
        selectedItemColor: Color(0xFFFFAD5A),
        unselectedItemColor: darkMuted,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: darkText,
        iconColor: darkMuted,
        selectedColor: darkPrimary,
        selectedTileColor: Color(0xFF5A3718),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: darkSurfaceMuted,
        surfaceTintColor: Colors.transparent,
        textStyle: TextStyle(color: darkText, fontFamily: 'Cairo'),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: const WidgetStatePropertyAll(darkText),
          overlayColor: WidgetStatePropertyAll(
            darkPrimary.withValues(alpha: 0.10),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: darkSurfaceMuted,
        selectedColor: const Color(0xFF5A3718),
        disabledColor: const Color(0xFF24211F),
        side: const BorderSide(color: darkBorder),
        labelStyle:
            const TextStyle(color: darkText, fontWeight: FontWeight.w700),
        secondaryLabelStyle:
            const TextStyle(color: darkText, fontWeight: FontWeight.w700),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF35312D),
        contentTextStyle: const TextStyle(
          color: darkText,
          fontWeight: FontWeight.w700,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: darkPrimary,
          foregroundColor: onDarkPrimary,
          minimumSize: const Size.fromHeight(56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkText,
          side: const BorderSide(color: darkBorder),
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFFFAD5A),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: darkPrimary,
          foregroundColor: onDarkPrimary,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: darkPrimary,
        foregroundColor: onDarkPrimary,
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: darkPrimary),
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(false),
        trackVisibility: const WidgetStatePropertyAll(false),
        radius: const Radius.circular(999),
        thickness: const WidgetStatePropertyAll(4),
        thumbColor: WidgetStatePropertyAll(darkMuted.withValues(alpha: 0.45)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _PremiumPageTransitionsBuilder(),
          TargetPlatform.iOS: _PremiumPageTransitionsBuilder(),
        },
      ),
    );
  }
}

@immutable
class AppThemeColors extends ThemeExtension<AppThemeColors> {
  const AppThemeColors({
    required this.surfaceMuted,
    required this.surfaceElevated,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.danger,
    required this.onDanger,
    required this.dangerContainer,
    required this.shadow,
  });

  static const light = AppThemeColors(
    surfaceMuted: AppTheme.surfaceMuted,
    surfaceElevated: Colors.white,
    border: AppTheme.border,
    textPrimary: AppTheme.text,
    textSecondary: AppTheme.textMuted,
    success: AppTheme.success,
    onSuccess: Colors.white,
    successContainer: Color(0xFFE9F7EF),
    warning: Color(0xFFB45309),
    onWarning: Colors.white,
    warningContainer: Color(0xFFFFF3E0),
    danger: AppTheme.error,
    onDanger: Colors.white,
    dangerContainer: Color(0xFFFFEDEC),
    shadow: Color(0x1A000000),
  );

  static const dark = AppThemeColors(
    surfaceMuted: Color(0xFF2B2825),
    surfaceElevated: Color(0xFF302D2A),
    border: Color(0xFF47423D),
    textPrimary: Color(0xFFECE7E1),
    textSecondary: Color(0xFFB8B0A8),
    success: Color(0xFF68D6A1),
    onSuccess: Color(0xFF062E1D),
    successContainer: Color(0xFF173B2B),
    warning: Color(0xFFFFC16B),
    onWarning: Color(0xFF3B2200),
    warningContainer: Color(0xFF493315),
    danger: Color(0xFFFFB4AB),
    onDanger: Color(0xFF4F0505),
    dangerContainer: Color(0xFF4A2220),
    shadow: Color(0x66000000),
  );

  final Color surfaceMuted;
  final Color surfaceElevated;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color danger;
  final Color onDanger;
  final Color dangerContainer;
  final Color shadow;

  @override
  AppThemeColors copyWith() => this;

  @override
  AppThemeColors lerp(covariant AppThemeColors? other, double t) {
    if (other == null) return this;
    return AppThemeColors(
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      dangerContainer: Color.lerp(dangerContainer, other.dangerContainer, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
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
