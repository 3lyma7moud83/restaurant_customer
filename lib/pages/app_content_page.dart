import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../services/app_content_service.dart';

class AppContentPage extends StatefulWidget {
  const AppContentPage({
    super.key,
    required this.section,
    required this.fallbackTitle,
  });

  final AppContentSection section;
  final String fallbackTitle;

  @override
  State<AppContentPage> createState() => _AppContentPageState();
}

class _AppContentPageState extends State<AppContentPage> {
  Locale? _loadedLocale;
  Future<AppContentEntry>? _entryFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final locale = Localizations.localeOf(context);
    if (_entryFuture == null || _loadedLocale != locale) {
      _loadedLocale = locale;
      _entryFuture = AppContentService.fetchEntry(
        section: widget.section,
        locale: locale,
      );
    }
  }

  Future<void> _refresh() async {
    final locale = Localizations.localeOf(context);
    final nextFuture = AppContentService.fetchEntry(
      section: widget.section,
      locale: locale,
      forceRefresh: true,
    );
    setState(() => _entryFuture = nextFuture);
    await nextFuture;
  }

  IconData _iconForSection(AppContentSection section) {
    return switch (section) {
      AppContentSection.supportSettings => Icons.support_agent_rounded,
      AppContentSection.privacyPolicy => Icons.privacy_tip_outlined,
      AppContentSection.securityPolicy => Icons.shield_outlined,
      AppContentSection.appSettings => Icons.info_outline_rounded,
    };
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.fallbackTitle;
    final icon = _iconForSection(widget.section);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<AppContentEntry>(
        future: _entryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final entry = snapshot.data;
          if (entry == null) {
            return Center(
              child: Text(
                context.tr('drawer.content_unavailable'),
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: AppTheme.bouncingScrollPhysics,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFF5A652), Color(0xFFE37E18)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.primary.withValues(alpha: 0.25),
                        blurRadius: 18,
                        offset: const Offset(0, 9),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(icon, color: Colors.white),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            entry.title.isEmpty ? title : entry.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.border.withValues(alpha: 0.96),
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x12000000),
                        blurRadius: 14,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                    child: Text(
                      entry.content,
                      style: const TextStyle(
                        color: AppTheme.text,
                        fontSize: 14.2,
                        fontWeight: FontWeight.w600,
                        height: 1.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
