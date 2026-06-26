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
import '../widgets/restaurant_card_components.dart';
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
  bool _saveAddressAsDefault = false;
  String? _loadedActiveOrderId;
  Map<String, dynamic>? _activeOrder;
  AppliedDiscountCode? _appliedDiscountCode;
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
    if (cart == null || cart.isLocked) {
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
    unawaited(_calculateDeliveryFromServer(cart));
  }

  Future<void> _calculateDeliveryFromServer(CartController cart) async {
    if (!cart.hasLocation || cart.isLocked) {
      return;
    }
    final timer = Stopwatch()..start();
    debugPrint(
      '[CartPage] phase=calculate_delivery_cost.started '
      'restaurant_id=${widget.restaurantId}',
    );

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
      debugPrint(
        '[CartPage] phase=calculate_delivery_cost.finished '
        'elapsed_ms=${timer.elapsedMilliseconds} cost=$cost',
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_page.calculateDeliveryFromServer',
        error: error,
        stack: stack,
      );
      cart.updateDeliveryCost(0);
      debugPrint(
        '[CartPage] phase=calculate_delivery_cost.failed '
        'elapsed_ms=${timer.elapsedMilliseconds}',
      );
    }
  }

  Future<void> _createOrder(CartController cart) async {
    if (creatingOrder) {
      return;
    }

    if (cart.isLocked) {
      await _showActiveOrderDialog();
      return;
    }

    if (cart.items.isEmpty) {
      _showSnack(context.tr('cart.empty'));
      return;
    }

    if (!_validateCheckoutFields()) {
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

    await _saveCustomerProfileForCheckout();
    await _saveDefaultAddressIfRequested(cart);

    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    final user = session?.user;
    if (user == null) {
      return;
    }

    final fullAddress = OrdersService.composeDeliveryAddress(
      address: cart.deliveryAddress!,
      buildingNumber: houseNumberCtrl.text,
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
          buildingNumber: houseNumberCtrl.text.trim(),
          apartmentNumber: '',
          floorNumber: '',
          landmark: '',
          notes: '',
          customerLat: cart.deliveryLat!,
          customerLng: cart.deliveryLng!,
          totalPrice: pricing.finalTotal,
          deliveryCost: cart.deliveryCost,
          paymentMethod: cart.selectedPaymentMethod?.value,
          items: cart.items
              .map<CreateOrderItemInput>(
                (item) => CreateOrderItemInput(
                  itemId: item.itemId,
                  name: item.name,
                  price: item.price,
                  quantity: item.qty,
                  variantId: item.variantId,
                  variantName: item.variantName,
                  variantPrice: item.variantPrice,
                  note: item.note,
                ),
              )
              .toList(growable: false),
        ),
        allowOfflineQueue: false,
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
    } on ActiveOrderInProgressException catch (error) {
      await cart.adoptActiveOrder(error.orderId);
      if (mounted) {
        await _loadActiveOrder(cart);
      }
      await _showActiveOrderDialog();
    } on DuplicateOrderBlockedException catch (error) {
      _showSnack(error.message);
    } catch (_) {
      _showSnack(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => creatingOrder = false);
      }
    }
  }

  bool _validateCheckoutFields() {
    if (nameCtrl.text.trim().isEmpty) {
      _showSnack(context.tr('cart.write_name'));
      return false;
    }
    if (phoneCtrl.text.trim().length < 8) {
      _showSnack(context.tr('cart.invalid_phone'));
      return false;
    }

    final requiredFields = <TextEditingController, String>{
      addressCtrl: 'اكتب عنوان التوصيل.',
      houseNumberCtrl: 'اكتب رقم العمارة.',
    };
    for (final entry in requiredFields.entries) {
      if (entry.key.text.trim().isEmpty) {
        _showSnack(entry.value);
        return false;
      }
    }
    return true;
  }

  Future<void> _saveCustomerProfileForCheckout() async {
    try {
      await _profileService.updateProfile(
        name: nameCtrl.text.trim(),
        phone: phoneCtrl.text.trim(),
      );
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_page.saveCustomerProfileForCheckout',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _showSnack('سيتم استخدام بيانات العميل لهذا الطلب فقط.');
      }
    }
  }

  Future<void> _saveDefaultAddressIfRequested(CartController cart) async {
    if (!_saveAddressAsDefault) {
      return;
    }

    try {
      final saved = await CustomerAddressService.savePrimaryAddress(
        primaryAddress: addressCtrl.text.trim(),
        houseApartmentNo: houseNumberCtrl.text.trim(),
        area: '',
        additionalNotes: '',
        lat: cart.deliveryLat,
        lng: cart.deliveryLng,
      );

      if (!cart.isLocked && saved.lat != null && saved.lng != null) {
        cart.setDeliveryLocation(
          address: saved.primaryAddress,
          lat: saved.lat!,
          lng: saved.lng!,
          houseNumber: saved.houseApartmentNo,
        );
      }
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'cart_page.saveDefaultAddressIfRequested',
        error: error,
        stack: stack,
      );
      if (mounted) {
        _showSnack(
          'تعذر حفظ العنوان الافتراضي، وسيتم استخدامه لهذا الطلب فقط.',
        );
      }
    }
  }

  Future<void> _openCurrentOrder() async {
    final order = _activeOrder;
    final orderId =
        order == null ? _loadedActiveOrderId : OrdersService.idOf(order);
    if (orderId == null || orderId.isEmpty) {
      return;
    }

    final route = AppTheme.platformPageRoute<void>(
      builder: (_) => shouldOpenTrackingPageForOrderStatus(
        order?['status']?.toString(),
      )
          ? OrderTrackingPage(orderId: orderId)
          : OrderDetailsPage(orderId: orderId),
    );

    await InputFocusGuard.prepareForUiTransition(context: context);
    if (!mounted) {
      return;
    }
    Navigator.push(context, route);
  }

  Future<void> _showActiveOrderDialog() async {
    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('طلب جاري بالفعل'),
          content: const Text(
            'لديك طلب جاري بالفعل، لا يمكنك إنشاء طلب جديد حتى يتم إنهاؤه.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('إغلاق'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _openCurrentOrder();
              },
              child: const Text('الانتقال إلى الطلب الحالي'),
            ),
          ],
        );
      },
    );
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

  Future<void> _incrementCartItem(CartController cart, CartItem item) async {
    if (creatingOrder || cart.isLocked) {
      return;
    }
    cart.incrementItem(item.id);
  }

  Future<void> _decrementCartItem(CartController cart, CartItem item) async {
    if (creatingOrder || cart.isLocked) {
      return;
    }
    if (item.qty > 1) {
      cart.decrementItem(item.id);
      return;
    }

    final confirmed = await _confirmDeleteCartItem(item);
    if (confirmed && mounted) {
      cart.deleteItem(item.id);
    }
  }

  Future<void> _deleteCartItem(CartController cart, CartItem item) async {
    if (creatingOrder || cart.isLocked) {
      return;
    }
    final confirmed = await _confirmDeleteCartItem(item);
    if (confirmed && mounted) {
      cart.deleteItem(item.id);
    }
  }

  Future<bool> _confirmDeleteCartItem(CartItem item) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('حذف الصنف من السلة؟'),
        content: Text(
          'سيتم حذف "${item.displayName}" بالكامل من السلة.',
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('إلغاء'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('حذف'),
          ),
        ],
      ),
    );
    return result == true;
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
                                      child: _CartLineItem(
                                        item: item,
                                        locked: cart.isLocked || creatingOrder,
                                        onIncrement: () =>
                                            _incrementCartItem(cart, item),
                                        onDecrement: () =>
                                            _decrementCartItem(cart, item),
                                        onDelete: () =>
                                            _deleteCartItem(cart, item),
                                        onNoteChanged: (value) =>
                                            cart.updateItemNote(item.id, value),
                                      ),
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
                                TextField(
                                  controller: nameCtrl,
                                  enabled: !cart.isLocked && !creatingOrder,
                                  onTapOutside: (_) =>
                                      InputFocusGuard.dismiss(),
                                  textAlign: TextAlign.right,
                                  decoration: InputDecoration(
                                    labelText: context.tr('cart.name'),
                                    prefixIcon:
                                        const Icon(Icons.person_outline),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: phoneCtrl,
                                  enabled: !cart.isLocked && !creatingOrder,
                                  onTapOutside: (_) =>
                                      InputFocusGuard.dismiss(),
                                  textAlign: TextAlign.right,
                                  keyboardType: TextInputType.phone,
                                  decoration: InputDecoration(
                                    labelText: context.tr('cart.phone'),
                                    prefixIcon:
                                        const Icon(Icons.phone_outlined),
                                  ),
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
                                    onPressed: creatingOrder
                                        ? null
                                        : () => _openLocationPicker(cart),
                                    icon: const Icon(Icons.map_outlined,
                                        size: 18),
                                    label: const Text(
                                      'تحديد الموقع من الخريطة',
                                    ),
                                  ),
                            child: Column(
                              children: [
                                TextField(
                                  controller: addressCtrl,
                                  enabled: !cart.isLocked && !creatingOrder,
                                  onTapOutside: (_) =>
                                      InputFocusGuard.dismiss(),
                                  textAlign: TextAlign.right,
                                  minLines: 2,
                                  maxLines: 3,
                                  decoration: InputDecoration(
                                    labelText:
                                        context.tr('cart.delivery_address'),
                                    hintText: 'اكتب العنوان أو حدده من الخريطة',
                                    prefixIcon:
                                        const Icon(Icons.location_on_outlined),
                                    suffixIcon: cart.isLocked || creatingOrder
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
                                  enabled: !cart.isLocked && !creatingOrder,
                                  onTapOutside: (_) =>
                                      InputFocusGuard.dismiss(),
                                  textAlign: TextAlign.right,
                                  decoration: const InputDecoration(
                                    labelText: 'رقم العمارة',
                                    hintText: 'مثال: 12',
                                    prefixIcon: Icon(Icons.apartment_outlined),
                                  ),
                                ),
                                if (!cart.isLocked) ...[
                                  const SizedBox(height: 12),
                                  CheckboxListTile(
                                    value: _saveAddressAsDefault,
                                    onChanged: creatingOrder
                                        ? null
                                        : (value) {
                                            setState(
                                              () => _saveAddressAsDefault =
                                                  value ?? false,
                                            );
                                          },
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                      'حفظ التعديلات كعنوان افتراضي للحساب',
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    subtitle: const Text(
                                      'اترك الخيار غير محدد لاستخدام العنوان لهذا الطلب فقط.',
                                      textAlign: TextAlign.right,
                                    ),
                                  ),
                                ],
                                if (cart.hasLocation) ...[
                                  const SizedBox(height: 12),
                                  _LocationPreview(
                                    address: cart.deliveryAddress ?? '',
                                    lat: cart.deliveryLat!,
                                    lng: cart.deliveryLng!,
                                  ),
                                ],
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
                                  enabled: !cart.isLocked && !creatingOrder,
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
                              locked: cart.isLocked || creatingOrder,
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
    required this.locked,
    required this.onIncrement,
    required this.onDecrement,
    required this.onDelete,
    required this.onNoteChanged,
  });

  final CartItem item;
  final bool locked;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final VoidCallback onDelete;
  final ValueChanged<String> onNoteChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F6F2),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: 'حذف الصنف',
                onPressed: locked ? null : onDelete,
                icon: const Icon(Icons.delete_outline_rounded),
              ),
              const SizedBox(width: 8),
              _QuantityStepper(
                quantity: item.qty,
                locked: locked,
                onIncrement: onIncrement,
                onDecrement: onDecrement,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      item.displayName,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: AppTheme.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      localizedCurrency(context, item.price),
                      style: const TextStyle(
                        color: Color(0xFF667085),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _CartItemImage(imageUrl: item.image),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            key: ValueKey('cart-item-note-${item.id}'),
            initialValue: item.note,
            enabled: !locked,
            onChanged: onNoteChanged,
            onTapOutside: (_) => InputFocusGuard.dismiss(),
            textAlign: TextAlign.right,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'ملاحظات الصنف',
              hintText: 'مثال: بدون صوص أو تغليف منفصل',
              prefixIcon: Icon(Icons.edit_note_rounded),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                localizedCurrency(context, item.price * item.qty),
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              Text(
                '${item.qty} × ${localizedCurrency(context, item.price)}',
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.quantity,
    required this.locked,
    required this.onIncrement,
    required this.onDecrement,
  });

  final int quantity;
  final bool locked;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'تقليل الكمية',
            onPressed: locked ? null : onDecrement,
            icon: const Icon(Icons.remove_rounded),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            visualDensity: VisualDensity.compact,
          ),
          SizedBox(
            width: 34,
            child: Text(
              quantity.toString(),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.text,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          IconButton(
            tooltip: 'زيادة الكمية',
            onPressed: locked ? null : onIncrement,
            icon: const Icon(Icons.add_rounded),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 38, height: 38),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _CartItemImage extends StatelessWidget {
  const _CartItemImage({
    required this.imageUrl,
  });

  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    final normalizedUrl = imageUrl.trim();

    return SizedBox.square(
      dimension: size,
      child: normalizedUrl.isEmpty
          ? const ImageFallback(
              icon: Icons.fastfood_rounded,
              iconSize: 22,
            )
          : AppCachedImage(
              imageUrl: normalizedUrl,
              width: size,
              height: size,
              fit: BoxFit.cover,
              borderRadius: BorderRadius.circular(14),
              errorWidget: const ImageFallback(
                icon: Icons.fastfood_rounded,
                iconSize: 22,
              ),
            ),
    );
  }
}

class _LocationPreview extends StatelessWidget {
  const _LocationPreview({
    required this.address,
    required this.lat,
    required this.lng,
  });

  final String address;
  final double lat;
  final double lng;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          const Icon(Icons.location_on_rounded, color: AppTheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text(
                  'معاينة الموقع المختار',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: AppTheme.text,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  address.trim().isEmpty ? 'لم يتم إدخال عنوان نصي.' : address,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF475467),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: Color(0xFF667085),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
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
