# تقرير فحص تقني عميق (Flutter) — `restaurant_customer`

تاريخ الفحص: **2026-03-14**

## نتائج سريعة

- `flutter analyze`: لا توجد مشاكل تحليل ثابت.
- `flutter test`: جميع الاختبارات نجحت (2 tests).

## 1) Bugs / Exceptions (وقت التشغيل)

### (حرج) AnimationController قد يُستدعى بعد `dispose()` — **تم الإصلاح**

- **المكان:** `lib/pages/restaurant_menu_page.dart:377`
- **السبب الحقيقي:** `reverse().then(...)` قد يُكمل بعد خروج الـ Widget من الشجرة، ثم يتم استدعاء `forward()` على `AnimationController` تم التخلص منه → Exception مثل: *"AnimationController.forward called after dispose"*.
- **الإصلاح:** إضافة `if (!mounted) return;` داخل الـ `then`.
- **الحالة:** Fixed ✅

### (حرج) احتمال `setState()` بعد `await Navigator.push` في BottomSheet — **تم الإصلاح**

- **المكان:** `lib/widgets/restaurant_info_sheet.dart:280` (الـ navigation) و `lib/widgets/restaurant_info_sheet.dart:296` (`setState`)
- **السبب الحقيقي:** بعد `await Navigator.of(context).push(...)` قد يتم التخلص من الـ BottomSheet (أو الـ State) ثم يتم تنفيذ `setState`/استخدام `context` → Exception.
- **الإصلاح:** إضافة `if (!mounted) return;` مباشرة بعد الرجوع من الـ Navigation وقبل `setState`، مع تسجيل الخطأ عند فشل الإرسال.
- **الحالة:** Fixed ✅

## 2) Null Safety / Async / Streams

- المشروع يمرّ بـ `flutter analyze` بدون تحذيرات، ومعظم أماكن `await` لديها حماية `mounted`.
- **تحسين مقترح:** تجنّب `catch (_) {}` الصامتة لأنها تُخفي السبب الحقيقي وتُصعّب دعم الأعطال (أمثلة بالأسفل).

## 3) Memory Leaks

### (عالي) `MapController` بدون `dispose()` — **تم الإصلاح**

- **المكان:** `lib/cart/select_address_page.dart:96`
- **السبب الحقيقي:** `flutter_map` يعرّف `MapController.dispose()`، وعدم استدعائها قد يترك Listeners/Streams داخلياً.
- **الإصلاح:** إضافة `_controller.dispose()` داخل `dispose()`.
- **الحالة:** Fixed ✅

## 4) Performance

### (حرج) Rebuild storm بسبب CartProvider يسبب إعادة بناء واسعة — **تم الإصلاح**

- **المكان:** `lib/cart/cart_provider.dart:54` و `lib/main.dart:65`
- **السبب الحقيقي:** التصميم السابق كان يعتمد على `State + setState` داخل `CartProviderWrapper` مع `updateShouldNotify=true` مما يؤدي لإعادة بناء واسعة (قد تصل لإعادة بناء `MaterialApp`/الشجرة) عند أي تغيير في السلة.
- **التأثير:** jank أثناء إضافة/حذف العناصر، وخصوصاً أثناء الكتابة في العنوان/رقم البيت (كانت تغييرات كل حرف تعمل rebuild + persist).
- **الإصلاح المنفّذ:**
  - تحويل `CartController` إلى `ChangeNotifier` وتقديمه عبر `InheritedNotifier` (يُحدّث الـ dependents بدون إعادة بناء `child`).
  - منع `notifyListeners()` أثناء typing في `setDeliveryAddress`/`setHouseNumber` مع إبقاء الـ persistence بـ debounce. (`lib/cart/cart_provider.dart:253`, `lib/cart/cart_provider.dart:265`)
- **الحالة:** Fixed ✅

### (متوسط) طلب الموقع داخل `_load()` قد يتكرر كثيراً

- **المكان:** `lib/pages/restaurants_page.dart:91`
- **السبب الحقيقي:** عند إعادة تحميل القائمة (بسبب Realtime أو بحث/تحديث) يتم استدعاء `LocationHelper.requestAndGetLocation()` مما قد يسبب تأخير وبطارية أعلى.
- **الاقتراح:**
  - كاش لآخر موقع صالح خلال الجلسة (مثلاً داخل State أو Service).
  - أو استخدم `getLastKnownPosition`/تقليل الدقة أو تحديث الموقع فقط عند طلب المستخدم.
- **الحالة:** Needs improvement (اختياري)

### (منخفض) كاش مطاعم ثابت بدون حد أعلى قد يزيد استهلاك الذاكرة

- **المكان:** `lib/services/restaurants_service.dart:10`
- **السبب الحقيقي:** `static Map` cache بدون سياسة إخلاء (eviction).
- **التأثير:** زيادة تدريجية في الذاكرة إذا زادت بيانات المطاعم/الأماكن.
- **الاقتراح:** LRU cache أو مسح الكاش عند signOut/تغيير حساب، أو تحديد حد أقصى للعناصر.

### (منخفض) صور الشبكة بدون Placeholder/Caching متقدم

- **أماكن بارزة:**
  - `lib/widgets/restaurant_card_components.dart:131`
  - `lib/widgets/restaurant_info_sheet.dart:152`
  - `lib/pages/restaurant_menu_page.dart:417`
- **المخاطر:** على أجهزة أضعف أو صور كبيرة قد يحدث jank أثناء التمرير.
- **الاقتراح:** إضافة placeholders، وضبط `cacheWidth/cacheHeight`، أو استخدام `cached_network_image` إذا لزم.

### (معلوماتي) لم يتم رصد عمليات ثقيلة داخل `build()` (شبكة/JSON) بشكل مباشر

- **ملاحظة:** لم يتم العثور على `jsonDecode(...)` أو `http.get(...)` أو استعلامات Supabase داخل `build()` مباشرةً (وهذا ممتاز للأداء).
- **الاقتراح:** حافظ على هذا النمط (اجعل التحميل داخل `initState`/services + memoization للفيوترات).

### (منخفض) `ListView(children: ...)` في بعض الصفحات

- **المكان:** `lib/cart/cart_page.dart:461` و `lib/pages/order_tracking_page.dart:249`
- **الملاحظة:** حالياً القوائم قصيرة (Cards ثابتة)، لكن لو زاد عدد العناصر بشكل كبير الأفضل استخدام `ListView.builder`.

### (متوسط) Realtime events قد تسبب Query storms في صفحات الطلبات/التتبع

- **أماكن بارزة:**
  - `lib/pages/order_tracking_page.dart:200` و `lib/pages/order_tracking_page.dart:208`
  - `lib/pages/order_details_page.dart:198` و `lib/pages/order_details_page.dart:206`
- **السبب الحقيقي:** كل تغيير Realtime يقوم بـ fetch جديد للطلب/العناصر من Supabase (بدلاً من استخدام payload أو debounce).
- **التأثير:** استهلاك بيانات/بطارية أعلى + احتمال lag + ضغط على Supabase (خصوصاً إذا كان هناك تحديثات كثيرة).
- **الاقتراح:**
  - Debounce/Throttle للـ refresh.
  - الاستفادة من `payload.newRecord` عندما يكون كافياً.
  - تحميل جزئي/ذكي بدل إعادة جلب كل شيء.

### (متوسط) لا يوجد timeout/retry واضح على طبقة التطبيق لمعظم استعلامات Supabase

- **الملاحظة:** استدعاءات Supabase لا تُغلّف بـ timeout أو retry policy موحّد (بعكس استدعاءات Mapbox عبر `http` والتي لديها `.timeout`).
- **التأثير:** على شبكات ضعيفة قد تتأخر الشاشات/تُعلّق لفترة أطول ويزيد احتمال أخطاء transient بدون إعادة محاولة.
- **الاقتراح:** إضافة wrapper في طبقة services يطبق `timeout` + retry (مع backoff) لبعض العمليات غير الحرجة، مع إظهار رسائل واضحة للمستخدم.

### (متوسط) `FlutterMap` داخل التتبع قد يُعاد إنشاؤه مع كل rebuild

- **المكان:** `lib/pages/order_tracking_page.dart:524`
- **السبب الحقيقي:** `_TrackingMapCard` هو `StatelessWidget` ويبني `FlutterMap` و `MapOptions(initialCenter/initialZoom)` في كل إعادة بناء للصفحة.
- **التأثير:** احتمال reset للكاميرا/إعادة تحميل tiles وحدوث jank عند تحديثات الطلب.
- **الاقتراح:** تحويل `_TrackingMapCard` إلى `StatefulWidget` مع `MapController` + تحديث markers/center فقط عند تغيّر الإحداثيات.

### (منخفض-متوسط) Shimmer لكل صورة يستخدم `AnimationController` مستقل

- **المكان:** `lib/widgets/restaurant_card_components.dart:238` و `lib/widgets/restaurant_card_components.dart:250`
- **السبب الحقيقي:** كل Card/صورة لها ticker يعمل `repeat()` حتى تحميل الصورة.
- **التأثير:** CPU/GPU أعلى أثناء تحميل الصور والتمرير على أجهزة ضعيفة.
- **الاقتراح:** Placeholder ثابت/خفيف في القوائم الكبيرة، أو تقليل استخدام shimmer، أو عزله داخل `RepaintBoundary`.

## 5) Security Audit

### (عالي) ملف `.env` يُشحن داخل التطبيق كـ Asset

- **المكان:** `pubspec.yaml:35`
- **السبب الحقيقي:** أي قيمة داخل `.env` ستكون قابلة للاستخراج من APK/IPA/Web bundle.
- **المطلوب:** لا تضع أسرار (مثل: Supabase `service_role`، مفاتيح خاصة، Tokens سرية).
- **بدائل:** `--dart-define`، Remote Config، أو Edge Functions (حسب الحاجة).
- **ملاحظة مهمة للبناء (Build):** لأن `.env` مذكور كـ asset، غيابه قد يسبب فشل build على أجهزة/CI جديدة. احرص على إنشاء `.env` أثناء الـ CI أو توفير مسار إعدادات بديل.

### (متوسط) `.env.example` يحتوي بيانات Supabase جاهزة

- **المكان:** `.env.example:2` و `.env.example:3`
- **ملاحظة:** مفتاح Supabase `anon` غالباً مُصمم ليكون عامًا في تطبيقات العميل، لكن الأمان الحقيقي يعتمد على **RLS**.
- **تحقق من:** تفعيل RLS وسياسات تمنع قراءة/تعديل بيانات الآخرين لكل الجداول المستخدمة.

### (عالي) Logging إلى جدول Supabase من العميل

- **المكان:** `lib/core/services/error_logger.dart:29`
- **المخاطر المحتملة:**
  - إذا كان الـ RLS يسمح بالقراءة قد يحدث تسريب Stack traces/PII.
  - إمكانية spam على جدول الأخطاء من العملاء.
- **الاقتراح:** سياسات RLS صارمة (Insert فقط، بدون Select)، أو توجيه التسجيل لـ Edge Function مع rate limiting.

### (متوسط) تخزين بيانات عنوان/طلب داخل `SharedPreferences` (غير مُشفّر)

- **المكان:** `lib/cart/cart_provider.dart:428`
- **السبب الحقيقي:** `SharedPreferences` تخزين نصي يمكن استخراجه من backup/أجهزة rooted.
- **التأثير:** تسريب محتمل لـ PII (عنوان التوصيل/رقم البيت) ومعرّف الطلب النشط.
- **الاقتراح:** تقليل ما يُحفظ، أو استخدام تخزين مُشفّر (`flutter_secure_storage`) للبيانات الحساسة، والنظر في تعطيل backup إن كانت سياسة التطبيق تسمح.

### (متوسط) التحقق الأمني الحقيقي يعتمد على RLS (لا تعتمد على filters من العميل)

- **أماكن بارزة:** `lib/pages/order_details_page.dart:112` و `lib/pages/order_tracking_page.dart:114` (استدعاء `getOrderById` مباشرةً)
- **السبب الحقيقي:** أي عميل معدل يمكنه محاولة جلب `orderId` ليس له إذا كانت سياسات RLS غير محكمة.
- **الاقتراح:** تأكد من RLS لكل الجداول الحساسة، ويفضل أيضاً تمرير `userId` عند الاستعلامات حيثما أمكن لزيادة الأمان الدفاعي.

## 6) Android Configuration

### (عالي) Release signing غير مضبوط للإنتاج — **تم التحسين**

- **المكان:** `android/app/build.gradle:47` و `android/app/build.gradle:60`
- **السبب الحقيقي:** استخدام debug keystore للـ release مناسب للتجربة فقط، وليس للنشر على المتاجر.
- **الإصلاح المنفّذ:** إضافة دعم `key.properties` (release keystore) مع fallback تلقائي إلى debug عند عدم توفره.
- **المطلوب للنشر:** إنشاء keystore، وتوليد `key.properties` في CI/CD (بدون commit)، والتأكد من اختبار build release قبل الإطلاق.

### (عالي) Mapbox Maven Downloads Token مطلوب لبناء Android

- **الأماكن:**
  - `android/build.gradle:8`
  - `android/gradle.properties:8`
- **السبب الحقيقي:** Mapbox dependencies تحتاج `MAPBOX_DOWNLOADS_TOKEN` وإلا سيفشل Gradle (401).
- **الحل:** ضع التوكن في `~/.gradle/gradle.properties` أو متغير بيئة `MAPBOX_DOWNLOADS_TOKEN` (لا تضعه داخل repo).

### (معلوماتي) توافق Gradle / AGP / Kotlin

- **AGP:** `android/settings.gradle:21`
- **Kotlin:** `android/settings.gradle:22`
- **Gradle Wrapper:** `android/gradle/wrapper/gradle-wrapper.properties:5`
- **ملاحظة:** القيم الحالية تبدو متوافقة عادةً مع Flutter/AGP 8.x، لكن عند التحديث تأكد من تحديث الثلاثة معاً لتجنب build failures.

### (معلوماتي) Permissions

- **INTERNET:** `android/app/src/main/AndroidManifest.xml:4`
- **LOCATION:** `android/app/src/main/AndroidManifest.xml:8`

### (متوسط) `android:allowBackup` غير محدد (قد يسهّل استخراج بيانات التطبيق)

- **المكان:** `android/app/src/main/AndroidManifest.xml:11`
- **السبب الحقيقي:** عند تفعيل النسخ الاحتياطي (افتراضيًا حسب الإعدادات)، قد تُنسخ بيانات مثل `SharedPreferences`.
- **الاقتراح:** إذا كانت سياسة الأمان تتطلب ذلك، أضف `android:allowBackup="false"` و `android:fullBackupContent="false"` داخل `<application>`.

## 7) Code Quality / Architecture

### (منخفض) Dependence غير مستخدمة

- **المكان:** `pubspec.yaml:13`
- **الملاحظة:** `dio` غير مستخدم في الكود الحالي (حسب البحث النصي).
- **الاقتراح:** إزالته لتقليل حجم الـ dependencies إذا غير مطلوب.

### (منخفض) ملفات/مجلدات خارج `lib/` قد تكون ميتة

- **المكان:** `widgets/app_logo.dart`
- **الملاحظة:** لم يتم العثور على أي imports/استخدام داخل `lib/`.
- **الاقتراح:** نقلها إلى `lib/` إذا مطلوبة أو حذفها إن كانت قديمة.

### (متوسط) `catch (_) {}` الصامتة

- **أمثلة:**
  - `lib/pages/home_page.dart:535`
  - `lib/pages/order_details_page.dart:160`
  - `lib/pages/order_tracking_page.dart:162`
- **المشكلة:** تُخفي الأخطاء الفعلية وتُصعّب التحليل عند حدوث أعطال في الإنتاج.
- **الاقتراح:** تسجيلها بـ `ErrorLogger.logError(...)` (مع الـ redaction) أو على الأقل إظهار رسالة مناسبة للمستخدم.

## 8) Supabase / RLS Checklist (Backend)

### (إيجابي) تقليل N+1 في الطلبات

- **المكان:** `lib/services/orders_service.dart:452` و `lib/services/restaurants_service.dart:316`
- **الملاحظة:** يتم تجميع `restaurant_id` ثم تحميل بيانات المطاعم دفعة واحدة (`getOrderRestaurantsByIds`) ثم إرفاقها لكل طلب، وهذا أفضل من N+1 queries.

الجداول/الوظائف الظاهرة من جانب العميل (حسب `rg`):

- Tables: `managers`, `categories`, `items`, `customers`, `orders`, `order_items`, `order_messages`, `restaurant_complaints`, `system_errors`
- RPC: `get_nearby_restaurants`, `estimate_delivery_cost`

**تحقق من:**

- تفعيل RLS لكل الجداول الحساسة.
- سياسات `orders/order_items/order_messages/customers` تعتمد على `auth.uid()` وتمنع الوصول المتبادل.
- `system_errors`: السماح بـ Insert فقط، ومنع Select على العملاء.

## 9) APK / App Size

### (عالي) تحسينات حجم APK تعتمد على إعدادات Release + إزالة غير المستخدم

- **أماكن بارزة:**
  - `pubspec.yaml:13` (`dio` غير مستخدم)
  - `android/app/build.gradle:62` (اقتراحات `minifyEnabled`/`shrinkResources`)
- **الاقتراحات العملية:**
  - إزالة dependencies غير المستخدمة ثم تشغيل `flutter pub get` لتحديث `pubspec.lock`.
  - بناء APK بإعدادات الحجم: `flutter build apk --release --split-per-abi`.
  - تأكد من `--tree-shake-icons` (افتراضيًا في release عادةً) وتقليل الخطوط/الأصول الكبيرة.
  - تفعيل `minifyEnabled/shrinkResources` بعد اختبار شامل (قد يتطلب Proguard rules لبعض المكتبات).
