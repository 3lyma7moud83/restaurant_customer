import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class RestaurantsService {
  RestaurantsService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static final Map<String, _RestaurantCacheEntry> _restaurantCache = {};
  static const Duration _listCacheTtl = Duration(minutes: 2);
  static const Duration _restaurantCacheTtl = Duration(minutes: 10);
  static List<Map<String, dynamic>>? _allActiveCache;
  static DateTime? _allActiveCacheAt;
  static final Map<String, _RestaurantListCacheEntry> _nearbyCache = {};

  static const int _orderScope = 2;
  static const int _detailsScope = 3;

  static void invalidateListCaches() {
    _allActiveCache = null;
    _allActiveCacheAt = null;
    _nearbyCache.clear();
  }

  static void invalidateRestaurantCacheById(String identifier) {
    final id = identifier.trim();
    if (id.isEmpty) {
      return;
    }
    _restaurantCache.remove(id);
  }

  static const String _listSelect = '''
      
      user_id,
      restaurant_id,
      name,
      image_url,
  address,
  lat,
  lng,
  service_radius_meters,
  open_time,
  close_time
    ''';

  static const String _nearbySelect = '''
      
      user_id,
      restaurant_id,
      name,
      image_url,
      lat,
      lng,
      service_radius_meters

    ''';

  static const String _orderInfoSelect = '''
      
      user_id,
      restaurant_id,
      name,
      image_url,
      phone,
      address,
      full_address,
      location_address,
      street_address,
      lat,
      lng,
      service_radius_meters,
      street,
      district,
      city,
      area,
      governorate
    ''';
  static const String _detailsSelect = '''
      user_id,
      restaurant_id,
      name,
      image_url,
      phone,
      address,
      lat,
      lng,
      service_radius_meters,
      open_time,
      close_time
    ''';

  /* ===================== ALL ===================== */

  static Future<List<Map<String, dynamic>>> getAllActive({
    bool forceRefresh = false,
  }) async {
    try {
      final hasValidAllActiveCache = !forceRefresh &&
          _allActiveCache != null &&
          _allActiveCacheAt != null &&
          DateTime.now().difference(_allActiveCacheAt!) <= _listCacheTtl;
      if (hasValidAllActiveCache) {
        return _allActiveCache!;
      }

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client.from('managers').select(_listSelect),
      );

      if (res == null) return [];

      final restaurants = res
          .whereType<Map>()
          .map((row) =>
              _normalizeManagerRestaurant(Map<String, dynamic>.from(row)))
          .toList(growable: false);
      _allActiveCache = restaurants;
      _allActiveCacheAt = DateTime.now();
      return restaurants;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurants_service.getAllActive',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  /* ===================== NEARBY ===================== */

  static Future<List<Map<String, dynamic>>> getNearby({
    required double latitude,
    required double longitude,
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = _nearbyCacheKey(
        latitude: latitude,
        longitude: longitude,
      );
      final cachedNearby = forceRefresh ? null : _nearbyCache[cacheKey];
      if (cachedNearby != null && !cachedNearby.isExpired) {
        return cachedNearby.value;
      }

      final rpcRows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client.rpc(
          'get_nearby_restaurants',
          params: {
            'user_lat': latitude,
            'user_lng': longitude,
          },
        ),
      );

      if (rpcRows == null) {
        return const [];
      }

      final snapshots = rpcRows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final requestedIds = snapshots
          .map(
            (row) =>
                _stringValue(row['restaurant_id']) ??
                _stringValue(row['manager_id']) ??
                '',
          )
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      final restaurantMap = await _loadRestaurantsByIdentifiers(
        requestedIds,
        select: _nearbySelect,
        requiredScope: _orderScope,
      );

      final nearbyRestaurants = snapshots.map((row) {
        final identifier = _stringValue(row['restaurant_id']) ??
            _stringValue(row['manager_id']) ??
            '';
        final managerRestaurant =
            identifier.isEmpty ? null : restaurantMap[identifier];
        final merged = _mergeRestaurantData(
          restaurantId: identifier,
          primary: managerRestaurant,
          fallback: {
            'id': identifier,
            'restaurant_id': identifier,
            'manager_id': _stringValue(row['manager_id']) ?? '',
            'lat': row['lat'],
            'lng': row['lng'],
            'service_radius_meters': row['service_radius_meters'],
          },
        );
        _cacheRestaurant(merged, _orderScope);
        return merged;
      }).toList(growable: false);
      _nearbyCache[cacheKey] = _RestaurantListCacheEntry(
        value: nearbyRestaurants,
        cachedAt: DateTime.now(),
      );
      return nearbyRestaurants;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurants_service.getNearby',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  /* ===================== CURRENT ===================== */

  static Future<Map<String, dynamic>?> getCurrentManagerRestaurant() async {
    final session = await SessionManager.instance.ensureValidSession();
    final user = session?.user;

    if (user == null) return null;

    final data = await SessionManager.instance
        .runWithValidSession<Map<String, dynamic>?>(() async {
      final row = await _client
          .from('managers')
          .select(_detailsSelect)
          .eq('user_id', user.id)
          .maybeSingle();

      if (row == null) return null;

      final restaurant =
          _normalizeManagerRestaurant(Map<String, dynamic>.from(row));
      _cacheRestaurant(restaurant, _detailsScope);
      return restaurant;
    }, requireSession: true);

    return data;
  }

  /* ===================== HELPERS ===================== */

  static String managerIdOf(Map<String, dynamic> restaurant) {
    return _stringValue(restaurant['manager_id']) ??
        _stringValue(restaurant['user_id']) ??
        _stringValue(restaurant['id']) ??
        '';
  }

  static String restaurantIdOf(Map<String, dynamic> restaurant) {
    return _stringValue(restaurant['restaurant_id']) ??
        _stringValue(restaurant['id']) ??
        _stringValue(restaurant['manager_id']) ??
        '';
  }

  static String restaurantNameOf(Map<String, dynamic> restaurant) {
    return _stringValue(restaurant['name']) ??
        _stringValue(restaurant['restaurant_name']) ??
        'مطعم';
  }

  static String? restaurantImageOf(Map<String, dynamic> restaurant) {
    return _stringValue(restaurant['image_url']) ??
        _stringValue(restaurant['restaurant_image_url']);
  }

  static String? restaurantPhoneOf(Map<String, dynamic> restaurant) {
    return _stringValue(restaurant['phone']) ??
        _stringValue(restaurant['restaurant_phone']);
  }

  static String cardNameOf(Map<String, dynamic> restaurant) {
    return restaurantNameOf(restaurant);
  }

  static String? cardImageOf(Map<String, dynamic> restaurant) {
    return restaurantImageOf(restaurant);
  }

  static double cardRatingOf(Map<String, dynamic> restaurant) {
    final rating = _toDouble(restaurant['rating']) ??
        _toDouble(restaurant['avg_rating']) ??
        _toDouble(restaurant['stars']) ??
        _toDouble(restaurant['review_score']);
    final normalized = rating == null ? 4.5 : rating.clamp(0, 5).toDouble();
    return normalized;
  }

  static int cardDeliveryMinutesOf(Map<String, dynamic> restaurant) {
    final minutes = (_toDouble(restaurant['delivery_time_min']) ??
            _toDouble(restaurant['delivery_minutes']) ??
            _toDouble(restaurant['eta_minutes']) ??
            _toDouble(restaurant['eta_min']) ??
            _toDouble(restaurant['prep_time_minutes']))
        ?.round();
    final normalized = minutes ?? 30;
    return normalized.clamp(10, 180);
  }

  static double cardDeliveryFeeOf(Map<String, dynamic> restaurant) {
    final fee = _toDouble(restaurant['delivery_fee']) ??
        _toDouble(restaurant['delivery_cost']) ??
        _toDouble(restaurant['fee']);
    if (fee == null || !fee.isFinite || fee < 0) {
      return 0;
    }
    return fee;
  }

  static String restaurantAddressOf(Map<String, dynamic> restaurant) {
    return _stringValue(restaurant['address']) ??
        _stringValue(restaurant['full_address']) ??
        _stringValue(restaurant['location_address']) ??
        _stringValue(restaurant['street_address']) ??
        _stringValue(restaurant['delivery_address']) ??
        _composeAddressFromParts(restaurant) ??
        'العنوان غير متوفر';
  }

  static double? restaurantLatOf(Map<String, dynamic> restaurant) {
    return _toDouble(restaurant['lat']) ??
        _toDouble(restaurant['latitude']) ??
        _toDouble(restaurant['restaurant_lat']);
  }

  static double? restaurantLngOf(Map<String, dynamic> restaurant) {
    return _toDouble(restaurant['lng']) ??
        _toDouble(restaurant['longitude']) ??
        _toDouble(restaurant['restaurant_lng']);
  }

  static double? serviceRadiusMetersOf(Map<String, dynamic> restaurant) {
    return _toDouble(restaurant['service_radius_meters']) ??
        _toDouble(restaurant['service_radius']) ??
        _toDouble(restaurant['radius_meters']);
  }

  static Map<String, dynamic>? normalizeRealtimeManagerRow(
    Map<dynamic, dynamic> row,
  ) {
    final normalized =
        _normalizeManagerRestaurant(Map<String, dynamic>.from(row));
    final restaurantId = restaurantIdOf(normalized);
    if (restaurantId.isEmpty) {
      return null;
    }
    _cacheRestaurant(normalized, _orderScope);
    return normalized;
  }

  static bool isWithinDeliveryRange({
    required Map<String, dynamic> restaurant,
    required double? customerLat,
    required double? customerLng,
  }) {
    if (customerLat == null || customerLng == null) {
      return true;
    }
    final lat = restaurantLatOf(restaurant);
    final lng = restaurantLngOf(restaurant);
    final radius = serviceRadiusMetersOf(restaurant);

    if (lat == null || lng == null || radius == null || radius <= 0) {
      return true;
    }

    final distance = haversineDistanceMeters(
      fromLat: customerLat,
      fromLng: customerLng,
      toLat: lat,
      toLng: lng,
    );
    return distance <= radius;
  }

  static double haversineDistanceMeters({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) {
    const earthRadius = 6371000.0;
    final dLat = _degToRad(toLat - fromLat);
    final dLng = _degToRad(toLng - fromLng);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(fromLat)) *
            math.cos(_degToRad(toLat)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return earthRadius * c;
  }

  static String openingTimeOf(Map<String, dynamic> restaurant) {
    return _formatTimeValue(
          restaurant['opening_time'] ??
              restaurant['open_time'] ??
              restaurant['opens_at'] ??
              restaurant['start_time'],
        ) ??
        'غير محدد';
  }

  static String closingTimeOf(Map<String, dynamic> restaurant) {
    return _formatTimeValue(
          restaurant['closing_time'] ??
              restaurant['close_time'] ??
              restaurant['closes_at'] ??
              restaurant['end_time'],
        ) ??
        'غير محدد';
  }

  static Future<Map<String, dynamic>> getRestaurantDetails(
    String restaurantId, {
    Map<String, dynamic>? fallbackData,
    bool forceRefresh = false,
  }) async {
    try {
      final fallback = fallbackData == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(fallbackData);

      if (!forceRefresh) {
        final cached = _cachedRestaurant(restaurantId, _detailsScope);
        if (cached != null) {
          return _mergeRestaurantData(
            restaurantId: restaurantId,
            primary: cached,
            fallback: fallback,
          );
        }
      }

      final loadedRestaurants = await _loadRestaurantsByIdentifiers(
        [restaurantId],
        select: _detailsSelect,
        requiredScope: _detailsScope,
        forceRefresh: forceRefresh,
      );
      final restaurantRow = loadedRestaurants[restaurantId];

      final merged = _mergeRestaurantData(
        restaurantId: restaurantId,
        primary: restaurantRow,
        fallback: fallback,
      );
      _cacheRestaurant(merged, _detailsScope);
      return merged;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurants_service.getRestaurantDetails',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<Map<String, Map<String, dynamic>>> getOrderRestaurantsByIds(
    Iterable<String> restaurantIds,
  ) {
    return _loadRestaurantsByIdentifiers(
      restaurantIds,
      select: _orderInfoSelect,
      requiredScope: _orderScope,
    );
  }

  static Future<void> submitComplaint({
    required String restaurantId,
    required String customerId,
    required String message,
  }) async {
    try {
      await SessionManager.instance.runWithValidSession<void>(
        () async {
          await _client.from('restaurant_complaints').insert({
            'restaurant_id': restaurantId,
            'customer_id': customerId,
            'message': message.trim(),
            'status': 'pending',
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
        },
        requireSession: true,
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurants_service.submitComplaint',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  /* ===================== MAP ===================== */
  static Map<String, dynamic> _normalizeManagerRestaurant(
    Map<String, dynamic> row,
  ) {
    final managerId = _stringValue(row['user_id']) ??
        _stringValue(row['manager_id']) ??
        _stringValue(row['id']) ??
        '';
    final restaurantId = _stringValue(row['restaurant_id']) ?? managerId;

    final normalized = <String, dynamic>{
      ...row,

      // ids
      'id': restaurantId,
      'restaurant_id': restaurantId,
      'manager_id': managerId,
      'user_id': managerId,

      // basic info
      'name': _stringValue(row['name']) ?? 'مطعم',
      'image_url': _stringValue(row['image_url']),
      'phone': restaurantPhoneOf(row),

      // address
      'address': _stringValue(row['address']),
      'full_address': _stringValue(row['full_address']),
      'location_address': _stringValue(row['location_address']),
      'street_address': _stringValue(row['street_address']),
      'street': _stringValue(row['street']),
      'district': _stringValue(row['district']),
      'city': _stringValue(row['city']),
      'area': _stringValue(row['area']),
      'governorate': _stringValue(row['governorate']),

      // location
      'lat': _toDouble(row['lat']),
      'lng': _toDouble(row['lng']),
      'service_radius_meters': _toDouble(row['service_radius_meters']),

      // times
      'open_time': _stringValue(row['open_time']),
      'close_time': _stringValue(row['close_time']),

      // UI card metadata (optional from backend, with runtime defaults)
      'rating': cardRatingOf(row),
      'delivery_time_min': cardDeliveryMinutesOf(row),
      'delivery_fee': cardDeliveryFeeOf(row),
    };

    return normalized;
  }

  static Map<String, dynamic> _mergeRestaurantData({
    required String restaurantId,
    Map<String, dynamic>? primary,
    Map<String, dynamic>? fallback,
  }) {
    final merged = <String, dynamic>{
      ...?fallback,
      ...?primary,
    };

    merged['id'] = _stringValue(merged['id']) ??
        _stringValue(merged['restaurant_id']) ??
        restaurantId;
    merged['restaurant_id'] = _stringValue(merged['restaurant_id']) ??
        _stringValue(merged['id']) ??
        restaurantId;
    merged['name'] = restaurantNameOf(merged);
    merged['image_url'] = restaurantImageOf(merged);
    merged['phone'] = restaurantPhoneOf(merged);

    return merged;
  }

  static Future<Map<String, Map<String, dynamic>>>
      _loadRestaurantsByIdentifiers(
    Iterable<String> identifiers, {
    required String select,
    required int requiredScope,
    bool forceRefresh = false,
  }) async {
    final requestedIds = identifiers
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);

    if (requestedIds.isEmpty) {
      return const <String, Map<String, dynamic>>{};
    }

    final result = <String, Map<String, dynamic>>{};
    final unresolved = <String>[];

    for (final id in requestedIds) {
      final cached = forceRefresh ? null : _cachedRestaurant(id, requiredScope);
      if (cached != null) {
        result[id] = cached;
      } else {
        unresolved.add(id);
      }
    }

    if (unresolved.isEmpty) {
      return result;
    }

    final normalizedByIdentifier = <String, Map<String, dynamic>>{};
    final loadedByRestaurantId = await _loadManagersByColumn(
      column: 'restaurant_id',
      values: unresolved,
      select: select,
      requiredScope: requiredScope,
    );
    normalizedByIdentifier.addAll(loadedByRestaurantId);

    final stillMissing = unresolved
        .where((id) => !normalizedByIdentifier.containsKey(id))
        .toList(growable: false);
    if (stillMissing.isNotEmpty) {
      final loadedByManagerId = await _loadManagersByColumn(
        column: 'user_id',
        values: stillMissing,
        select: select,
        requiredScope: requiredScope,
      );
      normalizedByIdentifier.addAll(loadedByManagerId);
    }

    for (final id in requestedIds) {
      final cached =
          normalizedByIdentifier[id] ?? _cachedRestaurant(id, requiredScope);
      if (cached != null) {
        result[id] = cached;
      }
    }

    return result;
  }

  static Future<Map<String, Map<String, dynamic>>> _loadManagersByColumn({
    required String column,
    required List<String> values,
    required String select,
    required int requiredScope,
  }) async {
    if (values.isEmpty) {
      return const <String, Map<String, dynamic>>{};
    }

    final rows =
        await SessionManager.instance.runWithValidSession<List<dynamic>>(
      () {
        final query = _client.from('managers').select(select);

        if (values.length == 1) {
          return query.eq(column, values.first);
        } else {
          return query.inFilter(column, values);
        }
      },
    );
    if (rows == null) {
      return const <String, Map<String, dynamic>>{};
    }

    final byIdentifier = <String, Map<String, dynamic>>{};
    for (final row in rows.whereType<Map>()) {
      final restaurant =
          _normalizeManagerRestaurant(Map<String, dynamic>.from(row));
      _cacheRestaurant(restaurant, requiredScope);

      final restaurantId = restaurantIdOf(restaurant);
      final managerId = managerIdOf(restaurant);
      if (restaurantId.isNotEmpty) {
        byIdentifier[restaurantId] = restaurant;
      }
      if (managerId.isNotEmpty) {
        byIdentifier[managerId] = restaurant;
      }
    }
    return byIdentifier;
  }

  static Map<String, dynamic>? _cachedRestaurant(
      String identifier, int minScope) {
    final entry = _restaurantCache[identifier];
    if (entry == null) {
      return null;
    }

    if (entry.isExpired) {
      _restaurantCache.remove(identifier);
      return null;
    }

    if (entry.scope < minScope) {
      return null;
    }

    return entry.value;
  }

  static void _cacheRestaurant(Map<String, dynamic> restaurant, int scope) {
    final restaurantId = restaurantIdOf(restaurant);
    final managerId = managerIdOf(restaurant);
    final now = DateTime.now();

    void cacheKey(String key) {
      if (key.isEmpty) {
        return;
      }

      final previousEntry = _restaurantCache[key];
      final previous = previousEntry == null || previousEntry.isExpired
          ? null
          : previousEntry.value;
      final merged = previous == null
          ? Map<String, dynamic>.from(restaurant)
          : <String, dynamic>{...previous, ...restaurant};
      final previousScope = previousEntry?.scope ?? 0;
      _restaurantCache[key] = _RestaurantCacheEntry(
        value: merged,
        scope: previousScope > scope ? previousScope : scope,
        cachedAt: now,
      );
    }

    cacheKey(restaurantId);
    cacheKey(managerId);
  }

  static String? _composeAddressFromParts(Map<String, dynamic> restaurant) {
    final parts = [
      _stringValue(restaurant['street']),
      _stringValue(restaurant['district']),
      _stringValue(restaurant['city']),
      _stringValue(restaurant['area']),
      _stringValue(restaurant['governorate']),
    ].whereType<String>().toList(growable: false);

    if (parts.isEmpty) {
      return null;
    }

    return parts.join(' - ');
  }

  static String? _formatTimeValue(dynamic value) {
    final text = _stringValue(value);
    if (text == null) {
      return null;
    }

    final parsedDate = DateTime.tryParse(text);
    if (parsedDate != null) {
      final local = parsedDate.toLocal();
      final hour = local.hour.toString().padLeft(2, '0');
      final minute = local.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }

    final normalized = text.replaceAll('.', ':');
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(
      normalized,
    );
    if (match != null) {
      final hour =
          (int.tryParse(match.group(1) ?? '') ?? 0).toString().padLeft(2, '0');
      final minute = match.group(2) ?? '00';
      return '$hour:$minute';
    }

    return text;
  }

  static String? _stringValue(dynamic value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty || text == 'null') {
      return null;
    }
    return text;
  }

  static double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  static double _degToRad(double degree) {
    return degree * (math.pi / 180.0);
  }

  static String _nearbyCacheKey({
    required double latitude,
    required double longitude,
  }) {
    return '${latitude.toStringAsFixed(3)}:${longitude.toStringAsFixed(3)}';
  }
}

class _RestaurantListCacheEntry {
  const _RestaurantListCacheEntry({
    required this.value,
    required this.cachedAt,
  });

  final List<Map<String, dynamic>> value;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > RestaurantsService._listCacheTtl;
}

class _RestaurantCacheEntry {
  const _RestaurantCacheEntry({
    required this.value,
    required this.scope,
    required this.cachedAt,
  });

  final Map<String, dynamic> value;
  final int scope;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) >
      RestaurantsService._restaurantCacheTtl;
}
