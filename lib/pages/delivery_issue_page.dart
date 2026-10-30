import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ui/app_motion.dart';

import '../core/orders/order_ui.dart';
import '../core/theme/app_theme.dart';
import '../core/ui/app_snackbar.dart';
import '../services/orders_service.dart';

class DeliveryIssuePage extends StatefulWidget {
  const DeliveryIssuePage({
    super.key,
    required this.order,
  });

  final Map<String, dynamic> order;

  @override
  State<DeliveryIssuePage> createState() => _DeliveryIssuePageState();
}

class _DeliveryIssuePageState extends State<DeliveryIssuePage> {
  static const List<String> _reasons = [
    'الطيار لم يصل',
    'لم أستلم أي طلب',
    'الطلب ناقص',
    'الطلب مختلف',
    'سبب آخر',
  ];

  String? _selectedReason;
  bool _submitting = false;

  Future<void> reportDeliveryIssue(String reason) async {
    if (_submitting) {
      return;
    }

    setState(() {
      _selectedReason = reason;
      _submitting = true;
    });

    try {
      await OrdersService.reportDeliveryIssue(
        widget.order,
        reason: reason,
      );
      if (!mounted) {
        return;
      }
      AppSnackBar.show(
        context,
        message: 'تم إرسال الاعتراض بنجاح. سنتابع الطلب معك.',
      );
      Navigator.pop(context, true);
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
    final orderId = OrdersService.shortIdOf(widget.order);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('اعتراض على التسليم'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          physics: AppTheme.bouncingScrollPhysics,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            OrderSectionCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    orderId.isEmpty ? 'اختر سبب الاعتراض' : 'طلب #$orderId',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'اختر السبب الأقرب لما حدث حتى يتمكن فريق الدعم من المتابعة.',
                    style: TextStyle(
                      color: AppTheme.colorsOf(context).textSecondary,
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ..._reasons.map(
              (reason) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _DeliveryIssueReasonTile(
                  reason: reason,
                  selected: _selectedReason == reason,
                  submitting: _submitting,
                  onTap: () => unawaited(reportDeliveryIssue(reason)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeliveryIssueReasonTile extends StatelessWidget {
  const _DeliveryIssueReasonTile({
    required this.reason,
    required this.selected,
    required this.submitting,
    required this.onTap,
  });

  final String reason;
  final bool selected;
  final bool submitting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = !submitting;

    return ScaleOnTap(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration:
            AppMotion.duration(context, AppTheme.microInteractionDuration),
        curve: AppTheme.emphasizedCurve,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            if (selected && submitting)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              )
            else
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : AppTheme.colorsOf(context).textSecondary,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                reason,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
