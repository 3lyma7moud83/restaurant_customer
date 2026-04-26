import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../services/restaurant_feed_utils.dart';
import '../services/restaurants_service.dart';
import 'restaurant_card_components.dart';

typedef RestaurantContextAction = void Function(
  BuildContext context,
  Map<String, dynamic> restaurant,
);

class RestaurantsGridSection extends StatelessWidget {
  const RestaurantsGridSection({
    super.key,
    required this.loading,
    required this.hasError,
    required this.restaurants,
    required this.searchQueryListenable,
    required this.onRefresh,
    required this.emptyStateBuilder,
    required this.errorStateBuilder,
    required this.onRestaurantTap,
    this.customerLat,
    this.customerLng,
    this.onRestaurantInfoTap,
    this.loadingSkeletonKey = 'restaurants-loading',
    this.errorKey = 'restaurants-error',
    this.emptyKey = 'restaurants-empty',
    this.gridKey = 'restaurants-grid',
  });

  final bool loading;
  final bool hasError;
  final List<Map<String, dynamic>> restaurants;
  final ValueListenable<String> searchQueryListenable;
  final Future<void> Function() onRefresh;
  final WidgetBuilder emptyStateBuilder;
  final WidgetBuilder errorStateBuilder;
  final RestaurantContextAction onRestaurantTap;
  final double? customerLat;
  final double? customerLng;
  final RestaurantContextAction? onRestaurantInfoTap;
  final String loadingSkeletonKey;
  final String errorKey;
  final String emptyKey;
  final String gridKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = RestaurantFeedUtils.calcGridCount(
          constraints.maxWidth,
        );
        final gridMetrics = _RestaurantGridMetrics.fromConstraints(
          constraints: constraints,
          crossAxisCount: crossAxisCount,
        );
        final childAspectRatio = RestaurantFeedUtils.cardAspectRatioFor(
          crossAxisCount: crossAxisCount,
          maxWidth: constraints.maxWidth,
        );
        final Widget content;
        if (loading) {
          content = RestaurantGridSkeleton(
            key: ValueKey(loadingSkeletonKey),
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: gridMetrics.mainAxisSpacing,
            crossAxisSpacing: gridMetrics.crossAxisSpacing,
            childAspectRatio: childAspectRatio,
            padding: EdgeInsets.only(bottom: gridMetrics.bottomPadding),
          );
        } else if (hasError) {
          content = KeyedSubtree(
            key: ValueKey(errorKey),
            child: errorStateBuilder(context),
          );
        } else {
          content = _SearchFilteredRestaurants(
            key: ValueKey(gridKey),
            constraints: constraints,
            crossAxisCount: crossAxisCount,
            restaurants: restaurants,
            searchQueryListenable: searchQueryListenable,
            onRefresh: onRefresh,
            gridMetrics: gridMetrics,
            childAspectRatio: childAspectRatio,
            customerLat: customerLat,
            customerLng: customerLng,
            emptyKey: emptyKey,
            emptyStateBuilder: emptyStateBuilder,
            onTap: onRestaurantTap,
            onInfoTap: onRestaurantInfoTap,
          );
        }

        if (kIsWeb) {
          return content;
        }

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: content,
        );
      },
    );
  }
}

class _SearchFilteredRestaurants extends StatelessWidget {
  const _SearchFilteredRestaurants({
    super.key,
    required this.constraints,
    required this.crossAxisCount,
    required this.restaurants,
    required this.searchQueryListenable,
    required this.onRefresh,
    required this.gridMetrics,
    required this.childAspectRatio,
    required this.customerLat,
    required this.customerLng,
    required this.emptyKey,
    required this.emptyStateBuilder,
    required this.onTap,
    required this.onInfoTap,
  });

  final BoxConstraints constraints;
  final int crossAxisCount;
  final List<Map<String, dynamic>> restaurants;
  final ValueListenable<String> searchQueryListenable;
  final Future<void> Function() onRefresh;
  final _RestaurantGridMetrics gridMetrics;
  final double childAspectRatio;
  final double? customerLat;
  final double? customerLng;
  final String emptyKey;
  final WidgetBuilder emptyStateBuilder;
  final RestaurantContextAction onTap;
  final RestaurantContextAction? onInfoTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: searchQueryListenable,
      builder: (context, searchQuery, _) {
        final filtered = RestaurantFeedUtils.filterBySearch(
          restaurants,
          searchQuery,
        );
        if (filtered.isEmpty) {
          return KeyedSubtree(
            key: ValueKey(emptyKey),
            child: emptyStateBuilder(context),
          );
        }

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: _RestaurantGrid(
            constraints: constraints,
            crossAxisCount: crossAxisCount,
            gridMetrics: gridMetrics,
            childAspectRatio: childAspectRatio,
            customerLat: customerLat,
            customerLng: customerLng,
            restaurants: filtered,
            onTap: onTap,
            onInfoTap: onInfoTap,
          ),
        );
      },
    );
  }
}

class _RestaurantGrid extends StatelessWidget {
  const _RestaurantGrid({
    required this.constraints,
    required this.crossAxisCount,
    required this.gridMetrics,
    required this.childAspectRatio,
    required this.customerLat,
    required this.customerLng,
    required this.restaurants,
    required this.onTap,
    required this.onInfoTap,
  });

  final BoxConstraints constraints;
  final int crossAxisCount;
  final _RestaurantGridMetrics gridMetrics;
  final double childAspectRatio;
  final double? customerLat;
  final double? customerLng;
  final List<Map<String, dynamic>> restaurants;
  final RestaurantContextAction onTap;
  final RestaurantContextAction? onInfoTap;

  @override
  Widget build(BuildContext context) {
    final physics = AppTheme.bouncingScrollPhysics;
    final cacheExtent = constraints.maxHeight.clamp(520.0, 1200.0).toDouble();

    return GridView.builder(
      physics: physics,
      padding: EdgeInsets.only(bottom: gridMetrics.bottomPadding),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      cacheExtent: cacheExtent,
      itemCount: restaurants.length,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: childAspectRatio,
        crossAxisSpacing: gridMetrics.crossAxisSpacing,
        mainAxisSpacing: gridMetrics.mainAxisSpacing,
      ),
      itemBuilder: (context, index) {
        final restaurant = restaurants[index];
        final restaurantId = RestaurantsService.restaurantIdOf(restaurant);
        final presentation = _RestaurantCardPresentation.fromRestaurant(
          context: context,
          restaurant: restaurant,
          customerLat: customerLat,
          customerLng: customerLng,
        );

        final card = RepaintBoundary(
          key: ValueKey(
            restaurantId.isEmpty ? 'restaurant-index-$index' : restaurantId,
          ),
          child: RestaurantListCard(
            name: RestaurantsService.cardNameOf(restaurant),
            imageUrl: RestaurantsService.cardImageOf(restaurant),
            deliveryMinutes: presentation.deliveryMinutes,
            categoryLabel: presentation.categoryLabel,
            distanceLabel: presentation.distanceLabel,
            statusLabel: presentation.statusLabel,
            statusPositive: presentation.statusPositive,
            onInfoTap: onInfoTap == null
                ? null
                : () => onInfoTap!(context, restaurant),
            onTap: () => onTap(context, restaurant),
          ),
        );

        final animationDuration = Duration(
          milliseconds: 220 + (index.clamp(0, 8) * 24),
        );
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: kIsWeb ? Duration.zero : animationDuration,
          curve: Curves.easeOutBack,
          child: card,
          builder: (context, value, child) {
            return Opacity(
              opacity: value.clamp(0, 1).toDouble(),
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 14),
                child: child,
              ),
            );
          },
        );
      },
    );
  }
}

class _RestaurantGridMetrics {
  const _RestaurantGridMetrics({
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
    required this.bottomPadding,
  });

  factory _RestaurantGridMetrics.fromConstraints({
    required BoxConstraints constraints,
    required int crossAxisCount,
  }) {
    final width = constraints.maxWidth;
    final compact = width < 420;
    final spacing = switch (crossAxisCount) {
      1 => compact ? 10.0 : 12.0,
      2 => 14.0,
      3 => 15.0,
      _ => 16.0,
    };
    return _RestaurantGridMetrics(
      crossAxisSpacing: spacing,
      mainAxisSpacing: spacing,
      bottomPadding: (spacing + 10).clamp(16.0, 30.0).toDouble(),
    );
  }

  final double crossAxisSpacing;
  final double mainAxisSpacing;
  final double bottomPadding;
}

class _RestaurantCardPresentation {
  const _RestaurantCardPresentation({
    required this.deliveryMinutes,
    required this.categoryLabel,
    required this.distanceLabel,
    required this.statusLabel,
    required this.statusPositive,
  });

  factory _RestaurantCardPresentation.fromRestaurant({
    required BuildContext context,
    required Map<String, dynamic> restaurant,
    required double? customerLat,
    required double? customerLng,
  }) {
    final distanceKm = RestaurantsService.distanceKmToCustomer(
      restaurant: restaurant,
      customerLat: customerLat,
      customerLng: customerLng,
    );
    final deliveryMinutes = RestaurantsService.cardDeliveryMinutesOf(
      restaurant,
      customerLat: customerLat,
      customerLng: customerLng,
      distanceKm: distanceKm,
    );
    final categoryLabel = _categoryLabelOf(
      restaurant: restaurant,
    );
    final distanceLabel = _distanceLabelOf(
      context: context,
      distanceKm: distanceKm,
    );
    final status = _openStatusOf(context, restaurant);

    return _RestaurantCardPresentation(
      deliveryMinutes: deliveryMinutes,
      categoryLabel: categoryLabel,
      distanceLabel: distanceLabel,
      statusLabel: status.label,
      statusPositive: status.isOpen,
    );
  }

  final int? deliveryMinutes;
  final String? categoryLabel;
  final String? distanceLabel;
  final String statusLabel;
  final bool statusPositive;

  static String? _categoryLabelOf({
    required Map<String, dynamic> restaurant,
  }) {
    final label = RestaurantsService.cardTypeOf(restaurant);
    return label?.trim().isNotEmpty == true ? label!.trim() : null;
  }

  static String? _distanceLabelOf({
    required BuildContext context,
    required double? distanceKm,
  }) {
    final km = distanceKm;
    if (km == null || !km.isFinite || km < 0) {
      return null;
    }

    final precision = km >= 10 ? 0 : 1;
    final value = km.toStringAsFixed(precision);
    final unit = context.tr('common.km_unit');
    return '$value $unit';
  }

  static _OpenStatus _openStatusOf(
    BuildContext context,
    Map<String, dynamic> restaurant,
  ) {
    final opening = _clockMinuteOf(
      restaurant['opening_time'] ??
          restaurant['open_time'] ??
          restaurant['opens_at'] ??
          restaurant['start_time'],
    );
    final closing = _clockMinuteOf(
      restaurant['closing_time'] ??
          restaurant['close_time'] ??
          restaurant['closes_at'] ??
          restaurant['end_time'],
    );

    if (opening == null || closing == null) {
      return _OpenStatus(
        isOpen: true,
        label: context.tr('common.open_now'),
      );
    }

    final now = DateTime.now();
    final minuteNow = (now.hour * 60) + now.minute;
    final isOpen = _isWithinOpenWindow(
      currentMinute: minuteNow,
      openingMinute: opening,
      closingMinute: closing,
    );
    return _OpenStatus(
      isOpen: isOpen,
      label: context.tr(isOpen ? 'common.open_now' : 'common.closed_now'),
    );
  }

  static int? _clockMinuteOf(dynamic value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty || raw == 'null') {
      return null;
    }

    final parsedDate = DateTime.tryParse(raw);
    if (parsedDate != null) {
      final local = parsedDate.toLocal();
      return (local.hour * 60) + local.minute;
    }

    final normalized = raw.replaceAll('.', ':');
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch(
      normalized,
    );
    if (match == null) {
      return null;
    }

    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    if (hour == null || minute == null || hour < 0 || minute < 0) {
      return null;
    }
    return (hour % 24 * 60) + (minute % 60);
  }

  static bool _isWithinOpenWindow({
    required int currentMinute,
    required int openingMinute,
    required int closingMinute,
  }) {
    if (openingMinute == closingMinute) {
      return true;
    }
    if (openingMinute < closingMinute) {
      return currentMinute >= openingMinute && currentMinute < closingMinute;
    }
    return currentMinute >= openingMinute || currentMinute < closingMinute;
  }
}

class _OpenStatus {
  const _OpenStatus({
    required this.isOpen,
    required this.label,
  });

  final bool isOpen;
  final String label;
}
