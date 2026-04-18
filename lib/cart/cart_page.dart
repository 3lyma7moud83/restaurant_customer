import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/localization/app_localizations.dart';
import '../core/services/error_logger.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/responsive.dart';
import '../pages/order_details_page.dart';
import '../pages/order_tracking_page.dart';
import '../services/orders_service.dart';
import '../services/profile_service.dart';
import '../services/session_manager.dart';
import 'cart_provider.dart';
import 'select_address_page.dart';

String localizedCurrency(BuildContext context, double value) {
  final normalized =
      value % 1 == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(2);
  return context.tr('common.currency', args: {'value': normalized});
}

class CartPage extends StatefulWidget {
  const CartPage({
    super.key,
    required this.restaurantId,
  });

  final String restaurantId;

  @override
  State<CartPage> createState() => _CartPageState();
}

class _CartPageState extends State<CartPage> {
  final supabase = Supabase.instance.client;
  final ProfileService _profileService = ProfileService();
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final addressCtrl = TextEditingController();
  final houseNumberCtrl = TextEditingController();

  bool _contentVisible = kIsWeb;

  bool loadingProfile = true;
  bool creatingOrder = false;
  bool _didSyncAddress = false;
  bool _didSyncHouseNumber = false;
  String? _loadedActiveOrderId;
  Map<String, dynamic>? _activeOrder;

  @override
  void initState() {
    super.initState();
    addressCtrl.addListener(_handleAddressChanged);
    houseNumberCtrl.addListener(_handleHouseNumberChanged);
    unawaited(_loadProfile());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cart = CartProvider.of(context);

    final deliveryAddress = cart.deliveryAddress ?? '';
    if (!_didSyncAddress || addressCtrl.text != deliveryAddress) {
      _didSyncAddress = true;
      _setControllerValue(addressCtrl, deliveryAddress);
    }

    if (!_didSyncHouseNumber || houseNumberCtrl.text != cart.houseNumber) {
      _didSyncHouseNumber = true;
      _setControllerValue(houseNumberCtrl, cart.houseNumber);
    }

    final activeOrderId = cart.activeOrderId;
    if (_loadedActiveOrderId != activeOrderId) {
      _loadedActiveOrderId = activeOrderId;
      unawaited(_loadActiveOrder(cart));
    }
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    addressCtrl.dispose();
    houseNumberCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await _profileService.getOrCreateProfile();
      if (!mounted) {
        return;
      }

      _setControllerValue(nameCtrl, (profile['name'] ?? '').toString());
      _setControllerValue(phoneCtrl, (profile['phone'] ?? '').toString());
    } catch (_) {
      if (mounted) {
        _showSnack(context.tr('cart.profile_load_error'));
      }
    } finally {
      if (mounted) {
        setState(() {
          loadingProfile = false;
          _contentVisible = true;
        });
      }
    }
  }

  Future<void> _loadActiveOrder(CartController cart) async {
    await cart.refreshActiveOrderStatus();
    if (!mounted) {
      return;
    }

    final activeOrderId = cart.activeOrderId;
    if (activeOrderId == null || activeOrderId.isEmpty) {
      setState(() => _activeOrder = null);
      return;
    }

    try {
      final order = await OrdersService.getOrderById(activeOrderId);
      if (!mounted) {
        return;
      }

      if (order == null) {
        setState(() => _activeOrder = null);
        return;
      }

      cart.syncOrderStatusFromRow(order);
      if (!mounted || !cart.isLocked) {
        setState(() => _activeOrder = null);
        return;
      }

      setState(() => _activeOrder = order);
    } catch (_) {
      if (mounted) {
        setState(() => _activeOrder = null);
      }
    }
  }

  void _handleHouseNumberChanged() {
    final cart = CartProvider.maybeOf(context);
    if (cart == null) {
      return;
    }

    final currentValue = houseNumberCtrl.text.trim();
    if (currentValue != cart.houseNumber) {
      cart.setHouseNumber(currentValue);
    }
  }

  void _handleAddressChanged() {
    final cart = CartProvider.maybeOf(context);
    if (cart == null || cart.isLocked) {
      return;
    }

    final currentValue = addressCtrl.text.trim();
    if (currentValue != (cart.deliveryAddress ?? '')) {
      cart.setDeliveryAddress(currentValue);
    }
  }

  Future<void> _openLocationPicker(CartController cart) async {
    if (cart.isLocked) {
      return;
    }

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SelectAddressPage(
        initialLat: cart.deliveryLat,
        initialLng: cart.deliveryLng,
        initialAddress: cart.deliveryAddress,
        initialHouseNumber: cart.houseNumber,
        initialCustomerName: nameCtrl.text,
        initialCustomerPhone: phoneCtrl.text,
      ),
    );

    if (result == null || !mounted) {
      return;
    }

    final lat = (result['lat'] as num?)?.toDouble();
    final lng = (result['lng'] as num?)?.toDouble();
    final fullAddress =
        (result['address'] ?? result['fullAddress'] ?? '').toString().trim();
    final houseNumber = (result['house_number'] ?? result['houseNumber'] ?? '')
        .toString()
        .trim();
    final customerName = (result['customerName'] ?? '').toString().trim();
    final customerPhone = (result['customerPhone'] ?? '').toString().trim();

    if (lat == null || lng == null) {
      _showSnack(context.tr('cart.location_pick_error'));
      return;
    }

    if (fullAddress.isEmpty) {
      _showSnack(context.tr('cart.address_required'));
      return;
    }

    cart.setDeliveryLocation(
      address: fullAddress,
      lat: lat,
      lng: lng,
      houseNumber: houseNumber,
    );
    if (customerName.isNotEmpty) {
      _setControllerValue(nameCtrl, customerName);
    }
    if (customerPhone.isNotEmpty) {
      _setControllerValue(phoneCtrl, customerPhone);
    }
    _setControllerValue(addressCtrl, fullAddress);
    _setControllerValue(houseNumberCtrl, houseNumber);
    await _calculateDeliveryFromServer(cart);
  }

  Future<void> _calculateDeliveryFromServer(CartController cart) async {
    if (!cart.hasLocation || cart.isLocked) {
      return;
    }

    try {
      final response =
          await SessionManager.instance.runWithValidSession<dynamic>(
        () => supabase.rpc(
          'estimate_delivery_cost',
          params: {
            'p_restaurant_id': widget.restaurantId,
            'p_customer_lat': cart.deliveryLat,
            'p_customer_lng': cart.deliveryLng,
          },
        ),
      );

      if (response == null) {
        cart.updateDeliveryCost(0);
        return;
      }

      final cost = response is Map
          ? (response['delivery_cost'] as num?)?.toDouble() ?? 0.0
          : 0.0;
      cart.updateDeliveryCost(cost);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_page.calculateDeliveryFromServer',
        error: error,
        stack: stack,
      );
      cart.updateDeliveryCost(0);
    }
  }

  Future<void> _createOrder(CartController cart) async {
    if (creatingOrder) {
      return;
    }

    if (cart.isLocked) {
      _openCurrentOrder();
      return;
    }

    if (cart.items.isEmpty) {
      _showSnack(context.tr('cart.empty'));
      return;
    }

    if (!cart.hasLocation ||
        cart.deliveryAddress == null ||
        cart.deliveryAddress!.trim().isEmpty) {
      _showSnack(context.tr('cart.pick_location_first'));
      return;
    }

    if (cart.selectedPaymentMethod == null) {
      _showSnack(context.tr('cart.select_payment_first'));
      return;
    }

    final hasCustomerIdentity = await _ensureCustomerIdentity();
    if (!hasCustomerIdentity) {
      return;
    }

    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    final user = session?.user;
    if (user == null) {
      return;
    }

    final fullAddress = OrdersService.composeDeliveryAddress(
      address: cart.deliveryAddress!,
      houseNumber: houseNumberCtrl.text,
    );

    setState(() => creatingOrder = true);

    try {
      final orderId = await OrdersService.createOrder(
        CreateOrderInput(
          userId: user.id,
          restaurantId: widget.restaurantId,
          customerName: nameCtrl.text.trim(),
          customerPhone: phoneCtrl.text.trim(),
          address: fullAddress,
          customerLat: cart.deliveryLat!,
          customerLng: cart.deliveryLng!,
          totalPrice: cart.totalPrice + cart.deliveryCost,
          deliveryCost: cart.deliveryCost,
          paymentMethod: cart.selectedPaymentMethod?.value,
          items: cart.items
              .map<CreateOrderItemInput>(
                (item) => CreateOrderItemInput(
                  name: item.name,
                  price: item.price,
                  quantity: item.qty,
                ),
              )
              .toList(growable: false),
        ),
      );

      await cart.markOrderPlaced(orderId);

      if (!mounted) {
        return;
      }

      Navigator.pushReplacement(
        context,
        AppTheme.platformPageRoute(
          builder: (_) => OrderDetailsPage(orderId: orderId),
        ),
      );
    } on OrderLimitExceededException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => creatingOrder = false);
      }
    }
  }

  Future<bool> _ensureCustomerIdentity() async {
    final currentName = nameCtrl.text.trim();
    final currentPhone = phoneCtrl.text.trim();
    if (currentName.isNotEmpty && currentPhone.length >= 8) {
      return true;
    }

    final result = await showModalBottomSheet<_CustomerInfoResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _CustomerInfoSheet(
        initialName: currentName,
        initialPhone: currentPhone,
      ),
    );

    if (result == null) {
      return false;
    }

    try {
      await _profileService.updateProfile(
        name: result.name,
        phone: result.phone,
      );

      if (!mounted) {
        return false;
      }

      _setControllerValue(nameCtrl, result.name);
      _setControllerValue(phoneCtrl, result.phone);
      return true;
    } catch (_) {
      if (mounted) {
        _showSnack(context.tr('cart.profile_save_error'));
      }
      return false;
    }
  }

  void _openCurrentOrder() {
    final order = _activeOrder;
    final orderId =
        order == null ? _loadedActiveOrderId : OrdersService.idOf(order);
    if (orderId == null || orderId.isEmpty) {
      return;
    }

    final status =
        order == null ? null : resolveOrderStatus(order['status']?.toString());

    final route = AppTheme.platformPageRoute<void>(
      builder: (_) => status != null && status.canTrack
          ? OrderTrackingPage(orderId: orderId)
          : OrderDetailsPage(orderId: orderId),
    );

    Navigator.push(context, route);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _setControllerValue(
    TextEditingController controller,
    String value,
  ) {
    if (controller.text == value) {
      return;
    }

    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartProvider.of(context);
    final subtotal = cart.totalPrice;
    final total = subtotal + cart.deliveryCost;
    final hasPaymentMethod = cart.selectedPaymentMethod != null;
    final activeStatus = _activeOrder == null
        ? null
        : resolveOrderStatus(_activeOrder!['status']?.toString());

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(context.tr('cart.title'))),
      body: loadingProfile
          ? const Center(child: CircularProgressIndicator())
          : AnimatedOpacity(
              opacity: _contentVisible ? 1 : 0,
              duration:
                  kIsWeb ? Duration.zero : const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              child: AppConstrainedContent(
                child: cart.items.isEmpty && !cart.isLocked
                    ? const _CartEmptyState()
                    : ListView(
                        physics: AppTheme.bouncingScrollPhysics,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
                        children: [
                          if (cart.isLocked) ...[
                            _ActiveOrderCard(
                              order: _activeOrder,
                              onOpenOrder: _openCurrentOrder,
                              fallbackOrderId: cart.activeOrderId,
                            ),
                            const SizedBox(height: 16),
                          ],
                          _SectionCard(
                            title: context.tr('cart.items_section'),
                            child: Column(
                              children: cart.items
                                  .map(
                                    (item) => Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 12),
                                      child: _CartLineItem(item: item),
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          ),
                          const SizedBox(height: 16),
                          _SectionCard(
                            title: context.tr('cart.customer_section'),
                            child: Column(
                              children: [
                                _ReadOnlyField(
                                  label: context.tr('cart.name'),
                                  value: nameCtrl.text.trim().isEmpty
                                      ? context
                                          .tr('cart.ask_before_first_order')
                                      : nameCtrl.text.trim(),
                                ),
                                const SizedBox(height: 12),
                                _ReadOnlyField(
                                  label: context.tr('cart.phone'),
                                  value: phoneCtrl.text.trim().isEmpty
                                      ? context
                                          .tr('cart.ask_before_first_order')
                                      : phoneCtrl.text.trim(),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _SectionCard(
                            title: context.tr('cart.address_section'),
                            trailing: cart.isLocked
                                ? null
                                : TextButton.icon(
                                    onPressed: () => _openLocationPicker(cart),
                                    icon: const Icon(Icons.map_outlined,
                                        size: 18),
                                    label: Text(
                                      context.tr('cart.select_location'),
                                    ),
                                  ),
                            child: Column(
                              children: [
                                TextField(
                                  controller: addressCtrl,
                                  enabled: !cart.isLocked,
                                  textAlign: TextAlign.right,
                                  minLines: 2,
                                  maxLines: 3,
                                  decoration: InputDecoration(
                                    labelText:
                                        context.tr('cart.delivery_address'),
                                    hintText: context
                                        .tr('cart.delivery_address_hint'),
                                    prefixIcon:
                                        const Icon(Icons.location_on_outlined),
                                    suffixIcon: cart.isLocked
                                        ? null
                                        : IconButton(
                                            onPressed: () =>
                                                _openLocationPicker(cart),
                                            icon:
                                                const Icon(Icons.map_outlined),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: houseNumberCtrl,
                                  enabled: !cart.isLocked,
                                  textAlign: TextAlign.right,
                                  decoration: InputDecoration(
                                    labelText: context.tr('cart.house_number'),
                                    hintText:
                                        context.tr('cart.house_number_hint'),
                                    prefixIcon: const Icon(Icons.home_outlined),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _SectionCard(
                            title: context.tr('cart.payment_section'),
                            child: Column(
                              children: [
                                _PaymentMethodTile(
                                  title: context.tr('cart.payment_cash'),
                                  subtitle:
                                      context.tr('cart.payment_cash_subtitle'),
                                  icon: Icons.payments_outlined,
                                  selected: cart.selectedPaymentMethod ==
                                      CartPaymentMethod.cash,
                                  enabled: !cart.isLocked,
                                  onTap: () => cart
                                      .setPaymentMethod(CartPaymentMethod.cash),
                                ),
                                const SizedBox(height: 10),
                                _PaymentMethodTile(
                                  title: context.tr('cart.payment_visa'),
                                  subtitle:
                                      context.tr('cart.payment_visa_soon'),
                                  icon: Icons.credit_card_rounded,
                                  selected: false,
                                  enabled: false,
                                  tooltip: context.tr('cart.payment_visa_soon'),
                                  onTap: () {},
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          _SectionCard(
                            title: context.tr('cart.price_summary'),
                            child: Column(
                              children: [
                                _PriceRow(
                                  label: context.tr('cart.subtotal'),
                                  value: localizedCurrency(context, subtotal),
                                ),
                                const SizedBox(height: 10),
                                _PriceRow(
                                  label: context.tr('cart.delivery'),
                                  value: localizedCurrency(
                                    context,
                                    cart.deliveryCost,
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 14),
                                  child: Divider(height: 1),
                                ),
                                _PriceRow(
                                  label: context.tr('cart.total'),
                                  value: localizedCurrency(context, total),
                                  emphasized: true,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          if (!cart.hasLocation && !cart.isLocked)
                            OutlinedButton.icon(
                              onPressed: () => _openLocationPicker(cart),
                              icon: const Icon(Icons.location_on_outlined),
                              label: Text(context.tr('cart.select_on_map')),
                            ),
                          if (cart.hasLocation && !cart.isLocked)
                            ElevatedButton(
                              onPressed: creatingOrder || !hasPaymentMethod
                                  ? null
                                  : () => _createOrder(cart),
                              child: creatingOrder
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : Text(
                                      context.tr(
                                        'cart.confirm_order_total',
                                        args: {
                                          'total':
                                              localizedCurrency(context, total),
                                        },
                                      ),
                                    ),
                            ),
                          if (cart.hasLocation &&
                              !cart.isLocked &&
                              !hasPaymentMethod)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                context.tr('cart.select_payment_first'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFFB42318),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          if (cart.isLocked)
                            ElevatedButton.icon(
                              onPressed: _openCurrentOrder,
                              icon: Icon(
                                activeStatus?.canTrack == true
                                    ? Icons.navigation_outlined
                                    : Icons.receipt_long_outlined,
                              ),
                              label:
                                  Text(context.tr('cart.track_current_order')),
                            ),
                        ],
                      ),
              ),
            ),
    );
  }
}

class _CartLineItem extends StatelessWidget {
  const _CartLineItem({
    required this.item,
  });

  final CartItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F6F2),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.fastfood_rounded,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  item.name,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.qty} × ${localizedCurrency(context, item.price)}',
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            localizedCurrency(context, item.price * item.qty),
            style: const TextStyle(
              color: AppTheme.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              if (trailing != null) Flexible(child: trailing!),
              if (trailing != null) const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F6F2),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF667085),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppTheme.text,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentMethodTile extends StatelessWidget {
  const _PaymentMethodTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.tooltip,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final tile = InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.1)
              : const Color(0xFFF9F6F2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.border,
          ),
        ),
        child: Row(
          children: [
            Radio<bool>(
              value: true,
              groupValue: selected,
              onChanged: enabled ? (_) => onTap() : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: enabled ? AppTheme.text : AppTheme.textMuted,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Color(0xFF667085),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              icon,
              color: enabled ? AppTheme.primary : AppTheme.textMuted,
            ),
          ],
        ),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) {
      return tile;
    }

    return Tooltip(message: tooltip!, child: tile);
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          value,
          style: TextStyle(
            color: emphasized ? AppTheme.primary : AppTheme.text,
            fontWeight: FontWeight.w800,
            fontSize: emphasized ? 16 : 14,
          ),
        ),
        const Spacer(),
        Text(
          label,
          style: TextStyle(
            color: emphasized ? AppTheme.text : const Color(0xFF667085),
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ActiveOrderCard extends StatelessWidget {
  const _ActiveOrderCard({
    required this.order,
    required this.onOpenOrder,
    required this.fallbackOrderId,
  });

  final Map<String, dynamic>? order;
  final VoidCallback onOpenOrder;
  final String? fallbackOrderId;

  @override
  Widget build(BuildContext context) {
    final statusInfo =
        order == null ? null : resolveOrderStatus(order!['status']?.toString());
    final displayOrderId = order == null
        ? (fallbackOrderId ?? '--')
        : OrdersService.shortIdOf(order!);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFF4E6D9),
            Color(0xFFE8EFE8),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              if (statusInfo != null) OrderStatusBadge(info: statusInfo),
              const Spacer(),
              Text(
                context.tr('cart.active_order'),
                style: TextStyle(
                  color: AppTheme.text,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('cart.active_order_locked_message'),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: Color(0xFF475467),
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            context.tr('cart.order_number', args: {'id': displayOrderId}),
            style: const TextStyle(
              color: AppTheme.text,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: onOpenOrder,
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(context.tr('cart.open_order')),
          ),
        ],
      ),
    );
  }
}

class _CartEmptyState extends StatelessWidget {
  const _CartEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Icon(
                Icons.shopping_bag_outlined,
                size: 40,
                color: AppTheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              context.tr('cart.empty_title'),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr('cart.empty_subtitle'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF667085),
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomerInfoResult {
  const _CustomerInfoResult({
    required this.name,
    required this.phone,
  });

  final String name;
  final String phone;
}

class _CustomerInfoSheet extends StatefulWidget {
  const _CustomerInfoSheet({
    required this.initialName,
    required this.initialPhone,
  });

  final String initialName;
  final String initialPhone;

  @override
  State<_CustomerInfoSheet> createState() => _CustomerInfoSheetState();
}

class _CustomerInfoSheetState extends State<_CustomerInfoSheet> {
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _phoneCtrl =
      TextEditingController(text: widget.initialPhone);

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();

    if (name.isEmpty) {
      _showSnack(context.tr('cart.write_name'));
      return;
    }

    if (phone.length < 8) {
      _showSnack(context.tr('cart.invalid_phone'));
      return;
    }

    Navigator.pop(
      context,
      _CustomerInfoResult(name: name, phone: phone),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              context.tr('cart.complete_order_data'),
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr('cart.complete_order_data_subtitle'),
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Color(0xFF667085),
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _nameCtrl,
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                labelText: context.tr('cart.name'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              textAlign: TextAlign.right,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: context.tr('cart.phone'),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submit,
                child: Text(context.tr('cart.save_and_continue')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
