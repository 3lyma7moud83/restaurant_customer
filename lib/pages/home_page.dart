import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/location/location_helper.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../pages/auth/widgets/profile_page.dart';
import '../services/profile_service.dart';
import '../services/restaurant_feed_utils.dart';
import '../services/restaurants_service.dart';
import '../services/session_manager.dart';
import '../widgets/restaurant_info_sheet.dart';
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

  void _openRestaurantMenu(
    BuildContext context,
    Map<String, dynamic> restaurant,
  ) {
    final managerId = RestaurantsService.managerIdOf(restaurant);
    final restaurantId = RestaurantsService.restaurantIdOf(restaurant);
    final restaurantName = RestaurantsService.restaurantNameOf(restaurant);

    if (managerId.isEmpty || restaurantId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('بيانات المطعم غير مكتملة حالياً.')),
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
              const Text(
                'نحتاج موقعك',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'علشان نعرض المطاعم القريبة منك',
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
                  child: const Text('تفعيل الموقع'),
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
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const _HomeAppBarTitle(),
      ),
      drawer: _MainDrawer(client: _client),
      body: ValueListenableBuilder<_HomeUiState>(
        valueListenable: _uiState,
        builder: (context, state, _) {
          final locationDenied = state.locationDenied;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مطاعم قريبة منك',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                _SearchBar(controller: _searchController),
                const SizedBox(height: 24),
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
    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.delivery_dining_rounded, color: AppTheme.primary),
        SizedBox(width: 6),
        Text(
          'Delivery',
          style: TextStyle(
            color: AppTheme.text,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
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
        ? 'الموقع غير مفعل حالياً. فعّل الموقع لعرض نتائج أدق.'
        : 'جرّب تغير المكان أو ترجع بعدين';

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
            const Text(
              'مفيش مطاعم قريبة دلوقتي',
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
                child: const Text('إعادة تفعيل الموقع'),
              ),
              const SizedBox(height: 8),
            ],
            if (onRetry != null)
              TextButton(
                onPressed: () => unawaited(onRetry!()),
                child: const Text('إعادة المحاولة'),
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
            const Text(
              'تعذر تحميل المطاعم',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'تحقق من الاتصال ثم أعد المحاولة.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF667085)),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => unawaited(onRetry()),
              child: const Text('إعادة المحاولة'),
            ),
            if (onRetryLocation != null) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => unawaited(onRetryLocation!()),
                child: const Text('تفعيل الموقع'),
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
        ? 'أهلاً بيك'
        : customerName.isNotEmpty
            ? customerName
            : (_profileLoading ? 'جار تحميل الحساب...' : 'حساب العميل');
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
                          child: Image.network(
                            profileImage,
                            width: avatarSize,
                            height: avatarSize,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.medium,
                            loadingBuilder: (context, child, progress) {
                              if (progress == null) {
                                return child;
                              }
                              return const Icon(
                                Icons.person,
                                color: AppTheme.primary,
                              );
                            },
                            errorBuilder: (_, __, ___) {
                              return const Icon(
                                Icons.person,
                                color: AppTheme.primary,
                              );
                            },
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
                  title: const Text('سجل الدخول لطلب اوردر'),
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
              title: const Text('الملف الشخصي'),
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
              title: const Text('طلباتي'),
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
              title: const Text(
                'تسجيل الخروج',
                style: TextStyle(color: Colors.red),
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
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: 'ابحث عن مطعم...',
        filled: true,
        fillColor: const Color(0xffFFF1E6),
        prefixIcon: const Icon(Icons.search),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
