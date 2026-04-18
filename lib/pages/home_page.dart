import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cart/cart_page.dart';
import '../cart/cart_provider.dart';
import '../core/localization/app_localizations.dart';
import '../core/localization/locale_controller.dart';
import '../core/location/location_helper.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/responsive.dart';
import '../pages/auth/widgets/profile_page.dart';
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
          );
    });
  }

  void _handleRestaurantInsert(PostgresChangePayload payload) {
    RestaurantsService.invalidateListCaches();
    _upsertRestaurantFromRealtimeRecord(
      payload.newRecord,
      insertAtTopIfMissing: true,
    );
  }

  void _handleRestaurantUpdate(PostgresChangePayload payload) {
    RestaurantsService.invalidateListCaches();
    _upsertRestaurantFromRealtimeRecord(payload.newRecord);
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
  }

  void _upsertRestaurantFromRealtimeRecord(
    Map<dynamic, dynamic> record, {
    bool insertAtTopIfMissing = false,
  }) {
    final normalized = RestaurantsService.normalizeRealtimeManagerRow(record);
    if (normalized == null) {
      return;
    }

    final restaurantId = RestaurantsService.restaurantIdOf(normalized);
    if (restaurantId.isEmpty) {
      return;
    }

    final withinRange = RestaurantsService.isWithinDeliveryRange(
      restaurant: normalized,
      customerLat: userLat,
      customerLng: userLng,
    );
    if (!withinRange) {
      _removeRestaurantRealtime(restaurantId);
      return;
    }

    _upsertRestaurantRealtime(
      normalized,
      insertAtTopIfMissing: insertAtTopIfMissing,
    );
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

  void _upsertRestaurantRealtime(
    Map<String, dynamic> restaurant, {
    bool insertAtTopIfMissing = false,
  }) {
    final currentShops = _state.shops;
    final restaurantId = RestaurantsService.restaurantIdOf(restaurant);
    if (restaurantId.isEmpty) {
      return;
    }

    final nextRestaurants = List<Map<String, dynamic>>.from(currentShops);
    final index = nextRestaurants.indexWhere(
      (item) => RestaurantsService.restaurantIdOf(item) == restaurantId,
    );

    if (index == -1) {
      if (insertAtTopIfMissing) {
        nextRestaurants.insert(0, restaurant);
      } else {
        nextRestaurants.add(restaurant);
      }
      _applyRestaurantsSnapshot(
        nextRestaurants,
        isLoading: false,
        hasLoadError: false,
      );
      return;
    }

    final current = nextRestaurants[index];
    if (identical(current, restaurant) || mapEquals(current, restaurant)) {
      return;
    }

    nextRestaurants[index] = restaurant;
    _applyRestaurantsSnapshot(
      nextRestaurants,
      isLoading: false,
      hasLoadError: false,
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

  Future<void> _openCart() async {
    final cart = CartProvider.read(context);
    final user = _client.auth.currentUser;

    if (user == null) {
      await Navigator.push(
        context,
        AppTheme.platformPageRoute(builder: (_) => const LoginPage()),
      );

      if (!mounted || _client.auth.currentUser == null) {
        return;
      }
    }

    if (!mounted) {
      return;
    }

    try {
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('home.cart_open_failed'))),
      );
    }
  }

  void _openRestaurantMenu(
    BuildContext context,
    Map<String, dynamic> restaurant,
  ) {
    final managerId = RestaurantsService.managerIdOf(restaurant);
    final restaurantId = RestaurantsService.restaurantIdOf(restaurant);
    final restaurantName = RestaurantsService.restaurantNameOf(restaurant);

    if (managerId.isEmpty || restaurantId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('home.restaurant_data_incomplete'))),
      );
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
                  onPressed: () {
                    Navigator.pop(context);
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
    final sideWidth = _HomeHeaderMetrics.sideWidthFor(width);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        toolbarHeight: _HomeHeaderMetrics.toolbarHeightFor(width),
        centerTitle: true,
        titleSpacing: 0,
        leadingWidth: sideWidth,
        leading: _HomeLeadingActions(onOpenCart: _openCart),
        title: const _HomeAppBarTitle(),
        actions: [
          _HomeMenuAction(width: sideWidth),
        ],
      ),
      drawer: _MainDrawer(client: _client),
      body: ValueListenableBuilder<_HomeUiState>(
        valueListenable: _uiState,
        builder: (context, state, _) {
          final locationDenied = state.locationDenied;
          return AppConstrainedContent(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('home.nearby_restaurants'),
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                _SearchBar(controller: _searchController),
                const SizedBox(height: 20),
                Expanded(
                  child: RestaurantsGridSection(
                    loading: state.loading,
                    hasError: state.hasError,
                    restaurants: state.shops,
                    searchQueryListenable: _searchQuery,
                    onRefresh: _refreshRestaurants,
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
                    onRestaurantTap: _openRestaurantMenu,
                  ),
                ),
              ],
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
  const _HomeAppBarTitle();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final iconSize = width >= 900 ? 24.0 : 21.0;
    final fontSize = width >= 900 ? 19.0 : 17.0;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.delivery_dining_rounded,
          color: AppTheme.primary,
          size: iconSize,
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            context.tr('app.name'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.text,
              fontWeight: FontWeight.w900,
              fontSize: fontSize,
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeHeaderMetrics {
  const _HomeHeaderMetrics._();

  static double sideWidthFor(double width) {
    if (width >= 1200) {
      return 198;
    }
    if (width >= 900) {
      return 178;
    }
    return 160;
  }

  static double toolbarHeightFor(double width) {
    if (width >= 900) {
      return 72;
    }
    return 64;
  }
}

class _HomeLeadingActions extends StatelessWidget {
  const _HomeLeadingActions({
    required this.onOpenCart,
  });

  final Future<void> Function() onOpenCart;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 8),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _HomeCartAction(onTap: onOpenCart),
              const SizedBox(width: 6),
              const _HomeLanguageToggleButton(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeMenuAction extends StatelessWidget {
  const _HomeMenuAction({
    required this.width,
  });

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Builder(
        builder: (context) => Tooltip(
          message: MaterialLocalizations.of(context).openAppDrawerTooltip,
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(end: 10),
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Scaffold.of(context).openDrawer(),
                  child: const SizedBox(
                    width: 38,
                    height: 38,
                    child: Icon(
                      Icons.menu_rounded,
                      size: 21,
                      color: AppTheme.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeCartAction extends StatelessWidget {
  const _HomeCartAction({
    required this.onTap,
  });

  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    final cart = CartProvider.of(context);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Tooltip(
          message: context.tr('cart.title'),
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => unawaited(onTap()),
              child: SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  Icons.shopping_cart_outlined,
                  size: 19,
                  color: AppTheme.text,
                ),
              ),
            ),
          ),
        ),
        if (cart.totalCount > 0)
          PositionedDirectional(
            top: -2,
            end: -2,
            child: Container(
              height: 17,
              constraints: const BoxConstraints(minWidth: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4.5),
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white,
                  width: 1.1,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                cart.totalCount.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9.5,
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
  const _HomeLanguageToggleButton();

  @override
  Widget build(BuildContext context) {
    final localeController = AppLocaleScope.of(context);
    final isArabic = localeController.isArabic;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LanguageSegment(
              label: context.tr('lang.current_ar'),
              selected: isArabic,
              onTap: () => unawaited(
                AppLocaleScope.read(context).setLocale(const Locale('ar')),
              ),
            ),
            _LanguageSegment(
              label: context.tr('lang.current_en'),
              selected: !isArabic,
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
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.primary : Colors.transparent;
    final textColor = selected ? Colors.white : AppTheme.textMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppTheme.microInteractionDuration,
          curve: AppTheme.emphasizedCurve,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w800,
              fontSize: 11,
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
    Navigator.pop(context);
    await Navigator.push(
      context,
      AppTheme.platformPageRoute(builder: (_) => const LoginPage()),
    );

    if (!mounted) return;
    await _loadCustomerProfile();
  }

  Future<void> _signOut() async {
    if (_signingOut || !mounted) {
      return;
    }

    setState(() => _signingOut = true);
    try {
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
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(context.tr('home.profile')),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  AppTheme.platformPageRoute(
                    builder: (_) => const ProfilePage(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long),
              title: Text(context.tr('home.orders')),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  AppTheme.platformPageRoute(
                    builder: (_) => const OrdersPage(),
                  ),
                );
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(
                Icons.logout,
                color: Colors.red,
              ),
              title: Text(
                context.tr('home.logout'),
                style: const TextStyle(color: Colors.red),
              ),
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

    return Drawer(
      child: AnimatedSlide(
        offset: _drawerVisible ? Offset.zero : const Offset(-0.035, 0),
        duration: drawerAnimationDuration,
        curve: Curves.easeOutCubic,
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: context.tr('common.search_restaurant_hint'),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: AppTheme.primaryDeep,
          ),
          border: InputBorder.none,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }
}
