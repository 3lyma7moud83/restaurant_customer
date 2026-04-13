import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../cart/cart_provider.dart';
import '../cart/cart_page.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
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
  List<Map<String, dynamic>> categories = [];
  List<Map<String, dynamic>> items = [];

  String? selectedCategoryId;
  bool loading = true;
  int _itemsRequestId = 0;

  ////////////////////////////////////////////////////////////
  /// INIT
  ////////////////////////////////////////////////////////////

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  ////////////////////////////////////////////////////////////
  /// RESPONSIVE GRID
  ////////////////////////////////////////////////////////////

  int _getCrossAxisCount(double width) {
    if (width < 360) return 1;
    if (width < 720) return 2;
    if (width < 1024) return 3;
    if (width < 1360) return 4;
    return 5;
  }

  ////////////////////////////////////////////////////////////
  /// LOAD DATA
  ////////////////////////////////////////////////////////////

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
        loading = false;
        setState(() {});
      }
    }
  }

  void _showLockedCartNotice() {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('لديك طلب جاري. تابع الطلب الحالي قبل إضافة طلب جديد.'),
      ),
    );
  }

  Future<void> _loadItems() async {
    if (selectedCategoryId == null) return;

    final requestId = ++_itemsRequestId;
    try {
      final res = await ItemsService.fetchByCategory(
        categoryId: selectedCategoryId!,
      );

      if (!mounted || requestId != _itemsRequestId) return;
      items = res;
      setState(() {});
    } catch (_) {
      if (!mounted || requestId != _itemsRequestId) return;
      items = const [];
      setState(() {});
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

  ////////////////////////////////////////////////////////////
  /// UI
  ////////////////////////////////////////////////////////////

  @override
  Widget build(BuildContext context) {
    final cart = CartProvider.of(context);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,

      ////////////////////////////////////////////////////////////
      /// APP BAR
      ////////////////////////////////////////////////////////////

      appBar: AppBar(
        title: Text(widget.restaurantName),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.shopping_cart),

                /// ✅ السلة تاخد نفس المطعم
                onPressed: () {
                  Navigator.push(
                    context,
                    AppTheme.platformPageRoute(
                      builder: (_) => CartPage(
                        restaurantId: widget.restaurantId,
                      ),
                    ),
                  );
                },
              ),
              if (cart.totalCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: CircleAvatar(
                    radius: 9,
                    backgroundColor: AppTheme.primary,
                    child: Text(
                      cart.totalCount.toString(),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),

      ////////////////////////////////////////////////////////////
      /// BODY
      ////////////////////////////////////////////////////////////

      body: loading
          ? const _MenuLoadingSkeleton()
          : Column(
              children: [
                if (cart.isLocked)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF4E6D9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            Navigator.push(
                              context,
                              AppTheme.platformPageRoute(
                                builder: (_) => CartPage(
                                  restaurantId: widget.restaurantId,
                                ),
                              ),
                            );
                          },
                          child: const Text('فتح السلة'),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'السلة مرتبطة بطلب جاري حتى يكتمل أو يتم رفضه.',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: AppTheme.text,
                              fontWeight: FontWeight.w700,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ////////////////////////////////////////////////////////////
                /// CATEGORIES
                ////////////////////////////////////////////////////////////

                if (categories.isNotEmpty)
                  SizedBox(
                    height: 56,
                    child: ListView.builder(
                      physics: AppTheme.bouncingScrollPhysics,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: categories.length,
                      itemBuilder: (_, i) {
                        final c = categories[i];
                        final categoryId = c['id']?.toString();
                        final selected = categoryId == selectedCategoryId;

                        return GestureDetector(
                          onTap: () async {
                            selectedCategoryId = categoryId;
                            setState(() {});
                            await _loadItems();
                          },
                          child: AnimatedContainer(
                            duration: kIsWeb
                                ? Duration.zero
                                : const Duration(milliseconds: 200),
                            margin: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 10,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppTheme.primary
                                  : const Color(0xFFF0E6DC),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              (c['name'] ?? '').toString(),
                              style: TextStyle(
                                color: selected ? Colors.white : Colors.black87,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                ////////////////////////////////////////////////////////////
                /// ITEMS
                ////////////////////////////////////////////////////////////

                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount =
                          _getCrossAxisCount(constraints.maxWidth);

                      if (selectedCategoryId == null) {
                        return const Center(
                          child: Text(
                            'اختار نوع الأول',
                            style: TextStyle(color: Color(0xFF667085)),
                          ),
                        );
                      }

                      if (items.isEmpty) {
                        return const Center(
                          child: Text(
                            'لا توجد أصناف هنا',
                            style: TextStyle(color: Color(0xFF667085)),
                          ),
                        );
                      }

                      return GridView.builder(
                        padding: const EdgeInsets.all(16),
                        physics: AppTheme.bouncingScrollPhysics,
                        cacheExtent: 480,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          childAspectRatio: 0.9,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                        itemCount: items.length,
                        itemBuilder: (_, i) {
                          final item = items[i];
                          final itemId = (item['id'] ?? '').toString();
                          final itemName = (item['name'] ?? '').toString();
                          final imageUrl = (item['image_url'] ?? '').toString();
                          final price = _priceOf(item['price']);

                          return ItemCard(
                            name: itemName.isEmpty ? 'صنف' : itemName,
                            price: price,
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
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

//////////////////////////////////////////////////////////////////
// ITEM CARD
//////////////////////////////////////////////////////////////////

class ItemCard extends StatefulWidget {
  final String name;
  final double price;
  final String imageUrl;
  final int quantity;
  final VoidCallback onAdd;

  const ItemCard({
    super.key,
    required this.name,
    required this.price,
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

  @override
  void initState() {
    super.initState();
  }

  void _animateAdd() {
    if (!mounted) {
      return;
    }
    setState(() => _pressed = true);
    _pressResetTimer?.cancel();
    _pressResetTimer = Timer(
      kIsWeb ? Duration.zero : const Duration(milliseconds: 140),
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
      scale: _pressed && !kIsWeb ? 0.95 : 1,
      duration: kIsWeb ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white,
          boxShadow: const [
            BoxShadow(
              blurRadius: 8,
              color: Colors.black12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: widget.imageUrl.isEmpty
                      ? const Icon(Icons.fastfood, size: 40)
                      : AppCachedImage(
                          imageUrl: widget.imageUrl,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(18),
                          ),
                          placeholder: const _MenuItemImagePlaceholder(),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Text(
                        widget.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.price} جنيه',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            /// زرار الإضافة
            Positioned(
              top: 8,
              right: 8,
              child: GestureDetector(
                onTap: _animateAdd,
                child: const CircleAvatar(
                  backgroundColor: AppTheme.primary,
                  radius: 16,
                  child: Icon(Icons.add, color: Colors.white, size: 18),
                ),
              ),
            ),

            /// الكمية
            if (widget.quantity > 0)
              Positioned(
                top: 8,
                left: 8,
                child: CircleAvatar(
                  radius: 10,
                  backgroundColor: Colors.black,
                  child: Text(
                    widget.quantity.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuLoadingSkeleton extends StatelessWidget {
  const _MenuLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width < 360
            ? 1
            : width < 720
                ? 2
                : width < 1024
                    ? 3
                    : width < 1360
                        ? 4
                        : 5;

        return GridView.builder(
          padding: const EdgeInsets.all(16),
          physics: const NeverScrollableScrollPhysics(),
          itemCount: crossAxisCount * 2,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.9,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
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
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white,
        boxShadow: const [
          BoxShadow(
            blurRadius: 8,
            color: Colors.black12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: const Column(
        children: [
          Expanded(child: _MenuItemImagePlaceholder()),
          Padding(
            padding: EdgeInsets.all(10),
            child: Column(
              children: [
                _MenuTextSkeleton(width: 88),
                SizedBox(height: 8),
                _MenuTextSkeleton(width: 64),
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
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
          strokeWidth: 2.5,
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
