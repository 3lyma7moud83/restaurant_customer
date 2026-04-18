import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../cart/cart_page.dart';
import '../cart/cart_provider.dart';
import '../core/localization/app_localizations.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/responsive.dart';
import '../services/categories_service.dart';
import '../services/items_service.dart';
import '../widgets/restaurant_card_components.dart';
import 'auth/login_page.dart';

class RestaurantMenuPage extends StatefulWidget {
  final String managerId;
  final String restaurantId;
  final String restaurantName;

  const RestaurantMenuPage({
    super.key,
    required this.managerId,
    required this.restaurantId,
    required this.restaurantName,
  });

  @override
  State<RestaurantMenuPage> createState() => _RestaurantMenuPageState();
}

class _RestaurantMenuPageState extends State<RestaurantMenuPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<Map<String, dynamic>> categories = const [];
  List<Map<String, dynamic>> items = const [];

  String? selectedCategoryId;
  bool loading = true;
  int _itemsRequestId = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCategories());
  }

  int _getCrossAxisCount(double width) {
    if (width < 340) {
      return 1;
    }
    if (width < 560) {
      return 2;
    }
    if (width < 820) {
      return 3;
    }
    if (width < 1080) {
      return 4;
    }
    if (width < 1360) {
      return 5;
    }
    if (width < 1640) {
      return 6;
    }
    return 7;
  }

  double _itemAspectRatioFor(int crossAxisCount) {
    return switch (crossAxisCount) {
      1 => 1.45,
      2 => 1.14,
      3 => 1.04,
      4 => 1.0,
      5 => 0.96,
      _ => 0.94,
    };
  }

  Future<void> _loadCategories() async {
    try {
      final fetchedCategories =
          await CategoriesService.getByManager(widget.managerId);
      if (!mounted) {
        return;
      }

      categories = fetchedCategories;
      if (categories.isNotEmpty) {
        selectedCategoryId ??= categories.first['id']?.toString();
        await _loadItems();
      }
    } catch (_) {
      if (mounted) {
        _showError();
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
        });
      }
    }
  }

  void _showLockedCartNotice() {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('menu.locked_order_notice')),
      ),
    );
  }

  Future<void> _loadItems() async {
    if (selectedCategoryId == null) {
      return;
    }

    final requestId = ++_itemsRequestId;
    try {
      final result = await ItemsService.fetchByCategory(
        categoryId: selectedCategoryId!,
      );

      if (!mounted || requestId != _itemsRequestId) {
        return;
      }

      setState(() {
        items = result;
      });
    } catch (_) {
      if (!mounted || requestId != _itemsRequestId) {
        return;
      }

      setState(() {
        items = const [];
      });
      _showError();
    }
  }

  void _showError() {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text(ErrorLogger.userMessage)),
    );
  }

  double _priceOf(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _formatCurrency(double value) {
    final normalized =
        value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
    return context.tr('common.currency', args: {'value': normalized});
  }

  Future<void> _openCart(CartController cart) async {
    if (_supabase.auth.currentUser == null) {
      await Navigator.push(
        context,
        AppTheme.platformPageRoute(builder: (_) => const LoginPage()),
      );
      if (!mounted || _supabase.auth.currentUser == null) {
        return;
      }
    }

    await Navigator.push(
      context,
      AppTheme.platformPageRoute(
        builder: (_) => CartPage(
          restaurantId: cart.restaurantId ?? widget.restaurantId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartProvider.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(widget.restaurantName),
        actions: [
          _MenuCartAction(
            cartCount: cart.totalCount,
            onPressed: () => _openCart(cart),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AppConstrainedContent(
        child: loading
            ? _MenuLoadingSkeleton(
                crossAxisResolver: _getCrossAxisCount,
                aspectRatioResolver: _itemAspectRatioFor,
              )
            : Column(
                children: [
                  if (cart.isLocked)
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF6EE),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFFF4DEC8),
                        ),
                      ),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => _openCart(cart),
                            child: Text(context.tr('common.open_cart')),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              context.tr('menu.locked_cart_message'),
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                color: AppTheme.text,
                                fontWeight: FontWeight.w700,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (categories.isNotEmpty)
                    SizedBox(
                      height: 46,
                      child: ListView.builder(
                        physics: AppTheme.bouncingScrollPhysics,
                        scrollDirection: Axis.horizontal,
                        itemCount: categories.length,
                        itemBuilder: (_, index) {
                          final category = categories[index];
                          final categoryId = category['id']?.toString();
                          final selected = categoryId == selectedCategoryId;
                          final categoryName =
                              (category['name'] ?? '').toString().trim();

                          return Padding(
                            padding: EdgeInsetsDirectional.only(
                              start: index == 0 ? 0 : 8,
                              end: index == categories.length - 1 ? 0 : 2,
                            ),
                            child: FilterChip(
                              selected: selected,
                              showCheckmark: false,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              visualDensity: const VisualDensity(
                                vertical: -2,
                                horizontal: -2,
                              ),
                              selectedColor: AppTheme.primary,
                              backgroundColor: const Color(0xFFF5ECE3),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                              labelPadding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 0,
                              ),
                              label: Text(
                                categoryName,
                                style: TextStyle(
                                  color:
                                      selected ? Colors.white : AppTheme.text,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                              onSelected: (_) async {
                                if (categoryId == null ||
                                    categoryId == selectedCategoryId) {
                                  return;
                                }

                                setState(() {
                                  selectedCategoryId = categoryId;
                                });
                                await _loadItems();
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final crossAxisCount =
                            _getCrossAxisCount(constraints.maxWidth);
                        final childAspectRatio =
                            _itemAspectRatioFor(crossAxisCount);

                        if (selectedCategoryId == null) {
                          return Center(
                            child: Text(
                              context.tr('menu.select_category_first'),
                              style: const TextStyle(
                                color: Color(0xFF667085),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }

                        if (items.isEmpty) {
                          return Center(
                            child: Text(
                              context.tr('menu.no_items_here'),
                              style: const TextStyle(
                                color: Color(0xFF667085),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }

                        return GridView.builder(
                          physics: AppTheme.bouncingScrollPhysics,
                          cacheExtent: constraints.maxHeight + 360,
                          padding: const EdgeInsets.only(bottom: 6),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            childAspectRatio: childAspectRatio,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                          ),
                          itemCount: items.length,
                          itemBuilder: (_, index) {
                            final item = items[index];
                            final itemId = (item['id'] ?? '').toString();
                            final itemName = (item['name'] ?? '').toString();
                            final imageUrl =
                                (item['image_url'] ?? '').toString();
                            final price = _priceOf(item['price']);

                            return RepaintBoundary(
                              child: ItemCard(
                                name: itemName.isEmpty
                                    ? context.tr('menu.default_item')
                                    : itemName,
                                priceText: _formatCurrency(price),
                                imageUrl: imageUrl,
                                quantity: cart.getQuantity(itemId),
                                onAdd: () {
                                  if (cart.isLocked) {
                                    _showLockedCartNotice();
                                    return;
                                  }
                                  if (itemId.isEmpty) {
                                    return;
                                  }
                                  cart.addItem(
                                    id: itemId,
                                    name: itemName,
                                    price: price,
                                    image: imageUrl,
                                    restaurantId: widget.restaurantId,
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
    );
  }
}

class _MenuCartAction extends StatelessWidget {
  const _MenuCartAction({
    required this.cartCount,
    required this.onPressed,
  });

  final int cartCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
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
              onTap: onPressed,
              child: const SizedBox(
                width: 38,
                height: 38,
                child: Icon(
                  Icons.shopping_cart_outlined,
                  size: 19,
                ),
              ),
            ),
          ),
        ),
        if (cartCount > 0)
          PositionedDirectional(
            end: -2,
            top: -2,
            child: Container(
              height: 17,
              constraints: const BoxConstraints(minWidth: 17),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 1.1),
              ),
              child: Text(
                cartCount.toString(),
                style: const TextStyle(
                  fontSize: 9.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ItemCard extends StatefulWidget {
  final String name;
  final String priceText;
  final String imageUrl;
  final int quantity;
  final VoidCallback onAdd;

  const ItemCard({
    super.key,
    required this.name,
    required this.priceText,
    required this.imageUrl,
    required this.quantity,
    required this.onAdd,
  });

  @override
  State<ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<ItemCard> {
  bool _pressed = false;
  Timer? _pressResetTimer;

  void _animateAdd() {
    if (!mounted) {
      return;
    }

    setState(() => _pressed = true);
    _pressResetTimer?.cancel();
    _pressResetTimer = Timer(
      kIsWeb ? Duration.zero : const Duration(milliseconds: 130),
      () {
        if (mounted) {
          setState(() => _pressed = false);
        }
      },
    );

    widget.onAdd();
  }

  @override
  void dispose() {
    _pressResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed && !kIsWeb ? 0.97 : 1,
      duration: kIsWeb ? Duration.zero : const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white,
          boxShadow: const [
            BoxShadow(
              blurRadius: 10,
              color: Color(0x12000000),
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(14),
                      ),
                      child: widget.imageUrl.isEmpty
                          ? const ImageFallback(
                              icon: Icons.fastfood_rounded,
                              iconSize: 34,
                            )
                          : AppCachedImage(
                              imageUrl: widget.imageUrl,
                              placeholder: const _MenuItemImagePlaceholder(),
                              errorWidget: const ImageFallback(
                                icon: Icons.fastfood_rounded,
                                iconSize: 34,
                              ),
                            ),
                    ),
                  ),
                  if (widget.quantity > 0)
                    PositionedDirectional(
                      top: 7,
                      start: 7,
                      child: Container(
                        height: 21,
                        padding: const EdgeInsets.symmetric(horizontal: 6.5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.78),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          widget.quantity.toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 7, 10, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.priceText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.primaryDeep,
                            fontWeight: FontWeight.w800,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.28),
                              blurRadius: 10,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            onTap: _animateAdd,
                            borderRadius: BorderRadius.circular(999),
                            child: const SizedBox(
                              width: 34,
                              height: 34,
                              child: Icon(
                                Icons.add_rounded,
                                color: Colors.white,
                                size: 21,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuLoadingSkeleton extends StatelessWidget {
  const _MenuLoadingSkeleton({
    required this.crossAxisResolver,
    required this.aspectRatioResolver,
  });

  final int Function(double width) crossAxisResolver;
  final double Function(int crossAxisCount) aspectRatioResolver;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = crossAxisResolver(width);

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: crossAxisCount * 2,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: aspectRatioResolver(crossAxisCount),
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemBuilder: (_, __) => const _MenuItemSkeletonCard(),
        );
      },
    );
  }
}

class _MenuItemSkeletonCard extends StatelessWidget {
  const _MenuItemSkeletonCard();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white,
        boxShadow: const [
          BoxShadow(
            blurRadius: 9,
            color: Color(0x12000000),
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: const Column(
        children: [
          Expanded(child: _MenuItemImagePlaceholder()),
          Padding(
            padding: EdgeInsets.fromLTRB(10, 7, 10, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MenuTextSkeleton(width: 92),
                SizedBox(height: 6),
                Row(
                  children: [
                    _MenuTextSkeleton(width: 62),
                    Spacer(),
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: Color(0xFFECECEC),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuItemImagePlaceholder extends StatelessWidget {
  const _MenuItemImagePlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF4E6D9),
            Color(0xFFECECEC),
          ],
        ),
      ),
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}

class _MenuTextSkeleton extends StatelessWidget {
  const _MenuTextSkeleton({
    required this.width,
  });

  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 10,
      decoration: BoxDecoration(
        color: const Color(0xFFE9E9E9),
        borderRadius: BorderRadius.circular(999),
      ),
    );
  }
}
