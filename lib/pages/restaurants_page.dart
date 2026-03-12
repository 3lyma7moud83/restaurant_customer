import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/realtime/realtime_channel_controller.dart';
import '../core/location/location_helper.dart';
import '../services/restaurants_service.dart';
import '../widgets/restaurant_card_components.dart';
import '../widgets/restaurant_info_sheet.dart';
import 'restaurant_menu_page.dart';

class RestaurantsPage extends StatefulWidget {
  const RestaurantsPage({super.key});

  @override
  State<RestaurantsPage> createState() => _RestaurantsPageState();
}

class _RestaurantsPageState extends State<RestaurantsPage> {
  final _supabase = Supabase.instance.client;
  late final RealtimeChannelController _restaurantsChannelController;

  List<Map<String, dynamic>> restaurants = [];
  List<Map<String, dynamic>> filtered = [];

  bool loading = true;

  final TextEditingController _searchController = TextEditingController();
  Timer? _restaurantsRefreshDebounce;

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
    _load();
    _listenToRestaurants();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    _restaurantsRefreshDebounce?.cancel();
    unawaited(_restaurantsChannelController.dispose());
    super.dispose();
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
        unawaited(_load());
      },
    );
  }

  Future<void> _load({bool showLoader = false}) async {
    if (mounted) {
      if (showLoader) {
        setState(() => loading = true);
      }
    }

    try {
      final location = await LocationHelper.requestAndGetLocation();
      final fetchedRestaurants = location == null
          ? await RestaurantsService.getAllActive()
          : await RestaurantsService.getNearby(
              latitude: location.lat,
              longitude: location.lng,
            );

      if (!mounted) return;
      _applyRestaurantsSnapshot(fetchedRestaurants, isLoading: false);
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
    final nextFiltered = _filterRestaurants(merged, _searchController.text);
    final listChanged = !_sameIdentityList(restaurants, merged);
    final filteredChanged = !_sameIdentityList(filtered, nextFiltered);

    if (!listChanged && !filteredChanged && loading == isLoading) {
      return;
    }

    setState(() {
      restaurants = merged;
      filtered = nextFiltered;
      loading = isLoading;
    });
  }

  List<Map<String, dynamic>> _reuseRestaurantMaps(
    List<Map<String, dynamic>> nextRestaurants,
  ) {
    final currentById = {
      for (final restaurant in restaurants)
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
    final nextFiltered = _filterRestaurants(restaurants, text);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: loading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Colors.orange,
                ),
              )
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'كل المطاعم',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _RestaurantsSearchField(controller: _searchController),
                    const SizedBox(height: 16),
                    Expanded(
                      child: filtered.isEmpty
                          ? const _RestaurantsEmptyState()
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final count =
                                    _calcGridCount(constraints.maxWidth);
                                final aspectRatio =
                                    _calcCardAspectRatio(constraints.maxWidth);

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
                                    final restaurant = filtered[i];
                                    final managerId =
                                        RestaurantsService.managerIdOf(
                                      restaurant,
                                    );
                                    final restaurantId =
                                        RestaurantsService.restaurantIdOf(
                                      restaurant,
                                    );
                                    final restaurantName =
                                        RestaurantsService.restaurantNameOf(
                                      restaurant,
                                    );

                                    return RestaurantListCard(
                                      name: RestaurantsService.cardNameOf(
                                        restaurant,
                                      ),
                                      imageUrl: RestaurantsService.cardImageOf(
                                        restaurant,
                                      ),
                                      onInfoTap: () => showRestaurantInfoSheet(
                                        context,
                                        restaurant: restaurant,
                                      ),
                                      onTap: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) => RestaurantMenuPage(
                                              managerId: managerId,
                                              restaurantId: restaurantId,
                                              restaurantName: restaurantName,
                                            ),
                                          ),
                                        );
                                      },
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

class _RestaurantsSearchField extends StatelessWidget {
  const _RestaurantsSearchField({
    required this.controller,
  });

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        hintText: 'ابحث عن مطعم...',
        prefixIcon: const Icon(Icons.search),
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(
          color: Color(0xFF98A2B3),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RestaurantsEmptyState extends StatelessWidget {
  const _RestaurantsEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(
            Icons.storefront_outlined,
            size: 58,
            color: Color(0xFF98A2B3),
          ),
          SizedBox(height: 12),
          Text(
            'لا توجد مطاعم حالياً',
            style: TextStyle(
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 6),
          Text(
            'جرّب تغيير البحث أو إعادة المحاولة لاحقاً.',
            style: TextStyle(color: Color(0xFF667085)),
          ),
        ],
      ),
    );
  }
}
