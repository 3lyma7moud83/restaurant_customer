import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/realtime/realtime_channel_controller.dart';
import '../pages/auth/widgets/profile_page.dart';
import '../services/profile_service.dart';
import '../services/restaurants_service.dart';
import '../services/session_manager.dart';
import '../widgets/restaurant_card_components.dart';
import '../widgets/restaurant_info_sheet.dart';
import 'auth/login_page.dart';
import 'restaurant_menu_page.dart';
import '../core/location/location_helper.dart';
import 'orders_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  final SupabaseClient _client = Supabase.instance.client;
  late final RealtimeChannelController _restaurantsChannelController;

  bool loading = true;
  bool locationDenied = false;

  List<Map<String, dynamic>> shops = [];
  List<Map<String, dynamic>> filtered = [];

  final TextEditingController _searchController = TextEditingController();

  double? userLat;
  double? userLng;

  late AnimationController _anim;
  late Animation<double> _fade;
  Timer? _restaurantsRefreshDebounce;

  @override
  void initState() {
    super.initState();

    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _fade = CurvedAnimation(parent: _anim, curve: Curves.easeOut);

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
    _restaurantsRefreshDebounce?.cancel();
    _anim.dispose();
    unawaited(_restaurantsChannelController.dispose());
    super.dispose();
  }

  Future<void> _init() async {
    await _getUserLocationIfNeeded();

    if (locationDenied && mounted) {
      await _showLocationSheet();
    }

    await _loadRestaurants(showLoader: true);
    if (mounted) _anim.forward();
  }

  Future<void> _getUserLocationIfNeeded() async {
    try {
      final location = await LocationHelper.requestAndGetLocation();
      if (location == null) {
        setState(() {
          locationDenied = true;
          loading = false;
        });
        return;
      }

      userLat = location.lat;
      userLng = location.lng;
    } catch (_) {
      setState(() {
        locationDenied = true;
        loading = false;
      });
    }
  }

  Future<void> _retryLocation() async {
    setState(() {
      loading = true;
      locationDenied = false;
    });

    userLat = null;
    userLng = null;

    await _getUserLocationIfNeeded();
    await _loadRestaurants(showLoader: true);

    if (mounted) _anim.forward();
  }

  void _listenToRestaurants() {
    _restaurantsChannelController.subscribe((client, channelName) {
      return client.channel(channelName).onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'managers',
            callback: (_) => _scheduleRestaurantsRefresh(),
          );
    });
  }

  void _scheduleRestaurantsRefresh() {
    _restaurantsRefreshDebounce?.cancel();
    _restaurantsRefreshDebounce = Timer(
      const Duration(milliseconds: 300),
      () {
        if (!mounted) {
          return;
        }
        unawaited(_loadRestaurants());
      },
    );
  }

  Future<void> _loadRestaurants({bool showLoader = false}) async {
    if (showLoader && mounted) {
      setState(() => loading = true);
    }

    try {
      final restaurants = userLat == null || userLng == null
          ? await RestaurantsService.getAllActive()
          : await RestaurantsService.getNearby(
              latitude: userLat!,
              longitude: userLng!,
            );

      if (!mounted) return;
      _applyRestaurantsSnapshot(restaurants, isLoading: false);
    } catch (_) {
      if (!mounted) return;
      _applyRestaurantsSnapshot(const [], isLoading: false);
    }
  }

  void _applyRestaurantsSnapshot(
    List<Map<String, dynamic>> nextRestaurants, {
    required bool isLoading,
  }) {
    final merged = _reuseRestaurantMaps(nextRestaurants);
    final filteredNext = _filterRestaurants(merged, _searchController.text);
    final listChanged = !_sameIdentityList(shops, merged);
    final filteredChanged = !_sameIdentityList(filtered, filteredNext);

    if (!listChanged && !filteredChanged && loading == isLoading) {
      return;
    }

    setState(() {
      shops = merged;
      filtered = filteredNext;
      loading = isLoading;
    });
  }

  List<Map<String, dynamic>> _reuseRestaurantMaps(
    List<Map<String, dynamic>> nextRestaurants,
  ) {
    final currentById = {
      for (final restaurant in shops)
        RestaurantsService.restaurantIdOf(restaurant): restaurant,
    };

    return nextRestaurants.map((restaurant) {
      final current =
          currentById[RestaurantsService.restaurantIdOf(restaurant)];
      if (current != null && mapEquals(current, restaurant)) {
        return current;
      }
      return restaurant;
    }).toList(growable: false);
  }

  bool _sameIdentityList(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> next,
  ) {
    if (current.length != next.length) {
      return false;
    }

    for (var i = 0; i < current.length; i++) {
      if (!identical(current[i], next[i])) {
        return false;
      }
    }

    return true;
  }

  void _handleSearchChanged() {
    _applySearch(_searchController.text);
  }

  List<Map<String, dynamic>> _filterRestaurants(
    List<Map<String, dynamic>> source,
    String text,
  ) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) {
      return List<Map<String, dynamic>>.from(source);
    }

    return source
        .where((restaurant) =>
            RestaurantsService.cardNameOf(restaurant).toLowerCase().contains(q))
        .toList(growable: false);
  }

  void _applySearch(String text) {
    final nextFiltered = _filterRestaurants(shops, text);
    if (_sameIdentityList(filtered, nextFiltered)) {
      return;
    }
    setState(() => filtered = nextFiltered);
  }

  int _calcGridCount(double width) {
    if (width >= 1200) return 5;
    if (width >= 900) return 4;
    if (width >= 600) return 3;
    return 2;
  }

  double _calcCardAspectRatio(double width) {
    if (width >= 1200) return 1.02;
    if (width >= 900) return 0.98;
    if (width >= 600) return 0.94;
    return 0.9;
  }

  Future<void> _showLocationSheet() async {
    await showModalBottomSheet(
      context: context,
      isDismissible: false,
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
                    _retryLocation();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
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
        ),
      ),
      drawer: _MainDrawer(
        client: _client,
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : FadeTransition(
              opacity: _fade,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'مطاعم قريبة منك',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    _SearchBar(controller: _searchController),
                    const SizedBox(height: 24),
                    Expanded(
                      child: filtered.isEmpty
                          ? const _EmptyState()
                          : LayoutBuilder(
                              builder: (_, c) {
                                final count = _calcGridCount(c.maxWidth);
                                final aspectRatio =
                                    _calcCardAspectRatio(c.maxWidth);

                                return GridView.builder(
                                  cacheExtent: 720,
                                  itemCount: filtered.length,
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: count,
                                    mainAxisSpacing: 14,
                                    crossAxisSpacing: 14,
                                    childAspectRatio: aspectRatio,
                                  ),
                                  itemBuilder: (_, i) {
                                    final r = filtered[i];
                                    return TweenAnimationBuilder<double>(
                                      tween: Tween(begin: 0, end: 1),
                                      duration:
                                          Duration(milliseconds: 300 + i * 80),
                                      curve: Curves.easeOut,
                                      builder: (_, v, child) => Opacity(
                                        opacity: v,
                                        child: Transform.translate(
                                          offset: Offset(0, (1 - v) * 30),
                                          child: child,
                                        ),
                                      ),
                                      child: RestaurantListCard(
                                        name: RestaurantsService.cardNameOf(r),
                                        imageUrl:
                                            RestaurantsService.cardImageOf(r),
                                        onInfoTap: () =>
                                            showRestaurantInfoSheet(
                                          context,
                                          restaurant: r,
                                        ),
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  RestaurantMenuPage(
                                                managerId: RestaurantsService
                                                    .managerIdOf(r),
                                                restaurantId: RestaurantsService
                                                    .restaurantIdOf(r),
                                                restaurantName:
                                                    RestaurantsService
                                                        .restaurantNameOf(
                                                  r,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/* ================= EMPTY ================= */

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.store_mall_directory_outlined,
              size: 80, color: Colors.orange),
          SizedBox(height: 12),
          Text(
            'مفيش مطاعم قريبة دلوقتي',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 6),
          Text(
            'جرّب تغير المكان أو ترجع بعدين',
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

/* ================= DRAWER ================= */

class _MainDrawer extends StatefulWidget {
  final SupabaseClient client;
  const _MainDrawer({required this.client});

  @override
  State<_MainDrawer> createState() => _MainDrawerState();
}

class _MainDrawerState extends State<_MainDrawer>
    with SingleTickerProviderStateMixin {
  final ProfileService _profileService = ProfileService();
  Map<String, dynamic>? customerProfile;
  late final AnimationController _drawerAnimationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _drawerAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _fadeAnimation = Tween<double>(
      begin: 0.92,
      end: 1,
    ).animate(
      CurvedAnimation(
        parent: _drawerAnimationController,
        curve: Curves.easeOutCubic,
      ),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-0.035, 0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _drawerAnimationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _loadCustomerProfile();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        playEntranceAnimation();
      }
    });
  }

  @override
  void dispose() {
    _drawerAnimationController.dispose();
    super.dispose();
  }

  void playEntranceAnimation() {
    if (!mounted) return;

    _drawerAnimationController
      ..stop()
      ..value = 0
      ..forward();
  }

  Future<void> _loadCustomerProfile() async {
    try {
      final res = await _profileService.getOrCreateProfile();
      if (!mounted) {
        return;
      }
      setState(() => customerProfile = res);
    } catch (_) {}
  }

  Future<void> _openLoginPage() async {
    Navigator.pop(context);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );

    if (!mounted) return;
    await _loadCustomerProfile();
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
                  radius: 28,
                  backgroundColor: Colors.white,
                  backgroundImage: !isGuest && hasProfileImage
                      ? NetworkImage(profileImage)
                      : null,
                  child: !isGuest && !hasProfileImage
                      ? const Icon(Icons.person, color: AppTheme.primary)
                      : isGuest
                          ? const Icon(Icons.login, color: AppTheme.primary)
                          : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isGuest
                            ? 'أهلاً بيك'
                            : (customerName.isEmpty
                                ? 'حساب العميل'
                                : customerName),
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
                  MaterialPageRoute(
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
                  MaterialPageRoute(
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
              onTap: () async {
                try {
                  await widget.client.auth.signOut();
                } catch (error, stack) {
                  await ErrorLogger.logError(
                    module: 'home_page.signOut',
                    error: error,
                    stack: stack,
                  );
                  await SessionManager.instance.redirectToLogin();
                }
              },
            ),
          ],
        ],
      ),
    );

    return Drawer(
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: drawerContent,
        ),
      ),
    );
  }
}

/* ================= SEARCH ================= */

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  const _SearchBar({required this.controller});

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
