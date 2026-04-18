import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
        final Widget content;
        if (loading) {
          content = RestaurantGridSkeleton(
            key: ValueKey(loadingSkeletonKey),
            crossAxisCount: crossAxisCount,
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
    required this.restaurants,
    required this.onTap,
    required this.onInfoTap,
  });

  final BoxConstraints constraints;
  final int crossAxisCount;
  final List<Map<String, dynamic>> restaurants;
  final RestaurantContextAction onTap;
  final RestaurantContextAction? onInfoTap;

  @override
  Widget build(BuildContext context) {
    final isCompactGrid = crossAxisCount <= 2;
    final mainAxisSpacing = isCompactGrid ? 10.0 : 12.0;
    final crossAxisSpacing = isCompactGrid ? 10.0 : 12.0;
    final childAspectRatio = RestaurantFeedUtils.cardAspectRatioFor(
      crossAxisCount,
    );

    final needsScroll = RestaurantFeedUtils.gridNeedsScroll(
      maxWidth: constraints.maxWidth,
      maxHeight: constraints.maxHeight,
      crossAxisCount: crossAxisCount,
      itemCount: restaurants.length,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      childAspectRatio: childAspectRatio,
    );

    final physics = AppTheme.conditionalScrollPhysics(canScroll: needsScroll);
    final cacheExtent = constraints.maxHeight.clamp(520.0, 1200.0).toDouble();
    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
      childAspectRatio: childAspectRatio,
    );

    return GridView.builder(
      primary: false,
      physics: physics,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      cacheExtent: cacheExtent,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: false,
      itemCount: restaurants.length,
      gridDelegate: delegate,
      itemBuilder: (context, index) {
        final restaurant = restaurants[index];
        final restaurantId = RestaurantsService.restaurantIdOf(restaurant);

        return RepaintBoundary(
          key: ValueKey(
            restaurantId.isEmpty ? 'restaurant-index-$index' : restaurantId,
          ),
          child: RestaurantListCard(
            name: RestaurantsService.cardNameOf(restaurant),
            imageUrl: RestaurantsService.cardImageOf(restaurant),
            onInfoTap: onInfoTap == null
                ? null
                : () => onInfoTap!(context, restaurant),
            onTap: () => onTap(context, restaurant),
          ),
        );
      },
    );
  }
}
