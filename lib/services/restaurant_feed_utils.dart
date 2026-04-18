import 'package:flutter/foundation.dart';

import 'restaurants_service.dart';

class RestaurantFeedUtils {
  RestaurantFeedUtils._();

  static List<Map<String, dynamic>> filterByRange({
    required List<Map<String, dynamic>> source,
    required double? customerLat,
    required double? customerLng,
  }) {
    return source
        .where(
          (restaurant) => RestaurantsService.isWithinDeliveryRange(
            restaurant: restaurant,
            customerLat: customerLat,
            customerLng: customerLng,
          ),
        )
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> filterBySearch(
    List<Map<String, dynamic>> source,
    String text,
  ) {
    final q = text.trim().toLowerCase();
    if (q.isEmpty) {
      return source;
    }

    return source
        .where((restaurant) =>
            RestaurantsService.cardNameOf(restaurant).toLowerCase().contains(q))
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> reuseRestaurantMaps(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> next,
  ) {
    final currentById = {
      for (final restaurant in current)
        RestaurantsService.restaurantIdOf(restaurant): restaurant,
    };

    return next.map((restaurant) {
      final currentRestaurant =
          currentById[RestaurantsService.restaurantIdOf(restaurant)];
      if (currentRestaurant != null &&
          mapEquals(currentRestaurant, restaurant)) {
        return currentRestaurant;
      }
      return restaurant;
    }).toList(growable: false);
  }

  static bool sameIdentityList(
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

  static int calcGridCount(double width) {
    if (width >= 1500) return 7;
    if (width >= 1260) return 6;
    if (width >= 1040) return 5;
    if (width >= 820) return 4;
    return 3;
  }

  static double cardAspectRatioFor(int crossAxisCount) {
    return 1;
  }

  static bool gridNeedsScroll({
    required double maxWidth,
    required double maxHeight,
    required int crossAxisCount,
    required int itemCount,
    required double crossAxisSpacing,
    required double mainAxisSpacing,
    required double childAspectRatio,
  }) {
    if (itemCount <= 0 ||
        maxHeight <= 0 ||
        maxWidth <= 0 ||
        crossAxisCount <= 0) {
      return false;
    }

    final totalCrossSpacing = (crossAxisCount - 1) * crossAxisSpacing;
    final tileWidth = (maxWidth - totalCrossSpacing) / crossAxisCount;
    if (tileWidth <= 0) {
      return true;
    }

    final tileHeight = tileWidth / childAspectRatio;
    if (tileHeight <= 0) {
      return true;
    }

    final rowCount = (itemCount / crossAxisCount).ceil();
    final contentHeight =
        (rowCount * tileHeight) + ((rowCount - 1) * mainAxisSpacing);
    return contentHeight > maxHeight;
  }

  static String realtimeRestaurantIdOf(Map<dynamic, dynamic>? row) {
    if (row == null) {
      return '';
    }
    try {
      final map = Map<String, dynamic>.from(row);
      return RestaurantsService.restaurantIdOf(map);
    } catch (_) {
      return '';
    }
  }
}
