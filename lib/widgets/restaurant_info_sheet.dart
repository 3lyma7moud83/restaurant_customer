import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import '../core/theme/app_theme.dart';
import '../pages/auth/login_page.dart';
import '../services/restaurants_service.dart';

Future<void> showRestaurantInfoSheet(
  BuildContext context, {
  required Map<String, dynamic> restaurant,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RestaurantInfoSheet(restaurant: restaurant),
  );
}

class _RestaurantInfoSheet extends StatefulWidget {
  const _RestaurantInfoSheet({
    required this.restaurant,
  });

  final Map<String, dynamic> restaurant;

  @override
  State<_RestaurantInfoSheet> createState() => _RestaurantInfoSheetState();
}

class _RestaurantInfoSheetState extends State<_RestaurantInfoSheet> {
  late final Future<Map<String, dynamic>> _detailsFuture;

  @override
  void initState() {
    super.initState();
    _detailsFuture = RestaurantsService.getRestaurantDetails(
      RestaurantsService.restaurantIdOf(widget.restaurant),
      fallbackData: widget.restaurant,
    );
  }

  Future<void> _openComplaintSheet(Map<String, dynamic> details) async {
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _ComplaintSheet(
        restaurantId: RestaurantsService.restaurantIdOf(details),
        restaurantName: RestaurantsService.restaurantNameOf(details),
      ),
    );

    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم إرسال الشكوى وسيتم مراجعتها قريباً.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
        child: FutureBuilder<Map<String, dynamic>>(
          future: _detailsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 360,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            final details = snapshot.data ?? widget.restaurant;

            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) {
                return Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, (1 - value) * 24),
                    child: child,
                  ),
                );
              },
              child: _RestaurantInfoContent(
                details: details,
                onComplaintTap: () => _openComplaintSheet(details),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _RestaurantInfoContent extends StatelessWidget {
  const _RestaurantInfoContent({
    required this.details,
    required this.onComplaintTap,
  });

  final Map<String, dynamic> details;
  final VoidCallback onComplaintTap;

  @override
  Widget build(BuildContext context) {
    final imageUrl = RestaurantsService.restaurantImageOf(details);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 168,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFFF4E6D9),
                  Color(0xFFE8EFE8),
                ],
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (imageUrl != null && imageUrl.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Image.network(
                      imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.06),
                        Colors.black.withValues(alpha: 0.42),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'معلومات المطعم',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        RestaurantsService.restaurantNameOf(details),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _InfoTile(
            icon: Icons.location_on_outlined,
            title: 'العنوان',
            value: RestaurantsService.restaurantAddressOf(details),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SmallInfoTile(
                  icon: Icons.schedule_outlined,
                  title: 'يفتح',
                  value: RestaurantsService.openingTimeOf(details),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SmallInfoTile(
                  icon: Icons.nightlight_outlined,
                  title: 'يغلق',
                  value: RestaurantsService.closingTimeOf(details),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: onComplaintTap,
            icon: const Icon(Icons.report_gmailerrorred_rounded),
            label: const Text('إرسال شكوى'),
          ),
        ],
      ),
    );
  }
}

class _ComplaintSheet extends StatefulWidget {
  const _ComplaintSheet({
    required this.restaurantId,
    required this.restaurantName,
  });

  final String restaurantId;
  final String restaurantName;

  @override
  State<_ComplaintSheet> createState() => _ComplaintSheetState();
}

class _ComplaintSheetState extends State<_ComplaintSheet> {
  final TextEditingController _messageController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      _showSnack('اكتب الشكوى أولاً.');
      return;
    }

    var user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const LoginPage()),
      );
      user = Supabase.instance.client.auth.currentUser;
      if (user == null) {
        if (!mounted) {
          return;
        }
        _showSnack('سجل الدخول لإرسال الشكوى.');
        return;
      }
    }

    setState(() => _sending = true);

    try {
      await RestaurantsService.submitComplaint(
        restaurantId: widget.restaurantId,
        customerId: user.id,
        message: message,
      );

      if (!mounted) {
        return;
      }
      Navigator.pop(context, true);
    } catch (_) {
      _showSnack(ErrorLogger.userMessage);
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
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
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'شكوى تخص ${widget.restaurantName}',
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'اكتب رسالتك بوضوح وسيتم إرسالها لإدارة المطعم للمراجعة.',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Color(0xFF667085),
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _messageController,
              minLines: 4,
              maxLines: 6,
              textAlign: TextAlign.right,
              decoration: const InputDecoration(
                hintText: 'اكتب تفاصيل الشكوى هنا',
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _sending ? null : _submit,
              child: _sending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('إرسال الشكوى'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: AppTheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
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
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.45,
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

class _SmallInfoTile extends StatelessWidget {
  const _SmallInfoTile({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppTheme.secondary),
              const Spacer(),
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF667085),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppTheme.text,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
