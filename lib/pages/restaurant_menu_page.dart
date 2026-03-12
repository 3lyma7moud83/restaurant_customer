import 'package:flutter/material.dart';

import '../cart/cart_provider.dart';
import '../cart/cart_page.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../services/categories_service.dart';
import '../services/items_service.dart';

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

class _RestaurantMenuPageState extends State<RestaurantMenuPage>
    with SingleTickerProviderStateMixin {
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

  int _getCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;

    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    return 5;
  }

  ////////////////////////////////////////////////////////////
  /// LOAD DATA
  ////////////////////////////////////////////////////////////

  Future<void> _loadCategories() async {
    try {
      categories = await CategoriesService.getByManager(widget.managerId);
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
                    MaterialPageRoute(
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
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            )
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
                              MaterialPageRoute(
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
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: categories.length,
                      itemBuilder: (_, i) {
                        final c = categories[i];
                        final selected = c['id'] == selectedCategoryId;

                        return GestureDetector(
                          onTap: () async {
                            selectedCategoryId = c['id'];
                            setState(() {});
                            await _loadItems();
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
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
                              c['name'],
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
                  child: selectedCategoryId == null
                      ? const Center(
                          child: Text(
                            'اختار نوع الأول',
                            style: TextStyle(color: Color(0xFF667085)),
                          ),
                        )
                      : items.isEmpty
                          ? const Center(
                              child: Text(
                                'لا توجد أصناف هنا',
                                style: TextStyle(color: Color(0xFF667085)),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.all(16),
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: _getCrossAxisCount(context),
                                childAspectRatio: 0.9,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                              ),
                              itemCount: items.length,
                              itemBuilder: (_, i) {
                                final item = items[i];

                                return ItemCard(
                                  name: item['name'],
                                  price: item['price'].toDouble(),
                                  imageUrl: item['image_url'] ?? '',
                                  quantity: cart.getQuantity(item['id']),
                                  onAdd: () {
                                    if (cart.isLocked) {
                                      _showLockedCartNotice();
                                      return;
                                    }
                                    cart.addItem(
                                      id: item['id'],
                                      name: item['name'],
                                      price: item['price'].toDouble(),
                                      image: item['image_url'] ?? '',
                                      restaurantId: widget.restaurantId,
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

class _ItemCardState extends State<ItemCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
      lowerBound: 0.95,
      upperBound: 1,
    )..value = 1;
  }

  void _animateAdd() {
    _controller.reverse().then((_) => _controller.forward());
    widget.onAdd();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _controller,
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
                      : ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(18),
                          ),
                          child: Image.network(
                            widget.imageUrl,
                            fit: BoxFit.cover,
                            width: double.infinity,
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Text(widget.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        '${widget.price} جنيه',
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
