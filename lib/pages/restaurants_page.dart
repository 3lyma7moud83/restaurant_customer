import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/localization/app_localizations.dart';
import '../core/location/location_helper.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/responsive.dart';
import '../services/restaurant_feed_utils.dart';
import '../services/restaurants_service.dart';
import '../widgets/restaurant_info_sheet.dart';
import '../widgets/restaurants_grid_section.dart';
import 'restaurant_menu_page.dart';

class RestaurantsPage extends StatefulWidget {
  const RestaurantsPage({super.key});

  @override
  State<RestaurantsPage> createState() => _RestaurantsPageState();
}

class _RestaurantsPageState extends State<RestaurantsPage> {
  final _supabase = Supabase.instance.client;
  late final RealtimeChannelController _restaurantsChannelController;
  late final ValueNotifier<_RestaurantsUiState> _uiState =
      ValueNotifier<_RestaurantsUiState>(const _RestaurantsUiState.initial());
  double? _userLat;
  double? _userLng;

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _searchQuery = ValueNotifier<String>('');
  Timer? _restaurantsRefreshDebounce;
  int _loadRequestId = 0;

  _RestaurantsUiState get _state => _uiState.value;

  @override
  void initState() {
    super.initState();
    _restaurantsChannelController = RealtimeChannelController(
      client: _supabase,
      topicPrefix: 'restaurants-page-${identityHashCode(this)}',
      onSubscribed: (didReconnect) async {
        if (didReconnect) {
          _scheduleRestaurantsRefresh();
        }
      },
    );
    _load(showLoader: true);
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
      customerLat: _userLat,
      customerLng: _userLng,
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
        unawaited(_load(forceRefresh: true));
      },
    );
  }

  Future<void> _load({
    bool showLoader = false,
    bool forceRefresh = false,
  }) async {
    final requestId = ++_loadRequestId;
    if (showLoader && mounted) {
      _updateUiState(
        _state.copyWith(
          loading: true,
          hasError: false,
        ),
      );
    }

    try {
      final location = await LocationHelper.requestAndGetLocation();
      final userLat = location?.lat;
      final userLng = location?.lng;

      final fetchedRestaurants = location == null
          ? await RestaurantsService.getAllActive(forceRefresh: forceRefresh)
          : await RestaurantsService.getNearby(
              latitude: location.lat,
              longitude: location.lng,
              forceRefresh: forceRefresh,
            );

      if (!mounted || requestId != _loadRequestId) {
        return;
      }

      _userLat = userLat;
      _userLng = userLng;

      final ranged = RestaurantFeedUtils.filterByRange(
        source: fetchedRestaurants,
        customerLat: _userLat,
        customerLng: _userLng,
      );
      _applyRestaurantsSnapshot(
        ranged,
        isLoading: false,
        hasLoadError: false,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurants_page.load',
        error: error,
        stack: stack,
      );

      if (!mounted || requestId != _loadRequestId) {
        return;
      }

      _applyRestaurantsSnapshot(
        _state.restaurants,
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
    final currentRestaurants = currentState.restaurants;
    final merged = RestaurantFeedUtils.reuseRestaurantMaps(
      currentRestaurants,
      nextRestaurants,
    );
    final listChanged =
        !RestaurantFeedUtils.sameIdentityList(currentRestaurants, merged);

    if (!listChanged &&
        currentState.loading == isLoading &&
        currentState.hasError == hasLoadError) {
      return;
    }

    _updateUiState(
      currentState.copyWith(
        restaurants: merged,
        loading: isLoading,
        hasError: hasLoadError,
      ),
    );
  }

  void _upsertRestaurantRealtime(
    Map<String, dynamic> restaurant, {
    bool insertAtTopIfMissing = false,
  }) {
    final currentRestaurants = _state.restaurants;
    final restaurantId = RestaurantsService.restaurantIdOf(restaurant);
    if (restaurantId.isEmpty) {
      return;
    }

    final nextRestaurants = List<Map<String, dynamic>>.from(
      currentRestaurants,
    );
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
    final currentRestaurants = _state.restaurants;
    final nextRestaurants = currentRestaurants
        .where(
            (item) => RestaurantsService.restaurantIdOf(item) != restaurantId)
        .toList(growable: false);

    if (nextRestaurants.length == currentRestaurants.length) {
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
    return _load(forceRefresh: true);
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

  void _updateUiState(_RestaurantsUiState nextState) {
    final current = _uiState.value;
    if (identical(current, nextState) ||
        (current.loading == nextState.loading &&
            current.hasError == nextState.hasError &&
            RestaurantFeedUtils.sameIdentityList(
              current.restaurants,
              nextState.restaurants,
            ))) {
      return;
    }
    _uiState.value = nextState;
  }

  @override
  Widget build(BuildContext context) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final titleFontSize = viewportWidth < 360
        ? 22.0
        : viewportWidth < 900
            ? 26.0
            : 28.0;
    final searchGap = viewportWidth < 360 ? 14.0 : 16.0;
    final listGap = viewportWidth < 360 ? 16.0 : 18.0;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: AppConstrainedContent(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('restaurants.all'),
                  style: TextStyle(
                    fontSize: titleFontSize,
                    fontWeight: FontWeight.w900,
                    height: 1.12,
                  ),
                ),
                SizedBox(height: searchGap),
                _RestaurantsSearchField(controller: _searchController),
                SizedBox(height: listGap),
                Expanded(
                  child: ValueListenableBuilder<_RestaurantsUiState>(
                    valueListenable: _uiState,
                    builder: (context, state, _) {
                      return RestaurantsGridSection(
                        loading: state.loading,
                        hasError: state.hasError,
                        restaurants: state.restaurants,
                        searchQueryListenable: _searchQuery,
                        onRefresh: _refreshRestaurants,
                        customerLat: _userLat,
                        customerLng: _userLng,
                        loadingSkeletonKey: 'restaurants-loading',
                        errorKey: 'restaurants-error',
                        emptyKey: 'restaurants-empty',
                        gridKey: 'restaurants-grid',
                        emptyStateBuilder: (_) => _RestaurantsEmptyState(
                          onRetry: _refreshRestaurants,
                        ),
                        errorStateBuilder: (_) => _RestaurantsErrorState(
                          onRetry: _refreshRestaurants,
                        ),
                        onRestaurantInfoTap: (context, restaurant) {
                          showRestaurantInfoSheet(
                            context,
                            restaurant: restaurant,
                          );
                        },
                        onRestaurantTap: _openRestaurantMenu,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RestaurantsUiState {
  const _RestaurantsUiState({
    required this.loading,
    required this.hasError,
    required this.restaurants,
  });

  const _RestaurantsUiState.initial()
      : loading = true,
        hasError = false,
        restaurants = const [];

  final bool loading;
  final bool hasError;
  final List<Map<String, dynamic>> restaurants;

  _RestaurantsUiState copyWith({
    bool? loading,
    bool? hasError,
    List<Map<String, dynamic>>? restaurants,
  }) {
    return _RestaurantsUiState(
      loading: loading ?? this.loading,
      hasError: hasError ?? this.hasError,
      restaurants: restaurants ?? this.restaurants,
    );
  }
}

class _RestaurantsSearchField extends StatelessWidget {
  const _RestaurantsSearchField({
    required this.controller,
  });

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
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
          onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
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
    });
  }
}

class _RestaurantsEmptyState extends StatelessWidget {
  const _RestaurantsEmptyState({
    this.onRetry,
  });

  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.storefront_outlined,
            size: 58,
            color: Color(0xFF98A2B3),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('restaurants.empty_title'),
            style: TextStyle(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('restaurants.empty_subtitle'),
            style: TextStyle(color: Color(0xFF667085)),
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => unawaited(onRetry!()),
              child: Text(context.tr('restaurants.refresh')),
            ),
          ],
        ],
      ),
    );
  }
}

class _RestaurantsErrorState extends StatelessWidget {
  const _RestaurantsErrorState({
    required this.onRetry,
  });

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            size: 62,
            color: Color(0xFF98A2B3),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('restaurants.error_title'),
            style: TextStyle(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            context.tr('restaurants.error_subtitle'),
            style: TextStyle(color: Color(0xFF667085)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => unawaited(onRetry()),
            child: Text(context.tr('common.retry')),
          ),
        ],
      ),
    );
  }
}
