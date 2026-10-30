import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/app_motion.dart';

import '../../services/orders_service.dart';
import '../stability/stability_logger.dart';
import '../theme/app_theme.dart';
import '../ui/app_snackbar.dart';

String deliveryConfirmationStateKey(Map<String, dynamic> order) {
  return [
    OrdersService.idOf(order),
    OrdersService.normalizedStatusOf(order),
    OrdersService.authoritativeStateVersionOf(order)?.toString() ?? '-',
    OrdersService.orderVersionOf(order)?.toString() ?? '-',
  ].join(':');
}

Future<void> showDeliveryConfirmationDialog({
  required BuildContext context,
  required Map<String, dynamic> order,
  required Future<void> Function() onConfirm,
  VoidCallback? onContactDriver,
}) {
  final orderId = OrdersService.idOf(order);
  StabilityLogger.deliveryConfirmation(
    'Delivery Confirmation Dialog Opened order=$orderId',
  );

  return showModalBottomSheet<void>(
    context: context,
    sheetAnimationStyle: AppMotion.overlayStyle(context),
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (_) {
      return _DeliveryConfirmationSheet(
        onConfirm: onConfirm,
        onContactDriver: onContactDriver,
      );
    },
  ).whenComplete(
    () => StabilityLogger.deliveryConfirmation(
      'Delivery Confirmation Dialog Closed order=$orderId',
    ),
  );
}

class DeliveryConfirmationBanner extends StatelessWidget {
  const DeliveryConfirmationBanner({
    super.key,
    required this.onOpenConfirmation,
  });

  final VoidCallback onOpenConfirmation;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.infoContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.info.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.fact_check_rounded,
                color: colors.info,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'يرجى تأكيد استلام الطلب لإكمال العملية.',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: colors.info,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onOpenConfirmation,
              icon: const Icon(Icons.check_circle_outline_rounded),
              label: const Text('✅ تأكيد الاستلام'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeliveryConfirmationSheet extends StatefulWidget {
  const _DeliveryConfirmationSheet({
    required this.onConfirm,
    this.onContactDriver,
  });

  final Future<void> Function() onConfirm;
  final VoidCallback? onContactDriver;

  @override
  State<_DeliveryConfirmationSheet> createState() =>
      _DeliveryConfirmationSheetState();
}

class _DeliveryConfirmationSheetState
    extends State<_DeliveryConfirmationSheet> {
  bool _submitting = false;
  bool _waitingForRealtime = false;
  bool _showContactDriver = false;

  Future<void> _confirmDeliveryReceived() async {
    if (_submitting || _waitingForRealtime) {
      return;
    }

    setState(() => _submitting = true);
    try {
      await widget.onConfirm();
      if (!mounted) {
        return;
      }
      setState(() {
        _submitting = false;
        _waitingForRealtime = true;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      AppSnackBar.show(
        context,
        message: error.toString().replaceFirst('Exception: ', ''),
      );
      setState(() => _submitting = false);
    }
  }

  void _handleNotReceived() {
    if (_submitting || _waitingForRealtime) {
      return;
    }
    setState(() => _showContactDriver = true);
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.viewInsetsOf(context).bottom;
    final colors = AppTheme.colorsOf(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottomPadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outline,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'هل استلمت الطلب؟',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'أكد السائق أنه قام بتسليم الطلب.\nلن تتغير الحالة إلى مكتمل إلا بعد تأكيدك أنت.',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: AppTheme.colorsOf(context).textSecondary,
                height: 1.55,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (_waitingForRealtime) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.successContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'تم إرسال التأكيد. بانتظار تحديث السيرفر الرسمي.',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: colors.success,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _submitting || _waitingForRealtime
                  ? null
                  : () => unawaited(_confirmDeliveryReceived()),
              icon: _submitting
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    )
                  : const Icon(Icons.check_circle_outline_rounded),
              label: const Text('استلمت الطلب'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _submitting || _waitingForRealtime
                  ? null
                  : _handleNotReceived,
              icon: const Icon(Icons.report_problem_outlined),
              label: const Text('لم أستلم الطلب'),
            ),
            if (_showContactDriver) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.warningContainer,
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: colors.warning.withValues(alpha: 0.3)),
                ),
                child: Text(
                  'سيبقى الطلب على حالته الحالية حتى تؤكد الاستلام. يمكنك التواصل مع السائق مباشرة الآن.',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: colors.warning,
                    fontWeight: FontWeight.w800,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _submitting || _waitingForRealtime
                    ? null
                    : () {
                        final onContactDriver = widget.onContactDriver;
                        if (onContactDriver != null) {
                          onContactDriver();
                          return;
                        }
                        AppSnackBar.show(
                          context,
                          message: 'رقم السائق غير متوفر حاليًا.',
                        );
                      },
                icon: const Icon(Icons.phone_outlined),
                label: const Text('📞 الاتصال بالسائق'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
