import 'dart:async';

import 'package:flutter/material.dart';

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
  required VoidCallback onReportIssue,
  VoidCallback? onBeforeReportIssue,
}) {
  final orderId = OrdersService.idOf(order);
  StabilityLogger.deliveryConfirmation(
    'Delivery Confirmation Dialog Opened order=$orderId',
  );

  return showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _DeliveryConfirmationSheet(
        onConfirm: onConfirm,
        onReportIssue: () {
          onBeforeReportIssue?.call();
          Navigator.of(sheetContext).pop();
          onReportIssue();
        },
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF7C3AED).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF7C3AED).withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.fact_check_rounded,
                color: Color(0xFF7C3AED),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'يرجى تأكيد استلام الطلب لإكمال العملية.',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: Color(0xFF3B1B7A),
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
                textStyle: const TextStyle(
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
    required this.onReportIssue,
  });

  final Future<void> Function() onConfirm;
  final VoidCallback onReportIssue;

  @override
  State<_DeliveryConfirmationSheet> createState() =>
      _DeliveryConfirmationSheetState();
}

class _DeliveryConfirmationSheetState
    extends State<_DeliveryConfirmationSheet> {
  bool _submitting = false;
  bool _waitingForRealtime = false;

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

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.viewInsetsOf(context).bottom;

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
                  color: const Color(0xFFD0D5DD),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'تم تسليم الطلب',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Color(0xFF101828),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'أكد الطيار أنه قام بتسليم الطلب.\nهل استلمت طلبك بالفعل؟',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Color(0xFF667085),
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
                  color: AppTheme.success.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'تم إرسال التأكيد. بانتظار تحديث السيرفر الرسمي.',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: Color(0xFF1F8A5B),
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
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_circle_outline_rounded),
              label: const Text('استلمت الطلب'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _submitting || _waitingForRealtime
                  ? null
                  : widget.onReportIssue,
              icon: const Icon(Icons.report_problem_outlined),
              label: const Text('لم أستلم الطلب'),
            ),
          ],
        ),
      ),
    );
  }
}
