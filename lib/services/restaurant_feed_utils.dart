import 'package:flutter/foundation.dart';

import 'restaurants_service.dart';

class RestaurantFeedUtils {
  RestaurantFeedUtils._();

  static const double _tabletBreakpoint = 700;
  static const double _desktopBreakpoint = 1000;
  static const double _wideDesktopBreakpoint = 1400;

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
    if (!width.isFinite || width <= 0) {
      return 1;
    }
    if (width > _wideDesktopBreakpoint) {
      return 4;
    }
    if (width > _desktopBreakpoint) {
      return 3;
    }
    if (width > _tabletBreakpoint) {
      return 2;
    }
    return 1;
  }

  static double cardAspectRatioFor({
    required int crossAxisCount,
    required double maxWidth,
  }) {
    final safeCount = crossAxisCount <= 0 ? 1 : crossAxisCount;
    final safeWidth = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 360.0;
    final estimatedSpacing = safeCount <= 1 ? 0.0 : (safeCount - 1) * 14.0;
    final estimatedCardWidth =
        ((safeWidth - estimatedSpacing) / safeCount).clamp(220.0, 620.0);
    final targetHeight = switch (safeCount) {
      1 => (estimatedCardWidth * 0.50).clamp(138.0, 186.0),
      2 => (estimatedCardWidth * 0.46).clamp(138.0, 180.0),
      3 => (estimatedCardWidth * 0.44).clamp(136.0, 172.0),
      _ => (estimatedCardWidth * 0.42).clamp(132.0, 166.0),
    };
    return (estimatedCardWidth / targetHeight).clamp(2.08, 2.95).toDouble();
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
