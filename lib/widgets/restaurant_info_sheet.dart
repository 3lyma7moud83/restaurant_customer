import 'package:flutter/material.dart';
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
}) async {
  await InputFocusGuard.prepareForUiTransition(context: context);
  if (!context.mounted) {
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RestaurantQuickActionsSheet(restaurant: restaurant),
  );
}

Future<bool?> showComplaintComposerSheet(
  BuildContext context, {
  String? restaurantId,
  String? restaurantName,
  String? orderId,
}) async {
  await InputFocusGuard.prepareForUiTransition(context: context);
  if (!context.mounted) {
    return null;
  }

  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ComplaintComposerSheet(
      restaurantId: restaurantId,
      restaurantName: restaurantName,
      orderId: orderId,
    ),
  );
}

class _RestaurantQuickActionsSheet extends StatefulWidget {
  const _RestaurantQuickActionsSheet({
    required this.restaurant,
  });

  final Map<String, dynamic> restaurant;

  @override
  State<_RestaurantQuickActionsSheet> createState() =>
      _RestaurantQuickActionsSheetState();
}

class _RestaurantQuickActionsSheetState
    extends State<_RestaurantQuickActionsSheet> {
  late final Future<Map<String, dynamic>?> _restaurantDetailsFuture =
      _loadRestaurantDetails();

  Future<void> _openComplaintComposer() async {
    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    final restaurantDetails = await _restaurantDetailsFuture;
    if (!mounted) {
      return;
    }
    final fallbackRestaurantId = RestaurantsService.restaurantIdOf(
      widget.restaurant,
    );
    final fallbackRestaurantName = RestaurantsService.restaurantNameOf(
      widget.restaurant,
    );
    final restaurantId = restaurantDetails == null
        ? fallbackRestaurantId
        : RestaurantsService.restaurantIdOf(restaurantDetails);
    final restaurantName = restaurantDetails == null
        ? fallbackRestaurantName
        : RestaurantsService.restaurantNameOf(restaurantDetails);
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

  Future<Map<String, dynamic>?> _loadRestaurantDetails() async {
    final restaurantId = RestaurantsService.restaurantIdOf(widget.restaurant);
    if (restaurantId.isEmpty) {
      return null;
    }

    try {
      final details = await RestaurantsService.getManagerDetailsByRestaurantId(
        restaurantId,
        forceRefresh: true,
      );
      return details;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'restaurant_info_sheet.load_details',
        error: error,
        stack: stack,
      );
      return null;
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
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FutureBuilder<Map<String, dynamic>?>(
              future: _restaurantDetailsFuture,
              builder: (context, snapshot) {
                final details = snapshot.data;
                final name = _displayOrUnspecified(
                  context,
                  _firstNonEmptyString(details, const [
                    'restaurant_name',
                    'name',
                  ]),
                );
                final imageUrl =
                    _firstNonEmptyString(details, const ['image_url']);
                final type = RestaurantsService.cardTypeOf(
                        details ?? <String, dynamic>{})
                    ?.trim();
                final openingTime = _displayOrUnspecified(
                  context,
                  _firstNonEmptyString(details, const [
                    'opening_time',
                    'open_time',
                  ]),
                );
                final closingTime = _displayOrUnspecified(
                  context,
                  _firstNonEmptyString(details, const [
                    'closing_time',
                    'close_time',
                  ]),
                );
                final safeAddress = _displayOrUnspecified(
                  context,
                  _firstNonEmptyString(details, const ['address']),
                );

                return Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFFF7EBDC),
                        Color(0xFFF4F7FA),
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
                                    style: const TextStyle(
                                      color: Colors.white,
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
                                      style: const TextStyle(
                                        color: Color(0xFFEFEFEF),
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
        color: Colors.white.withValues(alpha: 0.86),
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
                color: AppTheme.primaryDeep,
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
                    style: const TextStyle(
                      color: AppTheme.textMuted,
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
                    style: const TextStyle(
                      color: AppTheme.text,
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                Icon(
                  isRtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  color: Color(0xFF98A2B3),
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
                        style: const TextStyle(
                          color: AppTheme.text,
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
                  child: Icon(icon, size: 19, color: AppTheme.primaryDeep),
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
  });

  final String? restaurantId;
  final String? restaurantName;
  final String? orderId;

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

    final isAuthenticated = await ensureUserAuthenticated(context);
    if (!mounted || !isAuthenticated) {
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      _showSnack(context.tr('complaint.login_required'));
      return;
    }

    setState(() => _sending = true);
    try {
      await ComplaintsService.submitComplaint(
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
      await ErrorLogger.logError(
        module: 'restaurant_info_sheet.complaint.submit',
        error: error,
        stack: stack,
      );
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
      duration: const Duration(milliseconds: 180),
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
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr('complaint.subtitle'),
                textAlign: isRtl ? TextAlign.right : TextAlign.left,
                style: const TextStyle(
                  color: Color(0xFF667085),
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
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
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
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
