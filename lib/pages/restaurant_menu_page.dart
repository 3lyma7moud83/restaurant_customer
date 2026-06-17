import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../cart/cart_page.dart';
import '../cart/cart_provider.dart';
import '../core/auth/auth_navigation_guard.dart';
import '../core/localization/app_localizations.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/input_focus_guard.dart';
import '../core/ui/app_snackbar.dart';
import '../core/ui/responsive.dart';
import '../services/categories_service.dart';
import '../services/items_service.dart';
import '../widgets/restaurant_card_components.dart';

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
  List<Map<String, dynamic>> categories = const [];
  List<Map<String, dynamic>> items = const [];

  String? selectedCategoryId;
  bool loading = true;
  int _itemsRequestId = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        InputFocusGuard.dismiss(context: context);
      }
    });
    unawaited(_loadCategories());
  }

  int _getCrossAxisCount(double width) {
    if (width < 560) {
      return 2;
    }
    if (width < 920) {
      return 3;
    }
    if (width < 1200) {
      return 4;
    }
    if (width < 1480) {
      return 5;
    }
    if (width < 1740) {
      return 6;
    }
    return 7;
  }

  double _itemAspectRatioFor(int crossAxisCount) {
    return switch (crossAxisCount) {
      <= 2 => 1.10,
      3 => 1.07,
      4 => 1.04,
      5 => 1.02,
      _ => 1.00,
    };
  }

  Future<void> _loadCategories() async {
    try {
      final fetchedCategories = await CategoriesService.getByRestaurantCached(
        restaurantId: widget.restaurantId,
        managerId: widget.managerId,
        forceRefresh: true,
      );
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

    AppSnackBar.show(
      context,
      message: context.tr('menu.locked_order_notice'),
    );
  }

  Future<void> _loadItems() async {
    if (selectedCategoryId == null) {
      return;
    }

    final requestId = ++_itemsRequestId;
    try {
      final result = await ItemsService.fetchByCategory(
        restaurantId: widget.restaurantId,
        categoryId: selectedCategoryId!,
        forceRefresh: true,
      );

      if (!mounted || requestId != _itemsRequestId) {
        return;
      }

      if (_sameItemsSnapshot(result)) {
        return;
      }

      setState(() => items = result);
    } catch (_) {
      if (!mounted || requestId != _itemsRequestId) {
        return;
      }

      if (items.isNotEmpty) {
        setState(() => items = const []);
      }
      _showError();
    }
  }

  void _showError() {
    if (!mounted) {
      return;
    }

    AppSnackBar.show(
      context,
      message: ErrorLogger.userMessage,
    );
  }

  bool _sameItemsSnapshot(List<Map<String, dynamic>> next) {
    if (items.length != next.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (!mapEquals(items[i], next[i])) {
        return false;
      }
    }
    return true;
  }

  double _priceOf(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  List<MenuItemVariant> _variantsOf(
    Map<String, dynamic> item,
    double fallbackPrice,
  ) {
    final source = _variantListSource(item);
    if (source == null || source.isEmpty) {
      return const [];
    }

    final variants = <MenuItemVariant>[];
    for (var index = 0; index < source.length; index++) {
      final rawVariant = source[index];
      if (rawVariant is! Map) {
        continue;
      }
      final variant = Map<String, dynamic>.from(rawVariant);
      final name = _firstVariantText(variant, const [
        'name',
        'title',
        'label',
        'size',
        'size_name',
        'weight',
        'weight_label',
      ]);
      if (name == null || name.isEmpty) {
        continue;
      }

      final price = _variantPriceOf(variant, fallbackPrice);
      variants.add(
        MenuItemVariant(
          id: _variantIdOf(variant, index, name, price),
          name: name,
          price: price,
        ),
      );
    }
    return variants;
  }

  String _variantNamesForLog(List<MenuItemVariant> variants) {
    return variants.map((variant) => variant.name).join(', ');
  }

  List<dynamic>? _variantListSource(Map<String, dynamic> item) {
    for (final key in const [
      'variants',
      'item_variants',
      'itemVariants',
      'sizes',
      'weights',
      'options',
    ]) {
      final value = item[key];
      if (value is List && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  String? _firstVariantText(
    Map<String, dynamic> variant,
    List<String> keys,
  ) {
    for (final key in keys) {
      final text = variant[key]?.toString().trim();
      if (text != null && text.isNotEmpty && text.toLowerCase() != 'null') {
        return text;
      }
    }
    return null;
  }

  String _variantIdOf(
    Map<String, dynamic> variant,
    int index,
    String name,
    double price,
  ) {
    final explicitId = _firstVariantText(
      variant,
      const ['id', 'variant_id', 'variantId'],
    );
    if (explicitId != null && explicitId.isNotEmpty) {
      return explicitId;
    }
    return '${index}_${name}_${price.toStringAsFixed(2)}';
  }

  double _variantPriceOf(
    Map<String, dynamic> variant,
    double fallbackPrice,
  ) {
    for (final key in const [
      'price',
      'unit_price',
      'amount',
      'value',
    ]) {
      final price = _priceOf(variant[key]);
      if (price > 0) {
        return price;
      }
    }

    final priceDelta = _priceOf(
      variant['price_delta'] ?? variant['priceDelta'],
    );
    if (priceDelta != 0) {
      return fallbackPrice + priceDelta;
    }
    return fallbackPrice;
  }

  String _sanitizeItemName(String rawValue) {
    final normalized = rawValue.trim();
    if (normalized.isEmpty) {
      return context.tr('menu.default_item');
    }

    final lower = normalized.toLowerCase();
    const blockedPatterns = [
      'violates',
      'foreign key',
      'constraint',
      'postgrest',
      'error:',
      'syntax error',
    ];
    if (blockedPatterns.any(lower.contains)) {
      return context.tr('menu.default_item');
    }
    return normalized;
  }

  String _sanitizeImageUrl(String rawValue) {
    final normalized = rawValue.trim();
    if (normalized.isEmpty) {
      return '';
    }

    final lower = normalized.toLowerCase();
    const blockedPatterns = [
      'violates',
      'foreign key',
      'constraint',
      'postgrest',
      'error:',
      'syntax error',
      'cannot coerce',
      'null)',
    ];
    if (blockedPatterns.any(lower.contains)) {
      return '';
    }

    final parsed = Uri.tryParse(normalized);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return '';
    }
    return normalized;
  }

  Future<void> _openCart(CartController cart) async {
    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
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

  Future<void> _handleAddItem({
    required CartController cart,
    required String itemId,
    required String itemName,
    required double price,
    required String imageUrl,
    MenuItemVariant? variant,
  }) async {
    if (cart.isLocked) {
      _showLockedCartNotice();
      return;
    }
    if (itemId.trim().isEmpty) {
      return;
    }

    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    cart.addItem(
      id: itemId,
      name: itemName,
      price: price,
      image: imageUrl,
      restaurantId: widget.restaurantId,
      variantId: variant?.id,
      variantName: variant?.name,
      variantPrice: variant?.price,
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
          const SizedBox(width: 12),
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
                              textAlign: Directionality.of(context) ==
                                      TextDirection.rtl
                                  ? TextAlign.right
                                  : TextAlign.left,
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
                      height: 34,
                      child: ListView.separated(
                        physics: AppTheme.bouncingScrollPhysics,
                        scrollDirection: Axis.horizontal,
                        padding: EdgeInsets.zero,
                        itemCount: categories.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 5),
                        itemBuilder: (_, index) {
                          final category = categories[index];
                          final categoryId = category['id']?.toString();
                          final selected = categoryId == selectedCategoryId;
                          final categoryName =
                              (category['name'] ?? '').toString().trim();

                          return Padding(
                            padding: EdgeInsetsDirectional.only(
                              start: index == 0 ? 1 : 0,
                              end: index == categories.length - 1 ? 1 : 0,
                            ),
                            child: _MenuCategoryCard(
                              label:
                                  categoryName.isEmpty ? '...' : categoryName,
                              selected: selected,
                              onTap: () {
                                if (categoryId == null ||
                                    categoryId == selectedCategoryId) {
                                  return;
                                }

                                setState(() {
                                  selectedCategoryId = categoryId;
                                });
                                unawaited(_loadItems());
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final crossAxisCount =
                            _getCrossAxisCount(constraints.maxWidth);

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
                          cacheExtent: constraints.maxHeight + 240,
                          padding: const EdgeInsets.only(bottom: 4),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio:
                                _itemAspectRatioFor(crossAxisCount),
                          ),
                          itemCount: items.length,
                          itemBuilder: (_, index) {
                            final item = items[index];
                            final itemId = (item['id'] ?? '').toString();
                            final itemName = _sanitizeItemName(
                                (item['name'] ?? '').toString());
                            final imageUrl = _sanitizeImageUrl(
                              (item['image_url'] ?? '').toString(),
                            );
                            final price = _priceOf(item['price']);
                            final variants = _variantsOf(item, price);
                            debugPrint(
                              '[RestaurantMenuPage.itemBuilder] item_id=$itemId '
                              'item_name=$itemName variants_length=${variants.length} '
                              'variant_names=[${_variantNamesForLog(variants)}]',
                            );
                            final initialVariant =
                                variants.isEmpty ? null : variants.first;

                            return RepaintBoundary(
                              child: ItemCard(
                                key: ValueKey('menu-item-card-$itemId'),
                                itemId: itemId,
                                name: itemName,
                                basePrice: price,
                                imageUrl: imageUrl,
                                variants: variants,
                                initialSelectedVariant: initialVariant,
                                onAdd: (selectedVariant) {
                                  final selectedPrice =
                                      selectedVariant?.price ?? price;
                                  unawaited(
                                    _handleAddItem(
                                      cart: cart,
                                      itemId: itemId,
                                      itemName: itemName,
                                      price: selectedPrice,
                                      imageUrl: imageUrl,
                                      variant: selectedVariant,
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
    );
  }
}

class _MenuCategoryCard extends StatelessWidget {
  const _MenuCategoryCard({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(13.5);
    final textColor = selected ? Colors.white : AppTheme.text;
    final horizontalPadding = selected ? 10.2 : 9.2;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 210),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: selected
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF39538),
                  Color(0xFFE07712),
                ],
              )
            : null,
        color: selected ? null : Colors.white,
        border: Border.all(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.95)
              : const Color(0xFFE9E2D8),
          width: selected ? 1.0 : 0.95,
        ),
        boxShadow: [
          BoxShadow(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.21)
                : const Color(0x14000000),
            blurRadius: selected ? 8 : 5,
            offset: Offset(0, selected ? 4 : 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: borderRadius,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: selected ? 3.8 : 3.5,
            ),
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                color: textColor,
                fontSize: 10.6,
                fontWeight: FontWeight.w800,
                height: 1.05,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 112),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
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
    const buttonExtent = 50.0;
    const buttonRadius = 16.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Tooltip(
          message: context.tr('cart.title'),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white, Color(0xFFF8F7F4)],
              ),
              borderRadius: BorderRadius.circular(buttonRadius),
              border: Border.all(
                color: AppTheme.border.withValues(alpha: 0.95),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.11),
                  blurRadius: 14,
                  offset: const Offset(0, 8),
                ),
                const BoxShadow(
                  color: Color(0x10000000),
                  blurRadius: 8,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(buttonRadius),
              child: InkWell(
                borderRadius: BorderRadius.circular(buttonRadius),
                onTap: onPressed,
                child: const SizedBox(
                  width: buttonExtent,
                  height: buttonExtent,
                  child: Icon(
                    Icons.shopping_bag_outlined,
                    size: 26,
                    color: AppTheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (cartCount > 0)
          PositionedDirectional(
            end: -3,
            top: -3,
            child: Container(
              height: 18,
              constraints: const BoxConstraints(minWidth: 18),
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
                  fontSize: 10,
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

class MenuItemVariant {
  const MenuItemVariant({
    required this.id,
    required this.name,
    required this.price,
  });

  final String id;
  final String name;
  final double price;
}

String _localizedMenuCurrency(BuildContext context, double value) {
  final normalized =
      value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  return context.tr('common.currency', args: {'value': normalized});
}

class ItemCard extends StatefulWidget {
  final String itemId;
  final String name;
  final double basePrice;
  final String imageUrl;
  final List<MenuItemVariant> variants;
  final MenuItemVariant? initialSelectedVariant;
  final ValueChanged<MenuItemVariant?> onAdd;

  const ItemCard({
    super.key,
    required this.itemId,
    required this.name,
    required this.basePrice,
    required this.imageUrl,
    this.variants = const <MenuItemVariant>[],
    this.initialSelectedVariant,
    required this.onAdd,
  });

  @override
  State<ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<ItemCard> {
  bool _pressed = false;
  Timer? _pressResetTimer;
  MenuItemVariant? _selectedVariant;

  @override
  void initState() {
    super.initState();
    _selectedVariant = _resolveSelectedVariant(widget.initialSelectedVariant);
  }

  @override
  void didUpdateWidget(covariant ItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!_sameVariants(oldWidget.variants, widget.variants)) {
      _selectedVariant = _resolveSelectedVariant(_selectedVariant);
    }
  }

  MenuItemVariant? get _effectiveVariant {
    return _resolveSelectedVariant(_selectedVariant);
  }

  MenuItemVariant? _resolveSelectedVariant(MenuItemVariant? preferred) {
    if (widget.variants.isEmpty) {
      return null;
    }

    final preferredId = preferred?.id.trim();
    if (preferredId != null && preferredId.isNotEmpty) {
      for (final variant in widget.variants) {
        if (variant.id == preferredId) {
          return variant;
        }
      }
    }
    return widget.variants.first;
  }

  bool _sameVariants(
    List<MenuItemVariant> previous,
    List<MenuItemVariant> next,
  ) {
    if (previous.length != next.length) {
      return false;
    }
    for (var index = 0; index < previous.length; index++) {
      final previousVariant = previous[index];
      final nextVariant = next[index];
      if (previousVariant.id != nextVariant.id ||
          previousVariant.name != nextVariant.name ||
          previousVariant.price != nextVariant.price) {
        return false;
      }
    }
    return true;
  }

  void _selectVariant(MenuItemVariant variant) {
    if (_selectedVariant?.id == variant.id) {
      return;
    }

    setState(() => _selectedVariant = variant);
  }

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

    widget.onAdd(_effectiveVariant);
  }

  @override
  void dispose() {
    _pressResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth < 170 || constraints.maxHeight < 172;
        final ultraCompact =
            constraints.maxWidth < 148 || constraints.maxHeight < 152;
        final radius = compact ? 14.0 : 16.0;
        final badgeHeight = compact ? 17.0 : 18.5;
        final badgeFontSize = compact ? 9.2 : 9.8;
        final addButtonExtent = ultraCompact
            ? 44.0
            : compact
                ? 45.0
                : 46.0;
        final addIconSize = ultraCompact
            ? 22.0
            : compact
                ? 23.0
                : 24.0;
        final addRingWidth = ultraCompact ? 1.0 : 1.15;
        final contentPadding = EdgeInsetsDirectional.fromSTEB(
          compact ? 8 : 9,
          compact ? 5 : 6,
          compact ? 8 : 9,
          compact ? 6 : 7,
        );
        final itemNameFont = compact ? 11.1 : 12.0;
        final itemPriceFont = compact ? 10.9 : 11.7;
        final imageFlex = compact ? 12 : 13;
        final addSemanticLabel = Directionality.of(context) == TextDirection.rtl
            ? 'إضافة إلى السلة'
            : 'Add to cart';
        final selectedVariant = _effectiveVariant;
        final selectedPrice = selectedVariant?.price ?? widget.basePrice;
        final quantity = CartProvider.maybeOf(context)?.getQuantity(
              widget.itemId,
              variantId: selectedVariant?.id,
            ) ??
            0;

        return AnimatedScale(
          scale: _pressed && !kIsWeb ? 0.972 : 1,
          duration: kIsWeb ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutBack,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              color: Colors.white,
              border: Border.all(
                color: const Color(0xFFEDE5DA),
              ),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 10,
                  color: Color(0x12000000),
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: imageFlex,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(radius),
                          ),
                          child: widget.imageUrl.isEmpty
                              ? const ImageFallback(
                                  icon: Icons.fastfood_rounded,
                                  iconSize: 30,
                                )
                              : AppCachedImage(
                                  imageUrl: widget.imageUrl,
                                  fit: BoxFit.cover,
                                  placeholder:
                                      const _MenuItemImagePlaceholder(),
                                  errorWidget: const ImageFallback(
                                    icon: Icons.fastfood_rounded,
                                    iconSize: 30,
                                  ),
                                ),
                        ),
                      ),
                      if (quantity > 0)
                        Positioned(
                          top: compact ? 4 : 6,
                          left: compact ? 4 : 6,
                          child: Container(
                            height: badgeHeight,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.74),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              quantity.toString(),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: badgeFontSize,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      if (widget.variants.length > 1)
                        Positioned(
                          top: compact ? 4 : 6,
                          right: compact ? 4 : 6,
                          child: _VariantMenuAnchor(
                            variants: widget.variants,
                            selectedVariant:
                                selectedVariant ?? widget.variants.first,
                            compact: compact,
                            onSelected: _selectVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: contentPadding,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: itemNameFont,
                                height: 1.14,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _localizedMenuCurrency(context, selectedPrice),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.primaryDeep,
                                fontWeight: FontWeight.w900,
                                fontSize: itemPriceFont,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: compact ? 5 : 6),
                      Semantics(
                        button: true,
                        label: addSemanticLabel,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFFFB96A),
                                Color(0xFFD65E00),
                              ],
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.98),
                              width: addRingWidth,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.primary.withValues(alpha: 0.34),
                                blurRadius: compact ? 9 : 11,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: InkResponse(
                              key: const Key('menu-item-add-button'),
                              onTap: _animateAdd,
                              containedInkWell: true,
                              customBorder: const CircleBorder(),
                              radius: addButtonExtent * 0.58,
                              child: SizedBox.square(
                                dimension: addButtonExtent,
                                child: Icon(
                                  Icons.add_rounded,
                                  color: Colors.white,
                                  size: addIconSize,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VariantMenuAnchor extends StatelessWidget {
  const _VariantMenuAnchor({
    required this.variants,
    required this.selectedVariant,
    required this.compact,
    required this.onSelected,
  });

  final List<MenuItemVariant> variants;
  final MenuItemVariant selectedVariant;
  final bool compact;
  final ValueChanged<MenuItemVariant> onSelected;

  @override
  Widget build(BuildContext context) {
    final menuWidth = compact ? 162.0 : 178.0;

    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      clipBehavior: Clip.antiAlias,
      style: MenuStyle(
        alignment: AlignmentDirectional.topEnd,
        backgroundColor: const WidgetStatePropertyAll<Color>(Colors.white),
        surfaceTintColor:
            const WidgetStatePropertyAll<Color>(Colors.transparent),
        shadowColor: const WidgetStatePropertyAll<Color>(Color(0x33000000)),
        elevation: const WidgetStatePropertyAll<double>(8),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(vertical: 4),
        ),
        minimumSize: WidgetStatePropertyAll<Size>(Size(menuWidth, 0)),
        maximumSize: WidgetStatePropertyAll<Size>(
          Size(menuWidth, compact ? 188 : 220),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFEDE5DA)),
          ),
        ),
      ),
      menuChildren: [
        for (final variant in variants)
          _VariantMenuItem(
            variant: variant,
            selected: variant.id == selectedVariant.id,
            compact: compact,
            width: menuWidth,
            onSelected: onSelected,
          ),
      ],
      builder: (context, controller, child) {
        return _VariantOverlayButton(
          label: selectedVariant.name,
          compact: compact,
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
        );
      },
    );
  }
}

class _VariantMenuItem extends StatelessWidget {
  const _VariantMenuItem({
    required this.variant,
    required this.selected,
    required this.compact,
    required this.width,
    required this.onSelected,
  });

  final MenuItemVariant variant;
  final bool selected;
  final bool compact;
  final double width;
  final ValueChanged<MenuItemVariant> onSelected;

  @override
  Widget build(BuildContext context) {
    final rowHeight = compact ? 34.0 : 38.0;

    return MenuItemButton(
      closeOnActivate: true,
      onPressed: () => onSelected(variant),
      style: ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        minimumSize: WidgetStatePropertyAll<Size>(Size(width, rowHeight)),
        maximumSize: WidgetStatePropertyAll<Size>(Size(width, rowHeight)),
        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsetsDirectional.symmetric(horizontal: compact ? 8 : 10),
        ),
        backgroundColor: WidgetStatePropertyAll<Color>(
          selected ? const Color(0xFFFFF6EE) : Colors.white,
        ),
        overlayColor: WidgetStatePropertyAll<Color>(
          AppTheme.primary.withValues(alpha: 0.08),
        ),
        foregroundColor: const WidgetStatePropertyAll<Color>(AppTheme.text),
      ),
      child: SizedBox(
        width: width - (compact ? 16 : 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? AppTheme.primary : const Color(0xFF98A2B3),
              size: compact ? 15 : 16,
            ),
            SizedBox(width: compact ? 5 : 6),
            Expanded(
              child: Text(
                variant.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.start,
                style: TextStyle(
                  color: AppTheme.text,
                  fontSize: compact ? 10.6 : 11.2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(width: compact ? 6 : 8),
            Text(
              _localizedMenuCurrency(context, variant.price),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color:
                    selected ? AppTheme.primaryDeep : const Color(0xFF667085),
                fontSize: compact ? 10.2 : 10.8,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VariantOverlayButton extends StatelessWidget {
  const _VariantOverlayButton({
    required this.label,
    required this.compact,
    required this.onTap,
  });

  final String label;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final height = compact ? 22.0 : 24.0;
    final fontSize = compact ? 10.0 : 10.6;

    return Material(
      color: Colors.black.withValues(alpha: 0.58),
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          constraints: BoxConstraints(
            minWidth: compact ? 46 : 52,
            maxWidth: compact ? 82 : 96,
          ),
          padding: EdgeInsetsDirectional.only(
            start: compact ? 7 : 8,
            end: compact ? 5 : 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: fontSize,
                    height: 1,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white,
                size: compact ? 14 : 15,
              ),
            ],
          ),
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
            padding: EdgeInsets.fromLTRB(8, 6, 8, 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MenuTextSkeleton(width: 92),
                SizedBox(height: 4),
                Row(
                  children: [
                    _MenuTextSkeleton(width: 62),
                    Spacer(),
                    CircleAvatar(
                      radius: 16,
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
