import '../core/cache/local_reference_cache.dart';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

enum AppContentSection {
  supportSettings('support_settings'),
  privacyPolicy('privacy_policy'),
  securityPolicy('security_policy'),
  appSettings('app_settings');

  const AppContentSection(this.keyName);
  final String keyName;
}

@visibleForTesting
bool shouldFetchEnglishContentFallback({
  required String language,
  required bool hasCurrentLanguageEntry,
}) {
  return language != 'en' && !hasCurrentLanguageEntry;
}

@visibleForTesting
bool isAppContentCacheFresh({
  required DateTime cachedAt,
  required DateTime now,
  Duration ttl = const Duration(minutes: 10),
}) {
  return now.difference(cachedAt) <= ttl;
}

class AppContentEntry {
  const AppContentEntry({
    required this.id,
    required this.section,
    required this.title,
    required this.content,
    required this.language,
    required this.isActive,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final AppContentSection section;
  final String title;
  final String content;
  final String language;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory AppContentEntry.fromRow(Map<String, dynamic> row) {
    final keyName = (row['entry_key'] ?? '').toString().trim();
    final section = AppContentSection.values.firstWhere(
      (value) => value.keyName == keyName,
      orElse: () => AppContentSection.supportSettings,
    );

    final createdAt = DateTime.tryParse((row['created_at'] ?? '').toString()) ??
        DateTime.now().toUtc();
    final updatedAt =
        DateTime.tryParse((row['updated_at'] ?? '').toString()) ?? createdAt;

    return AppContentEntry(
      id: (row['id'] ?? '').toString(),
      section: section,
      title: _normalizeBrandingForDisplay(
        (row['title'] ?? '').toString().trim(),
      ),
      content: _normalizeBrandingForDisplay(
        (row['content'] ?? '').toString().trim(),
      ),
      language: (row['language'] ?? '').toString().trim().toLowerCase(),
      isActive: row['is_active'] == true,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

String _normalizeBrandingForDisplay(String value) {
  if (value.isEmpty) {
    return value;
  }

  var normalized = value;
  normalized = normalized.replaceAllMapped(
    RegExp(r'support@delivery-mat3mk\.com', caseSensitive: false),
    (_) => 'support@deliverymat3mk.com',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'delivery-mat3mk', caseSensitive: false),
    (_) => 'Delivery Mat3mk',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'restaurant_(customer|driver|admin)', caseSensitive: false),
    (_) => 'Delivery Mat3mk',
  );
  normalized = normalized.replaceAllMapped(
    RegExp(r'mat3amak', caseSensitive: false),
    (_) => 'Delivery Mat3mk',
  );
  return normalized;
}

class AppContentService {
  AppContentService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static final _local = LocalReferenceCache('customer_content');

  static const String _selectFields = '''
    id,
    entry_key,
    title,
    content,
    language,
    is_active,
    created_at,
    updated_at
  ''';

  static Future<AppContentEntry> fetchEntry({
    required AppContentSection section,
    required Locale locale,
    bool forceRefresh = false,
  }) async {
    final language = locale.languageCode.toLowerCase() == 'ar' ? 'ar' : 'en';
    try {
      final currentLanguageEntry = await _fetchEntryByLanguage(
        section: section,
        language: language,
        forceRefresh: forceRefresh,
      );
      final fallbackEnglishEntry = shouldFetchEnglishContentFallback(
        language: language,
        hasCurrentLanguageEntry: currentLanguageEntry != null,
      )
          ? await _fetchEntryByLanguage(
              section: section,
              language: 'en',
              forceRefresh: forceRefresh,
            )
          : null;

      final resolved = currentLanguageEntry ??
          fallbackEnglishEntry ??
          _fallbackEntry(section: section, language: language);
      return resolved;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'app_content_service.fetchEntry',
        error: error,
        stack: stack,
      );
      return _fallbackEntry(section: section, language: language);
    }
  }

  static Future<AppContentEntry?> _fetchEntryByLanguage({
    required AppContentSection section,
    required String language,
    bool forceRefresh = false,
  }) async {
    final user = _client.auth.currentUser?.id ?? 'anonymous';
    final rows = await _local.read(
        scope: user,
        key: '${section.keyName}:$language',
        ttl: section == AppContentSection.appSettings
            ? const Duration(minutes: 10)
            : const Duration(hours: 1),
        forceRefresh: forceRefresh,
        isCurrent: () => (_client.auth.currentUser?.id ?? 'anonymous') == user,
        load: () async {
          final result = await SessionManager.instance
              .runWithValidSession<List<dynamic>>(() => _client
                  .from('app_content_entries')
                  .select(_selectFields)
                  .eq('entry_key', section.keyName)
                  .eq('language', language)
                  .eq('is_active', true)
                  .order('updated_at', ascending: false)
                  .limit(1));
          if (result == null) throw StateError('Content unavailable');
          return result
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList();
        });
    return rows.isEmpty ? null : AppContentEntry.fromRow(rows.first);
  }

  static AppContentEntry _fallbackEntry({
    required AppContentSection section,
    required String language,
  }) {
    final isArabic = language == 'ar';
    final now = DateTime.now().toUtc();
    final defaults = _fallbackContent[section]!;
    return AppContentEntry(
      id: 'local-${section.keyName}-$language',
      section: section,
      title: isArabic ? defaults.titleAr : defaults.titleEn,
      content: isArabic ? defaults.contentAr : defaults.contentEn,
      language: language,
      isActive: true,
      createdAt: now,
      updatedAt: now,
    );
  }

  static const Map<AppContentSection, _FallbackContent> _fallbackContent = {
    AppContentSection.supportSettings: _FallbackContent(
      titleAr: 'الدعم الفني',
      titleEn: 'Technical Support',
      contentAr:
          'للمساعدة الفنية المتعلقة بالتطبيق أو الطلبات، تواصل مع فريق الدعم عبر:\n'
          'البريد: support@deliverymat3mk.com\n'
          'الهاتف: +20 100 000 0000\n'
          'ساعات الدعم: يوميًا من 10:00 صباحًا حتى 10:00 مساءً.\n'
          'يرجى إرفاق رقم الطلب ووصف واضح للمشكلة لتسريع المعالجة.',
      contentEn:
          'For technical assistance related to the app or orders, contact support:\n'
          'Email: support@deliverymat3mk.com\n'
          'Phone: +20 100 000 0000\n'
          'Support hours: Daily from 10:00 AM to 10:00 PM.\n'
          'Please include your order number and a clear issue description.',
    ),
    AppContentSection.privacyPolicy: _FallbackContent(
      titleAr: 'سياسة الخصوصية',
      titleEn: 'Privacy Policy',
      contentAr:
          'نلتزم بحماية بياناتك الشخصية. نستخدم بيانات الحساب والعنوان فقط لتقديم الخدمة وتحسين جودة الطلبات.\n'
          'لا نشارك معلوماتك مع أي طرف ثالث خارج نطاق التشغيل أو المتطلبات القانونية.\n'
          'يمكنك طلب تحديث أو حذف بياناتك الشخصية من خلال الدعم الفني.',
      contentEn:
          'We are committed to protecting your personal data. Account and address data are used only to provide service and improve order quality.\n'
          'We do not share your information with third parties outside operational or legal requirements.\n'
          'You may request data updates or deletion through technical support.',
    ),
    AppContentSection.securityPolicy: _FallbackContent(
      titleAr: 'الحماية والأمان',
      titleEn: 'Protection & Security',
      contentAr:
          'نطبق ضوابط أمان تشغيلية لحماية الحسابات والاتصالات داخل التطبيق.\n'
          'يتم مراقبة الأخطاء الفنية ومحاولات الاستخدام غير المعتاد لتحسين الأمان والاستقرار.\n'
          'ننصح بعدم مشاركة رمز التحقق أو بيانات تسجيل الدخول مع أي جهة.',
      contentEn:
          'We apply operational security controls to protect accounts and in-app communication.\n'
          'Technical errors and unusual activity are monitored to improve security and stability.\n'
          'Do not share verification codes or login credentials with anyone.',
    ),
    AppContentSection.appSettings: _FallbackContent(
      titleAr: 'رقم الإصدار',
      titleEn: 'App Version',
      contentAr: 'v1.0.0',
      contentEn: 'v1.0.0',
    ),
  };
}

class _FallbackContent {
  const _FallbackContent({
    required this.titleAr,
    required this.titleEn,
    required this.contentAr,
    required this.contentEn,
  });

  final String titleAr;
  final String titleEn;
  final String contentAr;
  final String contentEn;
}
