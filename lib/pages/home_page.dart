import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cart/cart_page.dart';
import '../cart/cart_provider.dart';
import '../core/auth/auth_navigation_guard.dart';
import '../core/localization/app_localizations.dart';
import '../core/localization/locale_controller.dart';
import '../core/location/location_helper.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/input_focus_guard.dart';
import '../core/ui/app_snackbar.dart';
import '../core/ui/responsive.dart';
import '../pages/app_content_page.dart';
import '../pages/auth/widgets/profile_page.dart';
import '../services/app_content_service.dart';
import '../services/notifications/app_notification_service.dart';
import '../services/profile_service.dart';
import '../services/restaurant_feed_utils.dart';
import '../services/restaurants_service.dart';
import '../services/session_manager.dart';
import '../widgets/restaurant_info_sheet.dart';
import '../widgets/restaurant_card_components.dart';
import '../widgets/restaurants_grid_section.dart';
import 'auth/login_page.dart';
import 'orders_page.dart';
import 'restaurant_menu_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SupabaseClient _client = Supabase.instance.client;
  late final RealtimeChannelController _restaurantsChannelController;
  late final ValueNotifier<_HomeUiState> _uiState =
      ValueNotifier<_HomeUiState>(const _HomeUiState.initial());

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');

  double? userLat;
  double? userLng;
  Timer? _restaurantsRefreshDebounce;
  int _restaurantsLoadRequestId = 0;

  _HomeUiState get _state => _uiState.value;

  @override
  void initState() {
    super.initState();

    _restaurantsChannelController = RealtimeChannelController(
      client: _client,
      topicPrefix: 'home-restaurants-${identityHashCode(this)}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          _scheduleRestaurantsRefresh();
        }
      },
    );

    _init();
    _listenToRestaurants();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    _searchQuery.dispose();
    _uiState.dispose();
    _restaurantsRefreshDebounce?.cancel();
    unawaited(_restaurantsChannelController.dispose());
    super.dispose();
  }

  Future<void> _init() async {
    await _getUserLocationIfNeeded();

    if (_state.locationDenied && mounted) {
      await _showLocationSheet();
    }

    await _loadRestaurants(showLoader: true);
  }

  Future<void> _getUserLocationIfNeeded() async {
    try {
      final location = await LocationHelper.requestAndGetLocation();
      if (!mounted) {
        return;
      }

      if (location == null) {
        userLat = null;
        userLng = null;
        _updateUiState(
          _state.copyWith(
            locationDenied: true,
          ),
        );
        return;
      }

      userLat = location.lat;
      userLng = location.lng;
      _updateUiState(
        _state.copyWith(
          locationDenied: false,
        ),
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'home_page.get_user_location',
        error: error,
        stack: stack,
      );
      if (!mounted) {
        return;
      }
      userLat = null;
      userLng = null;
      _updateUiState(
        _state.copyWith(
          locationDenied: true,
        ),
      );
    }
  }

  Future<void> _retryLocation() async {
    if (!mounted) {
      return;
    }
    _updateUiState(
      _state.copyWith(
        loading: true,
        hasError: false,
        locationDenied: false,
      ),
    );

    await _getUserLocationIfNeeded();

    if (_state.locationDenied && mounted) {
      await _showLocationSheet();
    }

    await _loadRestaurants(showLoader: true, forceRefresh: true);
  }

  void _listenToRestaurants() {
    _restaurantsChannelController.subscribe((client, channelName) {
      return client
          .channel(channelName)
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'managers',
            callback: _handleRestaurantInsert,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'managers',
            callback: _handleRestaurantUpdate,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'managers',
            callback: _handleRestaurantDelete,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'restaurant_locations',
            callback: _handleRestaurantLocationMutation,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'restaurant_locations',
            callback: _handleRestaurantLocationMutation,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'restaurant_locations',
            callback: _handleRestaurantLocationMutation,
          );
    });
  }

  void _handleRestaurantInsert(PostgresChangePayload _) {
    RestaurantsService.invalidateListCaches();
    _scheduleRestaurantsRefresh();
  }

  void _handleRestaurantUpdate(PostgresChangePayload _) {
    RestaurantsService.invalidateListCaches();
    _scheduleRestaurantsRefresh();
  }

  void _handleRestaurantLocationMutation(PostgresChangePayload _) {
    RestaurantsService.invalidateListCaches();
    _scheduleRestaurantsRefresh();
  }

  void _handleRestaurantDelete(PostgresChangePayload payload) {
    RestaurantsService.invalidateListCaches();
    final restaurantId = RestaurantFeedUtils.realtimeRestaurantIdOf(
      payload.oldRecord,
    );
    if (restaurantId.isEmpty) {
      _scheduleRestaurantsRefresh();
      return;
    }
    _removeRestaurantRealtime(restaurantId);
    _scheduleRestaurantsRefresh();
  }

  void _scheduleRestaurantsRefresh() {
    _restaurantsRefreshDebounce?.cancel();
    final debounceDuration = kIsWeb
        ? const Duration(milliseconds: 420)
        : const Duration(milliseconds: 300);
    _restaurantsRefreshDebounce = Timer(
      debounceDuration,
      () {
        if (!mounted) {
          return;
        }
        unawaited(_loadRestaurants(forceRefresh: true));
      },
    );
  }

  Future<void> _loadRestaurants({
    bool showLoader = false,
    bool forceRefresh = false,
  }) async {
    final requestId = ++_restaurantsLoadRequestId;

    if (showLoader && mounted) {
      _updateUiState(
        _state.copyWith(
          loading: true,
          hasError: false,
        ),
      );
    }

    try {
      final restaurants = userLat == null || userLng == null
          ? await RestaurantsService.getAllActive(forceRefresh: forceRefresh)
          : await RestaurantsService.getNearby(
              latitude: userLat!,
              longitude: userLng!,
              forceRefresh: forceRefresh,
            );

      if (!mounted || requestId != _restaurantsLoadRequestId) {
        return;
      }

      final ranged = RestaurantFeedUtils.filterByRange(
        source: restaurants,
        customerLat: userLat,
        customerLng: userLng,
      );

      _applyRestaurantsSnapshot(
        ranged,
        isLoading: false,
        hasLoadError: false,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'home_page.load_restaurants',
        error: error,
        stack: stack,
      );

      if (!mounted || requestId != _restaurantsLoadRequestId) {
        return;
      }

      _applyRestaurantsSnapshot(
        _state.shops,
        isLoading: false,
        hasLoadError: true,
      );
    }
  }

  void _applyRestaurantsSnapshot(
    List<Map<String, dynamic>> nextRestaurants, {
    required bool isLoading,
    required bool hasLoadError,
  }) {
    final currentState = _state;
    final currentShops = currentState.shops;
    final merged =
        RestaurantFeedUtils.reuseRestaurantMaps(currentShops, nextRestaurants);
    final listChanged =
        !RestaurantFeedUtils.sameIdentityList(currentShops, merged);

    if (!listChanged &&
        currentState.loading == isLoading &&
        currentState.hasError == hasLoadError) {
      return;
    }

    _updateUiState(
      currentState.copyWith(
        shops: merged,
        loading: isLoading,
        hasError: hasLoadError,
      ),
    );
  }

  void _removeRestaurantRealtime(String restaurantId) {
    final currentShops = _state.shops;
    final nextRestaurants = currentShops
        .where(
            (item) => RestaurantsService.restaurantIdOf(item) != restaurantId)
        .toList(growable: false);

    if (nextRestaurants.length == currentShops.length) {
      return;
    }

    _applyRestaurantsSnapshot(
      nextRestaurants,
      isLoading: false,
      hasLoadError: false,
    );
  }

  void _handleSearchChanged() {
    final text = _searchController.text;
    if (_searchQuery.value == text) {
      return;
    }
    _searchQuery.value = text;
  }

  Future<void> _refreshRestaurants() {
    return _loadRestaurants(forceRefresh: true);
  }

  void _dismissActiveInput() {
    InputFocusGuard.dismiss(context: context);
  }

  Future<void> _openCart() async {
    _dismissActiveInput();
    final cart = CartProvider.read(context);
    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    if (!mounted) {
      return;
    }

    try {
      await InputFocusGuard.prepareForUiTransition(context: context);
      if (!mounted) {
        return;
      }
      await Navigator.push(
        context,
        AppTheme.platformPageRoute(
          builder: (_) => CartPage(
            restaurantId: cart.restaurantId ?? '',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      AppSnackBar.show(
        context,
        message: context.tr('home.cart_open_failed'),
      );
    }
  }

  Future<void> _openRestaurantMenu(
    BuildContext context,
    Map<String, dynamic> restaurant,
  ) async {
    _dismissActiveInput();
    final managerId = RestaurantsService.managerIdOf(restaurant);
    final restaurantId = RestaurantsService.restaurantIdOf(restaurant);
    final restaurantName = RestaurantsService.restaurantNameOf(restaurant);

    if (managerId.isEmpty || restaurantId.isEmpty) {
      AppSnackBar.show(
        context,
        message: context.tr('home.restaurant_data_incomplete'),
      );
      return;
    }

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!context.mounted) {
      return;
    }

    Navigator.push(
      context,
      AppTheme.platformPageRoute(
        builder: (_) => RestaurantMenuPage(
          managerId: managerId,
          restaurantId: restaurantId,
          restaurantName: restaurantName,
        ),
      ),
    );
  }

  Future<void> _showLocationSheet() async {
    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }

    await showModalBottomSheet(
      context: context,
      isDismissible: false,
      enableDrag: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on, size: 44),
              const SizedBox(height: 12),
              Text(
                context.tr('home.location_needed_title'),
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr('home.location_needed_subtitle'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await InputFocusGuard.prepareForUiTransition(
                      context: context,
                    );
                    if (!mounted || !navigator.mounted) {
                      return;
                    }
                    navigator.pop();
                    unawaited(_retryLocation());
                  },
                  child: Text(context.tr('common.enable_location')),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _updateUiState(_HomeUiState nextState) {
    final current = _uiState.value;
    if (identical(current, nextState) ||
        (current.loading == nextState.loading &&
            current.hasError == nextState.hasError &&
            current.locationDenied == nextState.locationDenied &&
            RestaurantFeedUtils.sameIdentityList(
              current.shops,
              nextState.shops,
            ))) {
      return;
    }
    _uiState.value = nextState;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final appBarLeadingWidth = _HomeHeaderMetrics.menuSlotWidthFor(width);
    final appBarTitleSpacing = _HomeHeaderMetrics.titleSpacingFor(width);
    final headingFontSize = width < 360
        ? 24.0
        : width < 900
            ? 28.0
            : 30.0;
    final searchGap = width < 360
        ? 10.0
        : width < 900
            ? 12.0
            : 14.0;
    final listGap = width < 360
        ? 12.0
        : width < 900
            ? 14.0
            : 16.0;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leadingWidth: appBarLeadingWidth,
        titleSpacing: appBarTitleSpacing,
        toolbarHeight: _HomeHeaderMetrics.toolbarHeightFor(width),
        centerTitle: true,
        leading: Builder(
          builder: (context) {
            return IconButton(
              icon: const Icon(
                Icons.menu_rounded,
                size: 28,
              ),
              onPressed: () {
                Scaffold.maybeOf(context)?.openDrawer();
              },
            );
          },
        ),
        title: _HomeAppBarTitle(
          compact: _HomeHeaderMetrics.compactTitleFor(width),
        ),
        actions: [
          _HomeLanguageActionSlot(viewportWidth: width),
          _HomeCartActionSlot(
            onOpenCart: _openCart,
            viewportWidth: width,
          ),
        ],
      ),
      drawer: _MainDrawer(client: _client),
      body: ValueListenableBuilder<_HomeUiState>(
        valueListenable: _uiState,
        builder: (context, state, _) {
          final locationDenied = state.locationDenied;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _dismissActiveInput,
            child: AppConstrainedContent(
              maxWidth:
                  kIsWeb ? _HomeHeaderMetrics.contentMaxWidthFor(width) : null,
              padding: _HomeHeaderMetrics.contentPaddingFor(width),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: Alignment.center,
                    child: Text(
                      context.tr('home.nearby_restaurants'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: headingFontSize,
                        fontWeight: FontWeight.w900,
                        height: 1.12,
                      ),
                    ),
                  ),
                  SizedBox(height: searchGap),
                  _SearchBar(controller: _searchController),
                  SizedBox(height: listGap),
                  Expanded(
                    child: RestaurantsGridSection(
                      loading: state.loading,
                      hasError: state.hasError,
                      restaurants: state.shops,
                      searchQueryListenable: _searchQuery,
                      onRefresh: _refreshRestaurants,
                      customerLat: userLat,
                      customerLng: userLng,
                      loadingSkeletonKey: 'home-loading',
                      errorKey: 'home-error',
                      emptyKey: 'home-empty',
                      gridKey: 'home-grid',
                      emptyStateBuilder: (_) => _EmptyState(
                        locationDenied: locationDenied,
                        onRetry: _refreshRestaurants,
                        onRetryLocation: locationDenied ? _retryLocation : null,
                      ),
                      errorStateBuilder: (_) => _HomeErrorState(
                        onRetry: _refreshRestaurants,
                        onRetryLocation: locationDenied ? _retryLocation : null,
                      ),
                      onRestaurantInfoTap: (context, restaurant) {
                        showRestaurantInfoSheet(
                          context,
                          restaurant: restaurant,
                        );
                      },
                      onRestaurantTap: (context, restaurant) => unawaited(
                        _openRestaurantMenu(context, restaurant),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HomeUiState {
  const _HomeUiState({
    required this.loading,
    required this.hasError,
    required this.locationDenied,
    required this.shops,
  });

  const _HomeUiState.initial()
      : loading = true,
        hasError = false,
        locationDenied = false,
        shops = const [];

  final bool loading;
  final bool hasError;
  final bool locationDenied;
  final List<Map<String, dynamic>> shops;

  _HomeUiState copyWith({
    bool? loading,
    bool? hasError,
    bool? locationDenied,
    List<Map<String, dynamic>>? shops,
  }) {
    return _HomeUiState(
      loading: loading ?? this.loading,
      hasError: hasError ?? this.hasError,
      locationDenied: locationDenied ?? this.locationDenied,
      shops: shops ?? this.shops,
    );
  }
}

class _HomeAppBarTitle extends StatelessWidget {
  const _HomeAppBarTitle({
    this.compact = false,
  });

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final iconSize = width >= 900
        ? 24.0
        : compact
            ? 18.5
            : 20.8;
    final fontSize = width >= 900
        ? 19.0
        : compact
            ? 15.2
            : 16.8;
    final appName = context.tr('app.name');

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: _HomeHeaderMetrics.titleHorizontalInsetFor(width),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delivery_dining_rounded,
              color: AppTheme.primary,
              size: iconSize,
            ),
            SizedBox(width: compact ? 5 : 7),
            Text(
              appName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.text,
                fontWeight: FontWeight.w900,
                fontSize: fontSize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeHeaderMetrics {
  const _HomeHeaderMetrics._();

  static double menuSlotWidthFor(double width) {
    if (width >= 1200) {
      return 86;
    }
    if (width >= 900) {
      return 82;
    }
    if (width >= 520) {
      return 78;
    }
    if (width >= 390) {
      return 74;
    }
    return 72;
  }

  static double contentMaxWidthFor(double width) {
    if (width >= 2200) {
      return 1400;
    }
    if (width >= 1800) {
      return 1360;
    }
    if (width >= 1500) {
      return 1320;
    }
    if (width >= 1200) {
      return 1220;
    }
    if (width >= 900) {
      return 1100;
    }
    return width;
  }

  static EdgeInsets contentPaddingFor(double width) {
    if (width >= 1200) {
      return const EdgeInsets.fromLTRB(24, 14, 24, 18);
    }
    if (width >= 900) {
      return const EdgeInsets.fromLTRB(20, 13, 20, 16);
    }
    if (width >= 520) {
      return const EdgeInsets.fromLTRB(14, 12, 14, 14);
    }
    if (width >= 390) {
      return const EdgeInsets.fromLTRB(12, 10, 12, 12);
    }
    return const EdgeInsets.fromLTRB(10, 8, 10, 10);
  }

  static double toolbarHeightFor(double width) {
    if (width >= 1200) {
      return 72;
    }
    if (width >= 900) {
      return 70;
    }
    if (width >= 520) {
      return 66;
    }
    if (width >= 390) {
      return 62;
    }
    return 60;
  }

  static double actionExtentFor(double width) {
    if (width >= 1200) {
      return 50;
    }
    if (width >= 900) {
      return 48;
    }
    if (width >= 520) {
      return 46;
    }
    if (width >= 390) {
      return 44;
    }
    return 42;
  }

  static double sideInsetFor(double width) {
    if (width >= 900) {
      return 14;
    }
    if (width >= 520) {
      return 11;
    }
    if (width >= 390) {
      return 9;
    }
    return 8;
  }

  static double languageHorizontalPaddingFor(double width) {
    if (width >= 900) {
      return 11.5;
    }
    if (width >= 520) {
      return 9.8;
    }
    if (width >= 390) {
      return 8.8;
    }
    if (width >= 360) {
      return 7.8;
    }
    return 7.0;
  }

  static double languageVerticalPaddingFor(double width) {
    if (width >= 900) {
      return 5.8;
    }
    if (width >= 390) {
      return 5.2;
    }
    return 4.4;
  }

  static double languageFontSizeFor(double width) {
    if (width >= 900) {
      return 11;
    }
    if (width >= 520) {
      return 10.6;
    }
    if (width >= 390) {
      return 10.0;
    }
    if (width >= 360) {
      return 9.6;
    }
    return 9.2;
  }

  static double titleSpacingFor(double width) {
    if (width >= 900) {
      return 8;
    }
    if (width >= 520) {
      return 6;
    }
    return 4;
  }

  static double titleHorizontalInsetFor(double width) {
    if (width >= 900) {
      return 10;
    }
    if (width >= 520) {
      return 6;
    }
    return 2;
  }

  static bool compactTitleFor(double width) {
    return width < 430;
  }
}

class _HomeLanguageActionSlot extends StatelessWidget {
  const _HomeLanguageActionSlot({
    required this.viewportWidth,
  });

  final double viewportWidth;

  @override
  Widget build(BuildContext context) {
    if (viewportWidth < 360) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsetsDirectional.only(
        end: _HomeHeaderMetrics.sideInsetFor(viewportWidth) * 0.4,
      ),
      child: _HomeLanguageToggleButton(
        segmentHorizontalPadding:
            _HomeHeaderMetrics.languageHorizontalPaddingFor(viewportWidth),
        segmentVerticalPadding:
            _HomeHeaderMetrics.languageVerticalPaddingFor(viewportWidth),
        segmentFontSize: _HomeHeaderMetrics.languageFontSizeFor(viewportWidth),
      ),
    );
  }
}

class _HomeCartActionSlot extends StatelessWidget {
  const _HomeCartActionSlot({
    required this.onOpenCart,
    required this.viewportWidth,
  });

  final Future<void> Function() onOpenCart;
  final double viewportWidth;

  @override
  Widget build(BuildContext context) {
    final buttonExtent = _HomeHeaderMetrics.actionExtentFor(viewportWidth);
    final sideInset = _HomeHeaderMetrics.sideInsetFor(viewportWidth);
    return Padding(
      padding: EdgeInsetsDirectional.only(end: sideInset),
      child: _HomeCartAction(
        onTap: onOpenCart,
        buttonExtent: buttonExtent + 2,
      ),
    );
  }
}

class HomeDrawerMenuButton extends StatefulWidget {
  const HomeDrawerMenuButton({
    super.key,
    required this.viewportWidth,
  });

  final double viewportWidth;

  @override
  State<HomeDrawerMenuButton> createState() => _HomeDrawerMenuButtonState();
}

class _HomeDrawerMenuButtonState extends State<HomeDrawerMenuButton> {
  bool _openingDrawer = false;

  Future<void> _openDrawer(
    BuildContext scaffoldContext,
  ) async {
    if (_openingDrawer) return;

    setState(() => _openingDrawer = true);

    try {
      await InputFocusGuard.prepareForUiTransition(
        context: scaffoldContext,
      );

      if (!mounted || !scaffoldContext.mounted) return;

      Scaffold.maybeOf(scaffoldContext)?.openDrawer();
    } finally {
      if (mounted) {
        setState(() => _openingDrawer = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final buttonExtent =
        (_HomeHeaderMetrics.actionExtentFor(widget.viewportWidth) + 4)
            .clamp(44.0, 54.0)
            .toDouble();

    final iconSize = buttonExtent * 0.60;
    final radius = 14.0;
    final borderSide = BorderSide(
      color: AppTheme.primaryDeep.withValues(alpha: 0.25),
      width: 1,
    );

    return Builder(
      builder: (scaffoldContext) {
        final tooltip =
            MaterialLocalizations.of(scaffoldContext).openAppDrawerTooltip;
        return Semantics(
          button: true,
          label: tooltip,
          child: IconButton(
            key: const Key('home-drawer-menu-button'),
            tooltip: tooltip,
            onPressed: _openingDrawer
                ? null
                : () => unawaited(_openDrawer(scaffoldContext)),
            icon: Icon(
              Icons.menu_rounded,
              size: iconSize,
              color: AppTheme.primaryDeep,
            ),
            splashRadius: buttonExtent * 0.52,
            visualDensity: VisualDensity.standard,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFFFFBF6),
              foregroundColor: AppTheme.primaryDeep,
              padding: EdgeInsets.zero,
              fixedSize: Size.square(buttonExtent),
              minimumSize: Size.square(buttonExtent),
              maximumSize: Size.square(buttonExtent),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
              side: borderSide,
              elevation: kIsWeb ? 0.5 : 2,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        );
      },
    );
  }
}

class _TopBarActionShell extends StatelessWidget {
  const _TopBarActionShell({
    required this.child,
    required this.radius,
  });

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, Color(0xFFF8F7F4)],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppTheme.border.withValues(alpha: 0.95)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.10),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
          const BoxShadow(
            color: Color(0x10000000),
            blurRadius: 9,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _DrawerTile extends StatelessWidget {
  const _DrawerTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return ListTile(
      dense: false,
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 19, color: AppTheme.primaryDeep),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: AppTheme.text,
        ),
      ),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
      trailing: trailing ??
          (onTap == null
              ? null
              : Icon(
                  isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  color: Color(0xFF98A2B3),
                )),
      onTap: onTap,
    );
  }
}

class _HomeCartAction extends StatelessWidget {
  const _HomeCartAction({
    required this.onTap,
    required this.buttonExtent,
  });

  final Future<void> Function() onTap;
  final double buttonExtent;

  @override
  Widget build(BuildContext context) {
    final cart = CartProvider.of(context);
    final buttonRadius = buttonExtent <= 43 ? 13.0 : 15.0;
    final badgeHeight = buttonExtent <= 43 ? 18.0 : 19.0;
    final badgeFontSize = buttonExtent <= 43 ? 9.6 : 10.2;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Tooltip(
          message: context.tr('cart.title'),
          child: _TopBarActionShell(
            radius: buttonRadius,
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(buttonRadius),
              child: InkWell(
                borderRadius: BorderRadius.circular(buttonRadius),
                onTap: () {
                  InputFocusGuard.dismiss(context: context);
                  unawaited(onTap());
                },
                child: SizedBox(
                  width: buttonExtent,
                  height: buttonExtent,
                  child: Icon(
                    Icons.shopping_bag_outlined,
                    size: buttonExtent * 0.56,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (cart.totalCount > 0)
          PositionedDirectional(
            top: -3,
            end: -3,
            child: Container(
              height: badgeHeight,
              constraints: BoxConstraints(minWidth: badgeHeight),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white,
                  width: 1.2,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x18000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: Text(
                cart.totalCount.toString(),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: badgeFontSize,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _HomeLanguageToggleButton extends StatelessWidget {
  const _HomeLanguageToggleButton({
    required this.segmentHorizontalPadding,
    required this.segmentVerticalPadding,
    required this.segmentFontSize,
  });

  final double segmentHorizontalPadding;
  final double segmentVerticalPadding;
  final double segmentFontSize;

  @override
  Widget build(BuildContext context) {
    final localeController = AppLocaleScope.of(context);
    final isArabic = localeController.isArabic;
    final borderRadius = BorderRadius.circular(999);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: borderRadius,
        border: Border.all(color: AppTheme.border.withValues(alpha: 0.94)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 12,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LanguageSegment(
              label: 'AR',
              selected: isArabic,
              horizontalPadding: segmentHorizontalPadding,
              verticalPadding: segmentVerticalPadding,
              fontSize: segmentFontSize,
              onTap: () => unawaited(
                AppLocaleScope.read(context).setLocale(const Locale('ar')),
              ),
            ),
            _LanguageSegment(
              label: 'EN',
              selected: !isArabic,
              horizontalPadding: segmentHorizontalPadding,
              verticalPadding: segmentVerticalPadding,
              fontSize: segmentFontSize,
              onTap: () => unawaited(
                AppLocaleScope.read(context).setLocale(const Locale('en')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageSegment extends StatelessWidget {
  const _LanguageSegment({
    required this.label,
    required this.selected,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.fontSize,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final double horizontalPadding;
  final double verticalPadding;
  final double fontSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primary : Colors.transparent;
    final textColor = selected ? Colors.white : AppTheme.textMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          InputFocusGuard.dismiss(context: context);
          onTap();
        },
        child: AnimatedContainer(
          duration: AppTheme.microInteractionDuration,
          curve: AppTheme.emphasizedCurve,
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: verticalPadding,
          ),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w800,
              fontSize: fontSize,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    this.locationDenied = false,
    this.onRetry,
    this.onRetryLocation,
  });

  final bool locationDenied;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onRetryLocation;

  @override
  Widget build(BuildContext context) {
    final subtitle = locationDenied
        ? context.tr('home.empty_location_disabled_subtitle')
        : context.tr('home.empty_general_subtitle');

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.store_mall_directory_outlined,
              size: 80,
              color: Colors.orange,
            ),
            const SizedBox(height: 12),
            Text(
              context.tr('home.empty_nearby_title'),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.black54),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (locationDenied && onRetryLocation != null) ...[
              OutlinedButton(
                onPressed: () => unawaited(onRetryLocation!()),
                child: Text(context.tr('home.enable_location_again')),
              ),
              const SizedBox(height: 8),
            ],
            if (onRetry != null)
              TextButton(
                onPressed: () => unawaited(onRetry!()),
                child: Text(context.tr('common.retry')),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeErrorState extends StatelessWidget {
  const _HomeErrorState({
    required this.onRetry,
    this.onRetryLocation,
  });

  final Future<void> Function() onRetry;
  final Future<void> Function()? onRetryLocation;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 62,
              color: Color(0xFF98A2B3),
            ),
            const SizedBox(height: 12),
            Text(
              context.tr('home.error_title'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              context.tr('home.error_subtitle'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF667085)),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => unawaited(onRetry()),
              child: Text(context.tr('common.retry')),
            ),
            if (onRetryLocation != null) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => unawaited(onRetryLocation!()),
                child: Text(context.tr('common.enable_location')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MainDrawer extends StatefulWidget {
  const _MainDrawer({required this.client});

  final SupabaseClient client;

  @override
  State<_MainDrawer> createState() => _MainDrawerState();
}

class _MainDrawerState extends State<_MainDrawer> {
  final ProfileService _profileService = ProfileService();
  Map<String, dynamic>? customerProfile;
  StreamSubscription<AuthState>? _authSubscription;
  bool _profileLoading = true;
  bool _signingOut = false;
  bool _drawerVisible = kIsWeb;
  Locale? _contentLocale;
  Future<AppContentEntry>? _appVersionFuture;

  @override
  void initState() {
    super.initState();
    _loadCustomerProfile();
    _authSubscription = widget.client.auth.onAuthStateChange.listen((event) {
      final user = event.session?.user;
      if (user == null) {
        if (!mounted) {
          return;
        }
        setState(() {
          customerProfile = null;
          _profileLoading = false;
        });
        return;
      }
      unawaited(_loadCustomerProfile());
    });
    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _drawerVisible = true);
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_contentLocale != locale || _appVersionFuture == null) {
      _contentLocale = locale;
      _appVersionFuture = AppContentService.fetchEntry(
        section: AppContentSection.appSettings,
        locale: locale,
      );
    }
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    super.dispose();
  }

  Future<void> _loadCustomerProfile() async {
    final user = widget.client.auth.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          customerProfile = null;
          _profileLoading = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() => _profileLoading = true);
    }

    try {
      final res = await _profileService.getOrCreateProfile();
      if (!mounted) {
        return;
      }
      setState(() {
        customerProfile = res;
      });
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'home_page.drawer.load_customer_profile',
        error: error,
        stack: stack,
      );
    } finally {
      if (mounted) {
        setState(() => _profileLoading = false);
      }
    }
  }

  Future<void> _openLoginPage() async {
    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(context);

    await Navigator.push(
      context,
      AppTheme.platformPageRoute(builder: (_) => const LoginPage()),
    );

    if (!mounted) return;
    await _loadCustomerProfile();
  }

  Future<void> _openDrawerPage(Widget page) async {
    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(context);

    await Navigator.push(
      context,
      AppTheme.platformPageRoute(builder: (_) => page),
    );
  }

  Future<void> _signOut() async {
    if (_signingOut || !mounted) {
      return;
    }

    setState(() => _signingOut = true);
    try {
      try {
        await AppNotificationService.instance
            .deactivateCurrentTokenBeforeSignOut(
          reason: 'signed_out',
        );
      } catch (error, stack) {
        await ErrorLogger.logError(
          module: 'home_page.sign_out.deactivate_push_token',
          error: error,
          stack: stack,
        );
      }

      await widget.client.auth.signOut();
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'home_page.sign_out',
        error: error,
        stack: stack,
      );
      await SessionManager.instance.redirectToLogin();
    } finally {
      if (mounted) {
        setState(() => _signingOut = false);
      }
    }
  }

  Future<void> _openContentPage({
    required AppContentSection section,
    required String fallbackTitle,
  }) async {
    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(context);

    await Navigator.push(
      context,
      AppTheme.platformPageRoute(
        builder: (_) => AppContentPage(
          section: section,
          fallbackTitle: fallbackTitle,
        ),
      ),
    );
  }

  Future<void> _openComplaintSheet() async {
    final sentMessage = context.tr('drawer.complaint_sent');
    final cart = CartProvider.maybeOf(context);
    final preferredRestaurantId = cart?.restaurantId?.trim();

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(context);

    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    final submitted = await showComplaintComposerSheet(
      context,
      restaurantId:
          preferredRestaurantId?.isEmpty == true ? null : preferredRestaurantId,
    );
    if (!mounted || submitted != true) {
      return;
    }
    AppSnackBar.show(
      context,
      message: sentMessage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.client.auth.currentUser;
    final isGuest = user == null;
    final customerName = (customerProfile?['name'] ?? '').toString().trim();
    final profileImage =
        (customerProfile?['image_url'] ?? '').toString().trim();
    final hasProfileImage = profileImage.isNotEmpty;
    final userEmail = user?.email?.trim();

    final displayName = isGuest
        ? context.tr('home.guest_welcome')
        : customerName.isNotEmpty
            ? customerName
            : (_profileLoading
                ? context.tr('home.loading_account')
                : context.tr('home.customer_account'));
    const avatarSize = 56.0;

    final drawerContent = RepaintBoundary(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 40, 20, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.primary, AppTheme.secondary],
              ),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: avatarSize / 2,
                  backgroundColor: Colors.white,
                  child: !isGuest && hasProfileImage
                      ? ClipOval(
                          child: AppCachedImage(
                            imageUrl: profileImage,
                            width: avatarSize,
                            height: avatarSize,
                            fit: BoxFit.cover,
                            errorWidget: const Icon(
                              Icons.person,
                              color: AppTheme.primary,
                            ),
                          ),
                        )
                      : !isGuest
                          ? const Icon(Icons.person, color: AppTheme.primary)
                          : const Icon(Icons.login, color: AppTheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (!isGuest &&
                          userEmail != null &&
                          userEmail.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          userEmail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (isGuest)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
              child: Card(
                elevation: 0,
                color: const Color(0xFFFFF3E0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListTile(
                  leading: const Icon(
                    Icons.login,
                    color: Color(0xffFF5722),
                  ),
                  title: Text(context.tr('home.login_to_order')),
                  trailing: const Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 18,
                  ),
                  onTap: _openLoginPage,
                ),
              ),
            )
          else ...[
            _DrawerTile(
              icon: Icons.person_outline,
              title: context.tr('home.profile'),
              onTap: () => unawaited(_openDrawerPage(const ProfilePage())),
            ),
            _DrawerTile(
              icon: Icons.receipt_long,
              title: context.tr('home.orders'),
              onTap: () => unawaited(_openDrawerPage(const OrdersPage())),
            ),
          ],
          const Divider(height: 22),
          _DrawerTile(
            icon: Icons.support_agent_rounded,
            title: context.tr('drawer.support'),
            onTap: () => unawaited(
              _openContentPage(
                section: AppContentSection.supportSettings,
                fallbackTitle: context.tr('drawer.support'),
              ),
            ),
          ),
          _DrawerTile(
            icon: Icons.report_gmailerrorred_rounded,
            title: context.tr('drawer.complaint'),
            onTap: () => unawaited(_openComplaintSheet()),
          ),
          _DrawerTile(
            icon: Icons.privacy_tip_outlined,
            title: context.tr('drawer.privacy'),
            onTap: () => unawaited(
              _openContentPage(
                section: AppContentSection.privacyPolicy,
                fallbackTitle: context.tr('drawer.privacy'),
              ),
            ),
          ),
          _DrawerTile(
            icon: Icons.shield_outlined,
            title: context.tr('drawer.security'),
            onTap: () => unawaited(
              _openContentPage(
                section: AppContentSection.securityPolicy,
                fallbackTitle: context.tr('drawer.security'),
              ),
            ),
          ),
          FutureBuilder<AppContentEntry>(
            future: _appVersionFuture,
            builder: (context, snapshot) {
              final versionLabel = (snapshot.data?.content ?? 'v1.0.0').trim();
              return _DrawerTile(
                icon: Icons.info_outline_rounded,
                title: context.tr('drawer.version'),
                subtitle: versionLabel.isEmpty ? 'v1.0.0' : versionLabel,
                onTap: () => unawaited(
                  _openContentPage(
                    section: AppContentSection.appSettings,
                    fallbackTitle: context.tr('drawer.version'),
                  ),
                ),
              );
            },
          ),
          if (!isGuest) ...[
            const Divider(height: 22),
            _DrawerTile(
              icon: Icons.logout,
              title: context.tr('home.logout'),
              trailing: _signingOut
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              onTap: _signingOut ? null : _signOut,
            ),
          ],
        ],
      ),
    );

    final drawerAnimationDuration =
        kIsWeb ? Duration.zero : const Duration(milliseconds: 220);
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return Drawer(
      child: AnimatedSlide(
        offset: _drawerVisible
            ? Offset.zero
            : (isRtl ? const Offset(0.035, 0) : const Offset(-0.035, 0)),
        duration: drawerAnimationDuration,
        curve: Curves.easeOutBack,
        child: AnimatedOpacity(
          opacity: _drawerVisible ? 1 : 0.92,
          duration: drawerAnimationDuration,
          curve: Curves.easeOutCubic,
          child: drawerContent,
        ),
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = width < 360;
        final borderRadius = compact ? 18.0 : 22.0;
        final horizontalPadding = compact ? 14.0 : 18.0;
        final verticalPadding = compact ? 14.0 : 16.0;
        final iconSize = compact ? 22.0 : 24.0;
        final mobileWebInputFix = kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.android);

        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(borderRadius),
            boxShadow: [
              BoxShadow(
                color: const Color(0x14000000),
                blurRadius: compact ? 14 : 20,
                offset: Offset(0, compact ? 8 : 12),
              ),
            ],
          ),
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            onTapOutside: (_) => InputFocusGuard.dismiss(),
            scrollPadding: EdgeInsets.only(
              top: 20,
              bottom: mobileWebInputFix ? 132 : 92,
            ),
            style: TextStyle(
              color: AppTheme.text,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 14.5 : 15.5,
            ),
            decoration: InputDecoration(
              hintText: context.tr('common.search_restaurant_hint'),
              hintStyle: TextStyle(
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w600,
                fontSize: compact ? 14.0 : 15.0,
              ),
              prefixIcon: Icon(
                Icons.search_rounded,
                color: AppTheme.primaryDeep,
                size: iconSize,
              ),
              prefixIconConstraints: BoxConstraints(
                minWidth: compact ? 44 : 50,
                minHeight: compact ? 44 : 50,
              ),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
            ),
          ),
        );
      },
    );
  }
}
