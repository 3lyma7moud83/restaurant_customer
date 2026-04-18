import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class AppLocalizations {
  const AppLocalizations(this.locale);

  final Locale locale;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [
    Locale('ar'),
    Locale('en'),
  ];

  static AppLocalizations of(BuildContext context) {
    final localization =
        Localizations.of<AppLocalizations>(context, AppLocalizations);
    assert(
      localization != null,
      'AppLocalizations is not available in the current BuildContext.',
    );
    return localization!;
  }

  bool get isArabic => locale.languageCode.toLowerCase() == 'ar';

  String tr(
    String key, {
    Map<String, String> args = const {},
  }) {
    final languageCode = locale.languageCode.toLowerCase();
    final languageMap =
        _localizedValues[languageCode] ?? _localizedValues['en']!;
    var resolved = languageMap[key] ?? _localizedValues['en']![key] ?? key;

    if (args.isEmpty) {
      return resolved;
    }

    for (final entry in args.entries) {
      resolved = resolved.replaceAll('{${entry.key}}', entry.value);
    }

    return resolved;
  }

  static const Map<String, Map<String, String>> _localizedValues = {
    'ar': {
      'app.name': 'delivery-mat3mk',
      'app.bootstrap_failed_title': 'تعذر تشغيل التطبيق',
      'app.bootstrap_env_error':
          'فشل تحميل إعدادات البيئة. تأكد من APP_ENV وملف assets/env/app.env.',
      'app.bootstrap_supabase_error':
          'فشل تهيئة Supabase. تأكد من مفاتيح البيئة واتصال الإنترنت.',
      'app.bootstrap_session_error':
          'فشل تهيئة الجلسة. حاول تشغيل التطبيق مرة أخرى.',
      'common.retry': 'إعادة المحاولة',
      'common.enable_location': 'تفعيل الموقع',
      'common.search_restaurant_hint': 'ابحث عن مطعم...',
      'common.view_menu': 'عرض القائمة',
      'common.restaurant': 'مطعم',
      'common.or': 'أو',
      'common.currency': '{value} ج',
      'common.minutes': 'د',
      'common.open_cart': 'فتح السلة',
      'home.nearby_restaurants': 'مطاعم قريبة منك',
      'home.restaurant_data_incomplete': 'بيانات المطعم غير مكتملة حالياً.',
      'home.location_needed_title': 'نحتاج موقعك',
      'home.location_needed_subtitle': 'علشان نعرض المطاعم القريبة منك',
      'home.empty_nearby_title': 'مفيش مطاعم قريبة دلوقتي',
      'home.empty_location_disabled_subtitle':
          'الموقع غير مفعل حالياً. فعّل الموقع لعرض نتائج أدق.',
      'home.empty_general_subtitle': 'جرّب تغير المكان أو ترجع بعدين',
      'home.enable_location_again': 'إعادة تفعيل الموقع',
      'home.error_title': 'تعذر تحميل المطاعم',
      'home.error_subtitle': 'تحقق من الاتصال ثم أعد المحاولة.',
      'home.guest_welcome': 'أهلاً بيك',
      'home.loading_account': 'جار تحميل الحساب...',
      'home.customer_account': 'حساب العميل',
      'home.login_to_order': 'سجل الدخول لطلب اوردر',
      'home.profile': 'الملف الشخصي',
      'home.orders': 'طلباتي',
      'home.logout': 'تسجيل الخروج',
      'home.sign_in_for_cart': 'سجل الدخول أولاً لفتح السلة.',
      'home.cart_open_failed': 'تعذر فتح السلة حالياً.',
      'restaurants.all': 'كل المطاعم',
      'restaurants.empty_title': 'لا توجد مطاعم حالياً',
      'restaurants.empty_subtitle':
          'جرّب تغيير البحث أو إعادة المحاولة لاحقاً.',
      'restaurants.refresh': 'تحديث',
      'restaurants.error_title': 'تعذر تحميل المطاعم',
      'restaurants.error_subtitle': 'تحقق من الاتصال ثم أعد المحاولة.',
      'menu.locked_order_notice':
          'لديك طلب جاري. تابع الطلب الحالي قبل إضافة طلب جديد.',
      'menu.locked_cart_message':
          'السلة مرتبطة بطلب جاري حتى يكتمل أو يتم رفضه.',
      'menu.select_category_first': 'اختار نوع الأول',
      'menu.no_items_here': 'لا توجد أصناف هنا',
      'menu.default_item': 'صنف',
      'menu.sign_in_for_cart': 'سجل الدخول أولاً للوصول إلى السلة.',
      'cart.title': 'السلة',
      'cart.profile_load_error': 'تعذر تحميل بيانات العميل حالياً.',
      'cart.location_pick_error': 'تعذر تحديد الموقع، حاول مرة أخرى.',
      'cart.address_required': 'اكتب عنوان التوصيل قبل المتابعة.',
      'cart.empty': 'السلة فارغة.',
      'cart.pick_location_first': 'حدد عنوان التوصيل من الخريطة أولاً.',
      'cart.profile_save_error': 'تعذر حفظ بيانات العميل حالياً.',
      'cart.items_section': 'الأصناف',
      'cart.customer_section': 'بيانات العميل',
      'cart.name': 'الاسم',
      'cart.phone': 'رقم الهاتف',
      'cart.ask_before_first_order': 'سيتم طلبه قبل تأكيد أول طلب',
      'cart.address_section': 'عنوان التوصيل',
      'cart.select_location': 'تحديد الموقع',
      'cart.delivery_address': 'عنوان التوصيل',
      'cart.delivery_address_hint':
          'حدد الموقع من الخريطة ثم عدّل العنوان إذا لزم',
      'cart.house_number': 'رقم البيت',
      'cart.house_number_hint': 'مثال: 12',
      'cart.payment_section': 'طريقة الدفع',
      'cart.payment_cash': 'الدفع نقدًا',
      'cart.payment_cash_subtitle': 'ادفع عند الاستلام',
      'cart.payment_visa': 'Visa',
      'cart.payment_visa_soon': 'قريبًا',
      'cart.select_payment_first': 'اختر وسيلة الدفع قبل إتمام الطلب.',
      'cart.price_summary': 'ملخص السعر',
      'cart.subtotal': 'سعر الطلب',
      'cart.delivery': 'التوصيل',
      'cart.total': 'الإجمالي',
      'cart.select_on_map': 'تحديد الموقع على الخريطة',
      'cart.confirm_order_total': 'تأكيد الطلب · {total}',
      'cart.track_current_order': 'متابعة الطلب الحالي',
      'cart.active_order': 'طلب جاري',
      'cart.active_order_locked_message':
          'تم حفظ السلة حتى يكتمل هذا الطلب أو يتم رفضه.',
      'cart.order_number': 'رقم الطلب: {id}',
      'cart.open_order': 'فتح الطلب',
      'cart.empty_title': 'السلة فارغة',
      'cart.empty_subtitle':
          'أضف بعض الأصناف من قائمة المطعم ثم ارجع هنا لتأكيد الطلب.',
      'cart.write_name': 'اكتب الاسم.',
      'cart.invalid_phone': 'رقم الهاتف غير صحيح.',
      'cart.complete_order_data': 'أكمل بيانات الطلب',
      'cart.complete_order_data_subtitle':
          'سنحفظ الاسم ورقم الهاتف في حسابك لاستخدامهما تلقائياً في الطلبات القادمة.',
      'cart.save_and_continue': 'حفظ ومتابعة الطلب',
      'auth.invalid_email': 'اكتب بريد إلكتروني صحيح.',
      'auth.password_required': 'كلمة المرور مطلوبة.',
      'auth.name_required': 'اكتب الاسم أولاً.',
      'auth.invalid_phone': 'رقم الهاتف غير صحيح.',
      'auth.account_created_check_email':
          'تم إنشاء الحساب. راجع بريدك ثم سجّل الدخول.',
      'auth.google_cancelled': 'تم إلغاء تسجيل الدخول عبر Google.',
      'auth.google_redirecting': 'جار تحويلك إلى Google لإكمال تسجيل الدخول...',
      'auth.google_failed_generic':
          'تعذر تسجيل الدخول عبر Google حالياً. حاول مرة أخرى.',
      'auth.login_success': 'تم تسجيل الدخول بنجاح.',
      'auth.title': 'الدخول إلى حسابك',
      'auth.subtitle_login':
          'سجّل دخولك بسرعة لمتابعة الطلبات واستقبال الإشعارات.',
      'auth.subtitle_register': 'أنشئ حسابك بخطوات بسيطة ثم أكمل أول طلبك.',
      'auth.login_tab': 'تسجيل دخول',
      'auth.register_tab': 'حساب جديد',
      'auth.name': 'الاسم',
      'auth.name_hint': 'اسمك الكامل',
      'auth.phone': 'رقم الهاتف',
      'auth.phone_hint': 'مثال: 01000000000',
      'auth.email': 'البريد الإلكتروني',
      'auth.password': 'كلمة المرور',
      'auth.login_button': 'تسجيل الدخول',
      'auth.create_account_button': 'إنشاء الحساب',
      'auth.continue_google': 'المتابعة عبر Google',
      'auth.terms':
          'بالمتابعة أنت توافق على استخدام حسابك لحفظ الطلبات والإشعارات.',
      'auth.hero_title': 'تجربة دخول أسرع\nوأهدأ',
      'auth.hero_subtitle':
          'واجهة نظيفة، دخول آمن، وتحديثات طلباتك تصل فوراً بمجرد تفعيل الإشعارات.',
      'lang.toggle': 'AR | EN',
      'lang.current_ar': 'AR',
      'lang.current_en': 'EN',
    },
    'en': {
      'app.name': 'delivery-mat3mk',
      'app.bootstrap_failed_title': 'Unable to start the app',
      'app.bootstrap_env_error':
          'Failed to load environment settings. Check APP_ENV and assets/env/app.env.',
      'app.bootstrap_supabase_error':
          'Failed to initialize Supabase. Check environment keys and your connection.',
      'app.bootstrap_session_error':
          'Failed to initialize session. Please restart the app.',
      'common.retry': 'Retry',
      'common.enable_location': 'Enable Location',
      'common.search_restaurant_hint': 'Search for a restaurant...',
      'common.view_menu': 'View menu',
      'common.restaurant': 'Restaurant',
      'common.or': 'OR',
      'common.currency': '{value} EGP',
      'common.minutes': 'min',
      'common.open_cart': 'Open Cart',
      'home.nearby_restaurants': 'Nearby Restaurants',
      'home.restaurant_data_incomplete':
          'Restaurant data is currently incomplete.',
      'home.location_needed_title': 'We need your location',
      'home.location_needed_subtitle':
          'So we can show restaurants close to you',
      'home.empty_nearby_title': 'No nearby restaurants right now',
      'home.empty_location_disabled_subtitle':
          'Location is off. Enable it to get accurate results.',
      'home.empty_general_subtitle': 'Try another area or check back later',
      'home.enable_location_again': 'Enable Location Again',
      'home.error_title': 'Could not load restaurants',
      'home.error_subtitle': 'Check your connection and try again.',
      'home.guest_welcome': 'Welcome',
      'home.loading_account': 'Loading account...',
      'home.customer_account': 'Customer Account',
      'home.login_to_order': 'Sign in to place an order',
      'home.profile': 'Profile',
      'home.orders': 'My Orders',
      'home.logout': 'Sign Out',
      'home.sign_in_for_cart': 'Sign in first to open your cart.',
      'home.cart_open_failed': 'Unable to open cart right now.',
      'restaurants.all': 'All Restaurants',
      'restaurants.empty_title': 'No restaurants available',
      'restaurants.empty_subtitle':
          'Try a different search or check again later.',
      'restaurants.refresh': 'Refresh',
      'restaurants.error_title': 'Could not load restaurants',
      'restaurants.error_subtitle': 'Check your connection and try again.',
      'menu.locked_order_notice':
          'You have an active order. Track it before adding a new one.',
      'menu.locked_cart_message':
          'Your cart is linked to an active order until it is completed or rejected.',
      'menu.select_category_first': 'Select a category first',
      'menu.no_items_here': 'No items in this category',
      'menu.default_item': 'Item',
      'menu.sign_in_for_cart': 'Sign in first to access the cart.',
      'cart.title': 'Cart',
      'cart.profile_load_error': 'Unable to load customer data right now.',
      'cart.location_pick_error':
          'Could not detect location, please try again.',
      'cart.address_required': 'Enter a delivery address before continuing.',
      'cart.empty': 'Your cart is empty.',
      'cart.pick_location_first': 'Pick delivery address from the map first.',
      'cart.profile_save_error': 'Unable to save customer data right now.',
      'cart.items_section': 'Items',
      'cart.customer_section': 'Customer Details',
      'cart.name': 'Name',
      'cart.phone': 'Phone',
      'cart.ask_before_first_order':
          'We will ask for it before confirming your first order',
      'cart.address_section': 'Delivery Address',
      'cart.select_location': 'Select Location',
      'cart.delivery_address': 'Delivery Address',
      'cart.delivery_address_hint':
          'Pick from map, then edit address if needed',
      'cart.house_number': 'House Number',
      'cart.house_number_hint': 'Example: 12',
      'cart.payment_section': 'Payment Method',
      'cart.payment_cash': 'Cash',
      'cart.payment_cash_subtitle': 'Pay on delivery',
      'cart.payment_visa': 'Visa',
      'cart.payment_visa_soon': 'Coming soon',
      'cart.select_payment_first':
          'Choose a payment method before confirming the order.',
      'cart.price_summary': 'Price Summary',
      'cart.subtotal': 'Subtotal',
      'cart.delivery': 'Delivery',
      'cart.total': 'Total',
      'cart.select_on_map': 'Select location on map',
      'cart.confirm_order_total': 'Confirm Order · {total}',
      'cart.track_current_order': 'Track Current Order',
      'cart.active_order': 'Active Order',
      'cart.active_order_locked_message':
          'Your cart is preserved until this order is completed or rejected.',
      'cart.order_number': 'Order # {id}',
      'cart.open_order': 'Open Order',
      'cart.empty_title': 'Cart is empty',
      'cart.empty_subtitle':
          'Add items from the restaurant menu, then return here to confirm.',
      'cart.write_name': 'Please enter your name.',
      'cart.invalid_phone': 'Invalid phone number.',
      'cart.complete_order_data': 'Complete order details',
      'cart.complete_order_data_subtitle':
          'We will save your name and phone to auto-fill future orders.',
      'cart.save_and_continue': 'Save and Continue',
      'auth.invalid_email': 'Enter a valid email address.',
      'auth.password_required': 'Password is required.',
      'auth.name_required': 'Enter your name first.',
      'auth.invalid_phone': 'Invalid phone number.',
      'auth.account_created_check_email':
          'Account created. Check your email, then sign in.',
      'auth.google_cancelled': 'Google sign-in was cancelled.',
      'auth.google_redirecting': 'Redirecting to Google to continue sign-in...',
      'auth.google_failed_generic':
          'Unable to sign in with Google right now. Please try again.',
      'auth.login_success': 'Signed in successfully.',
      'auth.title': 'Sign in to your account',
      'auth.subtitle_login':
          'Sign in quickly to track orders and receive notifications.',
      'auth.subtitle_register':
          'Create your account in a few steps, then place your first order.',
      'auth.login_tab': 'Sign In',
      'auth.register_tab': 'New Account',
      'auth.name': 'Name',
      'auth.name_hint': 'Your full name',
      'auth.phone': 'Phone Number',
      'auth.phone_hint': 'Example: 01000000000',
      'auth.email': 'Email',
      'auth.password': 'Password',
      'auth.login_button': 'Sign In',
      'auth.create_account_button': 'Create Account',
      'auth.continue_google': 'Continue with Google',
      'auth.terms':
          'By continuing, you agree to use your account for orders and notifications.',
      'auth.hero_title': 'Faster sign in\nless friction',
      'auth.hero_subtitle':
          'Clean interface, secure login, and instant order updates once notifications are enabled.',
      'lang.toggle': 'AR | EN',
      'lang.current_ar': 'AR',
      'lang.current_en': 'EN',
    },
  };
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (supportedLocale) => supportedLocale.languageCode == locale.languageCode,
    );
  }

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(AppLocalizations(locale));
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppLocalizationContextX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  String tr(
    String key, {
    Map<String, String> args = const {},
  }) {
    return l10n.tr(key, args: args);
  }
}
