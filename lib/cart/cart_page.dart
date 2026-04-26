import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/localization/app_localizations.dart';
import '../core/services/error_logger.dart';
import '../core/orders/order_status_utils.dart';
import '../core/orders/order_ui.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snackbar.dart';
import '../core/ui/input_focus_guard.dart';
import '../core/ui/responsive.dart';
import '../pages/order_details_page.dart';
import '../pages/order_tracking_page.dart';
import '../services/discount_codes_service.dart';
import '../services/customer_address_service.dart';
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
  final discountCodeCtrl = TextEditingController();

  bool _contentVisible = kIsWeb;

  bool loadingProfile = true;
  bool creatingOrder = false;
  bool _applyingDiscount = false;
  bool _didSyncAddress = false;
  bool _didSyncHouseNumber = false;
  String? _loadedActiveOrderId;
  Map<String, dynamic>? _activeOrder;
  AppliedDiscountCode? _appliedDiscountCode;
  CustomerAddress? _primaryAddress;
  String? _discountFeedback;
  bool _discountFeedbackIsError = false;

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

    _syncAppliedDiscountWithCart(cart);
  }

  @override
  void dispose() {
    nameCtrl.dispose();
    phoneCtrl.dispose();
    addressCtrl.dispose();
    houseNumberCtrl.dispose();
    discountCodeCtrl.dispose();
    super.dispose();
  }

  void _syncAppliedDiscountWithCart(CartController cart) {
    final applied = _appliedDiscountCode;
    if (applied == null) {
      return;
    }

    final subtotal = cart.totalPrice;
    final isSameRestaurant = applied.restaurantId == widget.restaurantId;
    final stillValid =
        subtotal > 0 && isSameRestaurant && applied.meetsMinimum(subtotal);
    if (stillValid) {
      return;
    }

    final minOrderText = localizedCurrency(context, applied.minOrderPrice);
    setState(() {
      _appliedDiscountCode = null;
      _discountFeedback = context.tr(
        'cart.discount_removed_min_order',
        args: {'minimum': minOrderText},
      );
      _discountFeedbackIsError = true;
    });
  }

  void _clearAppliedDiscount({bool clearFeedback = false}) {
    final hadDiscount = _appliedDiscountCode != null;
    final hasFeedback = _discountFeedback != null;
    if (!hadDiscount && (!clearFeedback || !hasFeedback)) {
      return;
    }

    setState(() {
      _appliedDiscountCode = null;
      if (clearFeedback) {
        _discountFeedback = null;
        _discountFeedbackIsError = false;
      }
    });
  }

  String _discountFailureMessage(DiscountCodeValidationException error) {
    switch (error.failure) {
      case DiscountCodeFailure.emptyCode:
        return context.tr('cart.discount_empty_code');
      case DiscountCodeFailure.codeNotFound:
      case DiscountCodeFailure.inactive:
        return context.tr('cart.discount_invalid_or_expired');
      case DiscountCodeFailure.belowMinimumOrder:
        final minValue = localizedCurrency(
          context,
          error.minimumOrderPrice ?? 0,
        );
        return context.tr(
          'cart.discount_min_order_not_met',
          args: {'minimum': minValue},
        );
      case DiscountCodeFailure.unsupportedType:
      case DiscountCodeFailure.invalidDiscountValue:
        return context.tr('cart.discount_invalid_amount');
    }
  }

  Future<void> _applyDiscountCode(CartController cart) async {
    if (_applyingDiscount) {
      return;
    }
    if (cart.isLocked) {
      setState(() {
        _discountFeedback = context.tr('cart.discount_locked');
        _discountFeedbackIsError = true;
      });
      return;
    }

    final currentApplied = _appliedDiscountCode;
    final enteredCode = discountCodeCtrl.text.trim();
    if (enteredCode.isEmpty) {
      setState(() {
        _discountFeedback = context.tr('cart.discount_empty_code');
        _discountFeedbackIsError = true;
      });
      return;
    }

    final normalizedInput = enteredCode.toLowerCase();
    if (currentApplied != null &&
        currentApplied.normalizedCode == normalizedInput) {
      setState(() {
        _discountFeedback = context.tr('cart.discount_already_applied');
        _discountFeedbackIsError = true;
      });
      return;
    }
    if (currentApplied != null) {
      setState(() {
        _discountFeedback = context.tr('cart.discount_single_code_only');
        _discountFeedbackIsError = true;
      });
      return;
    }

    setState(() {
      _applyingDiscount = true;
      _discountFeedback = null;
      _discountFeedbackIsError = false;
    });

    try {
      final validated = await DiscountCodesService.validateCode(
        restaurantId: widget.restaurantId,
        code: enteredCode,
        orderSubtotal: cart.totalPrice,
      );
      if (!mounted) {
        return;
      }

      _setControllerValue(discountCodeCtrl, validated.code);
      setState(() {
        _appliedDiscountCode = validated;
        _discountFeedback = context.tr(
          'cart.discount_apply_success',
          args: {'code': validated.code},
        );
        _discountFeedbackIsError = false;
      });
    } on DiscountCodeValidationException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _discountFeedback = _discountFailureMessage(error);
        _discountFeedbackIsError = true;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _discountFeedback = context.tr('cart.discount_error_generic');
        _discountFeedbackIsError = true;
      });
    } finally {
      if (mounted) {
        setState(() {
          _applyingDiscount = false;
        });
      }
    }
  }

  Future<void> _loadProfile() async {
    try {
      final profileFuture = _profileService.getOrCreateProfile();
      final addressFuture = CustomerAddressService.getPrimaryAddress();
      final profile = await profileFuture;
      final savedPrimaryAddress = await addressFuture;
      if (!mounted) {
        return;
      }

      _setControllerValue(nameCtrl, (profile['name'] ?? '').toString());
      _setControllerValue(phoneCtrl, (profile['phone'] ?? '').toString());
      _primaryAddress = savedPrimaryAddress;

      if (savedPrimaryAddress != null) {
        final currentAddress = addressCtrl.text.trim();
        if (currentAddress.isEmpty) {
          _setControllerValue(addressCtrl, savedPrimaryAddress.primaryAddress);
        }
        if (houseNumberCtrl.text.trim().isEmpty) {
          _setControllerValue(
            houseNumberCtrl,
            savedPrimaryAddress.houseApartmentNo,
          );
        }

        final cart = CartProvider.maybeOf(context);
        if (cart != null &&
            !cart.isLocked &&
            (cart.deliveryAddress == null ||
                cart.deliveryAddress!.trim().isEmpty)) {
          final hasGeoPoint = savedPrimaryAddress.lat != null &&
              savedPrimaryAddress.lng != null;
          if (hasGeoPoint) {
            cart.setDeliveryLocation(
              address: savedPrimaryAddress.primaryAddress,
              lat: savedPrimaryAddress.lat!,
              lng: savedPrimaryAddress.lng!,
              houseNumber: savedPrimaryAddress.houseApartmentNo,
            );
          } else {
            cart.setDeliveryAddress(savedPrimaryAddress.primaryAddress);
            cart.setHouseNumber(savedPrimaryAddress.houseApartmentNo);
          }
        }
      }
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

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
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
      await _openCurrentOrder();
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

    final hasPrimaryAddress = await _ensurePrimaryAddressForCheckout(cart);
    if (!hasPrimaryAddress) {
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
    final pricing = _pricingFor(cart);

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
          totalPrice: pricing.finalTotal,
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

      await InputFocusGuard.prepareForUiTransition(context: context);
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

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return false;
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

  Future<bool> _ensurePrimaryAddressForCheckout(CartController cart) async {
    final cachedAddress = _primaryAddress;
    if (cachedAddress != null && cachedAddress.isComplete) {
      return true;
    }

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return false;
    }

    final result = await showModalBottomSheet<_PrimaryAddressResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _PrimaryAddressSheet(
        initialAddress: addressCtrl.text.trim(),
        initialHouseApartmentNo: houseNumberCtrl.text.trim(),
        initialLat: cart.deliveryLat ?? cachedAddress?.lat,
        initialLng: cart.deliveryLng ?? cachedAddress?.lng,
        initialCustomerName: nameCtrl.text.trim(),
        initialCustomerPhone: phoneCtrl.text.trim(),
      ),
    );

    if (result == null) {
      return false;
    }

    try {
      final saved = await CustomerAddressService.savePrimaryAddress(
        primaryAddress: result.primaryAddress,
        houseApartmentNo: result.houseApartmentNo,
        area: '',
        additionalNotes: '',
        lat: result.lat,
        lng: result.lng,
      );

      if (!mounted) {
        return false;
      }

      setState(() => _primaryAddress = saved);

      _setControllerValue(addressCtrl, saved.primaryAddress);
      _setControllerValue(houseNumberCtrl, saved.houseApartmentNo);

      if (!cart.isLocked) {
        final lat = saved.lat ?? result.lat;
        final lng = saved.lng ?? result.lng;
        cart.setDeliveryLocation(
          address: saved.primaryAddress,
          lat: lat,
          lng: lng,
          houseNumber: saved.houseApartmentNo,
        );
      }

      return true;
    } catch (_) {
      if (mounted) {
        _showSnack(context.tr('cart.profile_save_error'));
      }
      return false;
    }
  }

  Future<void> _openCurrentOrder() async {
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

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.push(context, route);
  }

  _CartPricingBreakdown _pricingFor(CartController cart) {
    final subtotal = cart.totalPrice;
    final delivery = cart.deliveryCost;
    final beforeDiscount = subtotal + delivery;
    final applied = _appliedDiscountCode;

    if (applied == null ||
        applied.restaurantId != widget.restaurantId ||
        !applied.meetsMinimum(subtotal)) {
      return _CartPricingBreakdown(
        subtotal: subtotal,
        delivery: delivery,
        beforeDiscount: beforeDiscount,
        discount: 0,
        finalTotal: beforeDiscount,
        appliedDiscount: null,
      );
    }

    final discount = applied.valueForSubtotal(subtotal);
    final finalTotal = (beforeDiscount - discount).clamp(0, double.infinity);
    return _CartPricingBreakdown(
      subtotal: subtotal,
      delivery: delivery,
      beforeDiscount: beforeDiscount,
      discount: discount,
      finalTotal: finalTotal.toDouble(),
      appliedDiscount: applied,
    );
  }

  void _showSnack(String message) {
    AppSnackBar.show(context, message: message);
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
    final pricing = _pricingFor(cart);
    final subtotal = pricing.subtotal;
    final total = pricing.finalTotal;
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
                              onOpenOrder: () => unawaited(_openCurrentOrder()),
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
                                  readOnly: true,
                                  onTap: cart.isLocked
                                      ? null
                                      : () => unawaited(
                                            _openLocationPicker(cart),
                                          ),
                                  onTapOutside: (_) =>
                                      InputFocusGuard.dismiss(),
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
                                  onTapOutside: (_) =>
                                      InputFocusGuard.dismiss(),
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
                            title: context.tr('cart.discount_section'),
                            child: _DiscountCodeSection(
                              codeController: discountCodeCtrl,
                              applying: _applyingDiscount,
                              locked: cart.isLocked,
                              hasAppliedDiscount:
                                  pricing.appliedDiscount != null,
                              feedback: _discountFeedback,
                              feedbackIsError: _discountFeedbackIsError,
                              discountTypeLabel: pricing.appliedDiscount == null
                                  ? null
                                  : context.tr(
                                      pricing.appliedDiscount!.type ==
                                              DiscountType.percentage
                                          ? 'cart.discount_type_percentage'
                                          : 'cart.discount_type_fixed',
                                    ),
                              onApply: () => _applyDiscountCode(cart),
                              onRemove: () => _clearAppliedDiscount(
                                clearFeedback: true,
                              ),
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
                                    pricing.delivery,
                                  ),
                                ),
                                if (pricing.appliedDiscount != null) ...[
                                  const SizedBox(height: 10),
                                  _PriceRow(
                                    label: context.tr('cart.discount_before'),
                                    value: localizedCurrency(
                                      context,
                                      pricing.beforeDiscount,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  _PriceRow(
                                    label: context.tr('cart.discount_value'),
                                    value:
                                        '- ${localizedCurrency(context, pricing.discount)}',
                                    valueColor: const Color(0xFF027A48),
                                  ),
                                ],
                                const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 14),
                                  child: Divider(height: 1),
                                ),
                                _PriceRow(
                                  label: pricing.appliedDiscount == null
                                      ? context.tr('cart.total')
                                      : context.tr('cart.discount_final'),
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

class _DiscountCodeSection extends StatelessWidget {
  const _DiscountCodeSection({
    required this.codeController,
    required this.applying,
    required this.locked,
    required this.hasAppliedDiscount,
    required this.feedback,
    required this.feedbackIsError,
    required this.discountTypeLabel,
    required this.onApply,
    required this.onRemove,
  });

  final TextEditingController codeController;
  final bool applying;
  final bool locked;
  final bool hasAppliedDiscount;
  final String? feedback;
  final bool feedbackIsError;
  final String? discountTypeLabel;
  final VoidCallback onApply;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final disabled = locked || applying;
    final canApply = !disabled && !hasAppliedDiscount;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 410;
        final applyButton = SizedBox(
          width: compact ? double.infinity : 118,
          child: ElevatedButton(
            onPressed: canApply ? onApply : null,
            style: ElevatedButton.styleFrom(
              minimumSize: Size(compact ? double.infinity : 118, 46),
            ),
            child: applying
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(context.tr('cart.discount_apply')),
          ),
        );

        final input = TextField(
          controller: codeController,
          enabled: !locked && !hasAppliedDiscount,
          onTapOutside: (_) => InputFocusGuard.dismiss(),
          textAlign: TextAlign.left,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            labelText: context.tr('cart.discount_code_label'),
            hintText: context.tr('cart.discount_code_hint'),
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (compact) ...[
              input,
              const SizedBox(height: 10),
              applyButton,
            ] else
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  applyButton,
                  const SizedBox(width: 12),
                  Expanded(child: input),
                ],
              ),
            if (hasAppliedDiscount) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: locked ? null : onRemove,
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: Text(context.tr('cart.discount_remove')),
                  ),
                  const SizedBox(width: 10),
                  if (discountTypeLabel != null)
                    Expanded(
                      child: Text(
                        context.tr(
                          'cart.discount_type',
                          args: {'type': discountTypeLabel!},
                        ),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF027A48),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (feedback != null && feedback!.trim().isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  feedback!,
                  textAlign: TextAlign.start,
                  style: TextStyle(
                    color: feedbackIsError
                        ? const Color(0xFFB42318)
                        : const Color(0xFF027A48),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PriceRow extends StatelessWidget {
  const _PriceRow({
    required this.label,
    required this.value,
    this.emphasized = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool emphasized;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          value,
          style: TextStyle(
            color:
                valueColor ?? (emphasized ? AppTheme.primary : AppTheme.text),
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

class _CartPricingBreakdown {
  const _CartPricingBreakdown({
    required this.subtotal,
    required this.delivery,
    required this.beforeDiscount,
    required this.discount,
    required this.finalTotal,
    required this.appliedDiscount,
  });

  final double subtotal;
  final double delivery;
  final double beforeDiscount;
  final double discount;
  final double finalTotal;
  final AppliedDiscountCode? appliedDiscount;
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

  Future<void> _submit() async {
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

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(
      context,
      _CustomerInfoResult(name: name, phone: phone),
    );
  }

  void _showSnack(String message) {
    AppSnackBar.show(context, message: message);
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
              onTapOutside: (_) => InputFocusGuard.dismiss(),
              textAlign: TextAlign.right,
              decoration: InputDecoration(
                labelText: context.tr('cart.name'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneCtrl,
              onTapOutside: (_) => InputFocusGuard.dismiss(),
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

class _PrimaryAddressResult {
  const _PrimaryAddressResult({
    required this.primaryAddress,
    required this.houseApartmentNo,
    required this.lat,
    required this.lng,
  });

  final String primaryAddress;
  final String houseApartmentNo;
  final double lat;
  final double lng;
}

class _PrimaryAddressSheet extends StatefulWidget {
  const _PrimaryAddressSheet({
    required this.initialAddress,
    required this.initialHouseApartmentNo,
    this.initialLat,
    this.initialLng,
    this.initialCustomerName,
    this.initialCustomerPhone,
  });

  final String initialAddress;
  final String initialHouseApartmentNo;
  final double? initialLat;
  final double? initialLng;
  final String? initialCustomerName;
  final String? initialCustomerPhone;

  @override
  State<_PrimaryAddressSheet> createState() => _PrimaryAddressSheetState();
}

class _PrimaryAddressSheetState extends State<_PrimaryAddressSheet> {
  late final TextEditingController _addressCtrl =
      TextEditingController(text: widget.initialAddress);
  late final TextEditingController _houseCtrl =
      TextEditingController(text: widget.initialHouseApartmentNo);
  double? _selectedLat;
  double? _selectedLng;

  @override
  void initState() {
    super.initState();
    _selectedLat = widget.initialLat;
    _selectedLng = widget.initialLng;
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    _houseCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final address = _addressCtrl.text.trim();
    final house = _houseCtrl.text.trim();

    if (address.isEmpty) {
      _showSnack('اكتب العنوان الأساسي.');
      return;
    }
    if (house.isEmpty) {
      _showSnack('اكتب رقم البيت / الشقة.');
      return;
    }
    if (_selectedLat == null || _selectedLng == null) {
      _showSnack('حدد موقع العنوان من الخريطة أولاً.');
      return;
    }

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.pop(
      context,
      _PrimaryAddressResult(
        primaryAddress: address,
        houseApartmentNo: house,
        lat: _selectedLat!,
        lng: _selectedLng!,
      ),
    );
  }

  Future<void> _openAddressPicker() async {
    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }

    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SelectAddressPage(
        initialLat: _selectedLat,
        initialLng: _selectedLng,
        initialAddress: _addressCtrl.text.trim(),
        initialHouseNumber: _houseCtrl.text.trim(),
        initialCustomerName: widget.initialCustomerName,
        initialCustomerPhone: widget.initialCustomerPhone,
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

    if (lat == null || lng == null || fullAddress.isEmpty) {
      _showSnack('تعذر اعتماد الموقع المحدد، حاول مرة أخرى.');
      return;
    }

    _addressCtrl.value = _addressCtrl.value.copyWith(
      text: fullAddress,
      selection: TextSelection.collapsed(offset: fullAddress.length),
      composing: TextRange.empty,
    );
    _houseCtrl.value = _houseCtrl.value.copyWith(
      text: houseNumber,
      selection: TextSelection.collapsed(offset: houseNumber.length),
      composing: TextRange.empty,
    );
    setState(() {
      _selectedLat = lat;
      _selectedLng = lng;
    });
  }

  void _showSnack(String message) {
    AppSnackBar.show(context, message: message);
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
            const Text(
              'أكمل عنوانك الأساسي',
              style: TextStyle(
                color: AppTheme.text,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'لا يمكن تنفيذ أول طلب قبل حفظ العنوان الأساسي. بعد الحفظ يمكنك تعديله لاحقًا من الملف الشخصي.',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Color(0xFF667085),
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _addressCtrl,
              readOnly: true,
              onTap: _openAddressPicker,
              onTapOutside: (_) => InputFocusGuard.dismiss(),
              textAlign: TextAlign.right,
              minLines: 2,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'العنوان الأساسي',
                hintText: 'اختر العنوان من الخريطة',
                prefixIcon: Icon(Icons.location_on_outlined),
                suffixIcon: IconButton(
                  onPressed: _openAddressPicker,
                  icon: const Icon(Icons.map_outlined),
                ),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _houseCtrl,
              onTapOutside: (_) => InputFocusGuard.dismiss(),
              textAlign: TextAlign.right,
              decoration: const InputDecoration(
                labelText: 'رقم البيت / الشقة',
                hintText: 'مثال: عمارة 12 - شقة 7',
                prefixIcon: Icon(Icons.home_outlined),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _selectedLat == null || _selectedLng == null
                    ? 'لم يتم تحديد موقع الخريطة بعد.'
                    : 'الموقع مضبوط (${_selectedLat!.toStringAsFixed(5)}, ${_selectedLng!.toStringAsFixed(5)})',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.save_outlined),
                label: const Text('حفظ ومتابعة'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
