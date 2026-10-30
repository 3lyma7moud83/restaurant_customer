import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ui/app_motion.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/auth/auth_navigation_guard.dart';
import '../core/localization/app_localizations.dart';
import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/input_focus_guard.dart';
import '../core/ui/app_snackbar.dart';
import '../services/complaints_service.dart';
import '../services/restaurants_service.dart';
import 'restaurant_card_components.dart';

Future<void> showRestaurantInfoSheet(
  BuildContext context, {
  required Map<String, dynamic> restaurant,
  double? customerLatitude,
  double? customerLongitude,
}) async {
  await InputFocusGuard.prepareForUiTransition(context: context);
  if (!context.mounted) {
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: AppMotion.overlayStyle(context),
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RestaurantQuickActionsSheet(
      restaurant: restaurant,
      customerLatitude: customerLatitude,
      customerLongitude: customerLongitude,
    ),
  );
}

Future<bool?> showComplaintComposerSheet(
  BuildContext context, {
  String? restaurantId,
  String? restaurantName,
  String? orderId,
  ComplaintsService? complaintsService,
}) async {
  await InputFocusGuard.prepareForUiTransition(context: context);
  if (!context.mounted) {
    return null;
  }

  return showModalBottomSheet<bool>(
    context: context,
    sheetAnimationStyle: AppMotion.overlayStyle(context),
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ComplaintComposerSheet(
      restaurantId: restaurantId,
      restaurantName: restaurantName,
      orderId: orderId,
      complaintsService: complaintsService,
    ),
  );
}

class _RestaurantQuickActionsSheet extends StatefulWidget {
  const _RestaurantQuickActionsSheet({
    required this.restaurant,
    this.customerLatitude,
    this.customerLongitude,
  });

  final Map<String, dynamic> restaurant;
  final double? customerLatitude;
  final double? customerLongitude;

  @override
  State<_RestaurantQuickActionsSheet> createState() =>
      _RestaurantQuickActionsSheetState();
}

class _RestaurantQuickActionsSheetState
    extends State<_RestaurantQuickActionsSheet> with WidgetsBindingObserver {
  late Map<String, dynamic> _restaurantDetails;
  Future<void>? _refreshFuture;
  int _loadGeneration = 0;
  bool _detailsUnavailable = false;

  @override
  void initState() {
    super.initState();
    _restaurantDetails = Map<String, dynamic>.from(widget.restaurant);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshRestaurantDetails());
  }

  @override
  void didUpdateWidget(covariant _RestaurantQuickActionsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restaurant != widget.restaurant ||
        oldWidget.customerLatitude != widget.customerLatitude ||
        oldWidget.customerLongitude != widget.customerLongitude) {
      _loadGeneration++;
      _refreshFuture = null;
      _restaurantDetails = Map<String, dynamic>.from(widget.restaurant);
      _detailsUnavailable = false;
      unawaited(_refreshRestaurantDetails());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRestaurantDetails());
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshRestaurantDetails() {
    final current = _refreshFuture;
    if (current != null) return current;
    final generation = _loadGeneration;
    final future = _loadRestaurantDetails(generation).whenComplete(() {
      if (generation == _loadGeneration) _refreshFuture = null;
    });
    _refreshFuture = future;
    return future;
  }

  Future<void> _openComplaintComposer() async {
    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    final restaurantId = RestaurantsService.restaurantIdOf(widget.restaurant);
    final restaurantName =
        RestaurantsService.restaurantNameOf(_restaurantDetails);
    final submitted = await showComplaintComposerSheet(
      context,
      restaurantId: restaurantId.isEmpty ? null : restaurantId,
      restaurantName: restaurantName,
    );
    if (submitted == true && mounted) {
      AppSnackBar.show(
        context,
        message: context.tr('drawer.complaint_sent'),
      );
    }
  }

  Future<void> _loadRestaurantDetails(int generation) async {
    final restaurantId = RestaurantsService.restaurantIdOf(widget.restaurant);
    final latitude = widget.customerLatitude;
    final longitude = widget.customerLongitude;
    if (restaurantId.isEmpty || latitude == null || longitude == null) {
      return;
    }

    try {
      // Customer access is authorized by the nearby RPC. Direct managers reads
      // are restricted to staff by RLS, including for realtime subscriptions.
      final restaurants = await RestaurantsService.getNearby(
        latitude: latitude,
        longitude: longitude,
        forceRefresh: true,
      ).timeout(const Duration(seconds: 12));
      if (!mounted || generation != _loadGeneration) return;
      Map<String, dynamic>? details;
      for (final restaurant in restaurants) {
        if (RestaurantsService.restaurantIdOf(restaurant) == restaurantId) {
          details = restaurant;
          break;
        }
      }
      setState(() {
        _detailsUnavailable = details == null;
        // Do not retain old facts when the server no longer returns this venue.
        _restaurantDetails = details ??
            <String, dynamic>{
              'restaurant_id': restaurantId,
              'name': RestaurantsService.restaurantNameOf(widget.restaurant),
              'image_url':
                  RestaurantsService.restaurantImageOf(widget.restaurant),
              'restaurant_type':
                  RestaurantsService.cardTypeOf(widget.restaurant),
            };
      });
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurant_info_sheet.load_details',
        error: error,
        stack: stack,
      );
    }
  }

  String _notSpecified(BuildContext context) =>
      context.tr('common.not_specified');

  String _displayOrUnspecified(BuildContext context, String? value) {
    final normalized = value?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized.toLowerCase() == 'null') {
      return _notSpecified(context);
    }
    return normalized;
  }

  String? _firstNonEmptyString(
    Map<String, dynamic>? source,
    List<String> keys,
  ) {
    if (source == null) {
      return null;
    }

    for (final key in keys) {
      final normalized = source[key]?.toString().trim();
      if (normalized != null &&
          normalized.isNotEmpty &&
          normalized.toLowerCase() != 'null') {
        return normalized;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: RefreshIndicator(
        onRefresh: _refreshRestaurantDetails,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Builder(
                builder: (context) {
                  final details = _restaurantDetails;
                  final name = _displayOrUnspecified(
                    context,
                    _firstNonEmptyString(details, const [
                      'restaurant_name',
                      'name',
                    ]),
                  );
                  final imageUrl =
                      _firstNonEmptyString(details, const ['image_url']);
                  final type = RestaurantsService.cardTypeOf(details)?.trim();
                  final unavailable = _detailsUnavailable
                      ? context.tr('restaurant.details_unavailable')
                      : _notSpecified(context);
                  final openingTime = RestaurantsService.openingTimeOf(
                    details,
                    fallback: unavailable,
                  );
                  final closingTime = RestaurantsService.closingTimeOf(
                    details,
                    fallback: unavailable,
                  );
                  final safeAddress = RestaurantsService.restaurantAddressOf(
                    details,
                    fallback: unavailable,
                  );

                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Theme.of(context).colorScheme.surfaceContainerHigh,
                          Theme.of(context).colorScheme.surfaceContainerLow,
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 142,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (imageUrl != null && imageUrl.isNotEmpty)
                                AppCachedImage(
                                  imageUrl: imageUrl,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(24),
                                  ),
                                  errorWidget: const SizedBox.shrink(),
                                ),
                              if (imageUrl != null && imageUrl.isNotEmpty)
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(24),
                                    ),
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.black.withValues(alpha: 0.08),
                                        Colors.black.withValues(alpha: 0.42),
                                      ],
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                      style: TextStyle(
                                        color: imageUrl != null &&
                                                imageUrl.isNotEmpty
                                            ? Colors.white
                                            : Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    if (type != null && type.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        type,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          color: imageUrl != null &&
                                                  imageUrl.isNotEmpty
                                              ? Colors.white
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                          child: Column(
                            children: [
                              _InfoFactRow(
                                icon: Icons.access_time_rounded,
                                title: context.tr('restaurant.opening_time'),
                                value: openingTime,
                              ),
                              const SizedBox(height: 8),
                              _InfoFactRow(
                                icon: Icons.nightlight_round_rounded,
                                title: context.tr('restaurant.closing_time'),
                                value: closingTime,
                              ),
                              const SizedBox(height: 8),
                              _InfoFactRow(
                                icon: Icons.location_on_rounded,
                                title: context.tr('restaurant.address'),
                                value: safeAddress,
                                maxLines: 2,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 18),
              _SheetActionTile(
                icon: Icons.report_gmailerrorred_rounded,
                title: context.tr('drawer.complaint'),
                onTap: _openComplaintComposer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoFactRow extends StatelessWidget {
  const _InfoFactRow({
    required this.icon,
    required this.title,
    required this.value,
    this.maxLines = 1,
  });

  final IconData icon;
  final String title;
  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: maxLines > 1
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: maxLines,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                      fontSize: 13.5,
                    ),
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

class _SheetActionTile extends StatelessWidget {
  const _SheetActionTile({
    required this.icon,
    required this.title,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isRtl = Directionality.of(context) == TextDirection.rtl;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    icon,
                    size: 19,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComplaintComposerSheet extends StatefulWidget {
  const _ComplaintComposerSheet({
    this.restaurantId,
    this.restaurantName,
    this.orderId,
    this.complaintsService,
  });

  final String? restaurantId;
  final String? restaurantName;
  final String? orderId;
  final ComplaintsService? complaintsService;

  @override
  State<_ComplaintComposerSheet> createState() =>
      _ComplaintComposerSheetState();
}

class _ComplaintComposerSheetState extends State<_ComplaintComposerSheet> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  bool _sending = false;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) {
      return;
    }

    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      _showSnack(context.tr('complaint.validation_error'));
      return;
    }

    setState(() => _sending = true);
    try {
      final isAuthenticated = await ensureUserAuthenticated(context);
      if (!mounted || !isAuthenticated) return;
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        _showSnack(context.tr('complaint.login_required'));
        return;
      }
      final submit =
          widget.complaintsService?.submit ?? ComplaintsService.submitComplaint;
      await submit(
        userId: user.id,
        restaurantId: widget.restaurantId,
        orderId: widget.orderId,
        title: title,
        description: description,
      );

      if (!mounted) {
        return;
      }
      await InputFocusGuard.prepareForUiTransition(context: context);
      if (!mounted) {
        return;
      }
      Navigator.pop(context, true);
    } catch (error, stack) {
      if (error is! ComplaintSubmissionException) {
        unawaited(ErrorLogger.logError(
          module: 'restaurant_info_sheet.complaint.submit',
          error: error,
          stack: stack,
        ));
      }
      if (mounted) {
        final errorText = error.toString();
        final normalizedError = errorText.startsWith('Exception: ')
            ? errorText.substring('Exception: '.length).trim()
            : errorText.trim();
        _showSnack(
          normalizedError.isEmpty ? ErrorLogger.userMessage : normalizedError,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  void _showSnack(String message) {
    AppSnackBar.show(context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final restaurantName = widget.restaurantName?.trim();
    final heading = restaurantName == null || restaurantName.isEmpty
        ? context.tr('complaint.heading')
        : context.tr(
            'complaint.heading_with_restaurant',
            args: {'name': restaurantName},
          );

    return AnimatedPadding(
      duration: AppMotion.duration(context, AppMotion.contentDuration),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                heading,
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr('complaint.subtitle'),
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
                enabled: !_sending,
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                onTapOutside: (_) => InputFocusGuard.dismiss(),
                textInputAction: TextInputAction.next,
                maxLength: 120,
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) {
                    return context.tr('complaint.title_required');
                  }
                  if (text.length < 4) {
                    return context.tr('complaint.title_too_short');
                  }
                  return null;
                },
                decoration: InputDecoration(
                  labelText: context.tr('complaint.title_label'),
                  hintText: context.tr('complaint.title_hint'),
                  prefixIcon: const Icon(Icons.title_rounded),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _descriptionController,
                enabled: !_sending,
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                onTapOutside: (_) => InputFocusGuard.dismiss(),
                minLines: 4,
                maxLines: 7,
                maxLength: 1000,
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) {
                    return context.tr('complaint.message_required');
                  }
                  if (text.length < 10) {
                    return context.tr('complaint.message_too_short');
                  }
                  return null;
                },
                decoration: InputDecoration(
                  labelText: context.tr('complaint.message_label'),
                  hintText: context.tr('complaint.message_hint'),
                  prefixIcon: const Icon(Icons.notes_rounded),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _sending ? null : _submit,
                  icon: _sending
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                  label: Text(context.tr('complaint.send')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
