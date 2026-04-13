# Deep Technical Audit (Flutter) — Performance/Rebuilds/Leaks/Supabase/Security/Size

تاريخ الفحص: **2026-03-14**

تمت المراجعة داخل: `lib/` + `android/` + `pubspec.yaml`.

## نتيجة سريعة (Sanity)

- `flutter analyze`: ✅ No issues found
- `flutter test`: ✅ All tests passed

---

## 1) Flutter Rebuilds (Rebuild Storms)

### (عالي) `CartProvider.maybeOf()` كان يخلق dependency غير مقصود → Rebuilds غير لازمة — **تم الإصلاح**

- **المكان:** `lib/cart/cart_provider.dart:68`
- **السبب الحقيقي:** `dependOnInheritedWidgetOfExactType` يجعل الـ Widget الحالي “يسمع” تغييرات السلة حتى لو كان فقط يريد **استدعاء دالة** (مثال: مزامنة حالة الطلب) وليس عرض بيانات السلة.
- **الأثر:** صفحات مثل `OrdersPage/OrderDetailsPage/OrderTrackingPage` قد تُعاد بناؤها عند أي تغيير في السلة بدون داعٍ → jank/إطالة frame time.
- **الإصلاح:** تحويل `maybeOf` لقراءة بدون subscribe باستخدام `getElementForInheritedWidgetOfExactType`.
- **الحالة:** Fixed ✅

### (متوسط) `CartProvider.updateShouldNotify` دائمًا `true` → كل من يعتمد على `CartProvider.of` سيُعاد بناؤه عند أي تغيير

- **المكان:** `lib/cart/cart_provider.dart:75`
- **السبب الحقيقي:** InheritedWidget يُخطر جميع الـ dependents بكل rebuild، بدون تفريق “أي جزء من السلة تغيّر”.
- **الأثر:** عند زيادة استخدام السلة (خصوصًا داخل صفحات تعرض Grid/List كبيرة) قد يحدث drop frames.
- **الحل المقترح (أعلى تأثير):**
  - الانتقال إلى `InheritedModel` (aspects) أو `ChangeNotifier` + (Provider/Selector) لتحديث أجزاء محددة فقط.
  - أو تقسيم السلة إلى `ValueNotifier`s (count/total/items/location) ثم بناء UI بـ `ValueListenableBuilder`.

### (متوسط) Grid صفحة المنيو يعيد بناء عناصر كثيرة عند كل تغيير بالسلة

- **المكان:** `lib/pages/restaurant_menu_page.dart:129` (الاعتماد على السلة) و `lib/pages/restaurant_menu_page.dart:295` (Grid)
- **السبب الحقيقي:** الصفحة تقرأ `CartProvider.of(context)` وتستخرج `quantity` لكل عنصر داخل `GridView.builder`.
- **الأثر:** عند إضافة عنصر، إعادة بناء الـ Grid (على الأقل العناصر المعروضة) + حساب كميات متعددة.
- **حلول مقترحة:**
  - اجعل كل Card يعتمد فقط على quantity الخاص به عبر Notifier مخصص.
  - أو استخدم Selector/Computed cache للـ quantities.

### (منخفض) البحث يُفلتر القائمة عند كل keystroke

- **المكان:** `lib/pages/home_page.dart:232` → `lib/pages/home_page.dart:256`
- **السبب الحقيقي:** listener على `TextEditingController` ينفّذ filter كامل للقائمة كل تغيير.
- **الأثر:** إذا كبرت قائمة المطاعم قد يظهر lag أثناء الكتابة.
- **حل مقترح:** memoization للأسماء lowercased أو debounce للبحث.

---

## 2) أداء داخل `build()` (Heavy Work)

### (متوسط) بناء قائمة العناصر داخل `build()` باستخدام spread على `.map` (غير lazy)

- **المكان:** `lib/pages/order_details_page.dart:484` و `lib/pages/order_tracking_page.dart:716`
- **السبب الحقيقي:** `...items.map(...)` يبني Widgets لكل العناصر دفعة واحدة داخل `Column` (بدون virtualization).
- **الأثر:** إذا زاد عدد عناصر الطلب قد يحدث slow build وjank.
- **حل مقترح:** `ListView.separated`/`ListView.builder` أو `SliverList` داخل `CustomScrollView`.

---

## 3) الصور و UI Rendering

### (متوسط) `Image.network/NetworkImage` بدون resize/caching hints

- **أماكن بارزة:**
  - `lib/widgets/restaurant_card_components.dart:131`
  - `lib/widgets/restaurant_info_sheet.dart:152`
  - `lib/pages/restaurant_menu_page.dart:417`
  - `lib/pages/home_page.dart:578`
- **الأثر:** احتمال jank أثناء scrolling + استهلاك ذاكرة أعلى على صور كبيرة.
- **حلول مقترحة:**
  - `cacheWidth/cacheHeight` حسب حجم العرض الفعلي.
  - `filterQuality: FilterQuality.low` للصور المصغّرة.
  - استخدام `cached_network_image` (مع placeholder) لو مناسب.
  - `precacheImage` للصور الحرجة قبل فتح الصفحة/BottomSheet.

---

## 4) Memory Leaks

### (حرج) `MapController` في `flutter_map` كان بدون `dispose()` — **تم الإصلاح سابقًا**

- **المكان:** `lib/cart/select_address_page.dart:96`
- **السبب الحقيقي:** `MapController` لديه `dispose()`، وإهماله قد يترك listeners داخليًا.
- **الحالة:** Fixed ✅

### (منخفض) عمليات حفظ السلة كانت تعمل كثيرًا (JSON + SharedPreferences) — **تم التحسين**

- **المكان:** `lib/cart/cart_provider.dart:317` (debounce) + `lib/cart/cart_provider.dart:442` (cancel timer)
- **السبب الحقيقي:** `jsonEncode` synchronous على UI isolate + تكرار استدعاء `_persistState` مع كل تعديل.
- **الأثر:** micro-jank عند إضافة عناصر/تعديل العنوان بكثرة.
- **الحالة:** Improved ✅ (Debounce 250ms)

---

## 5) Supabase (Queries + Realtime + RLS)

### (متوسط) جلب `items` كان يعمل `select()` بدون تحديد أعمدة — **تم الإصلاح**

- **المكان:** `lib/services/items_service.dart:24`
- **السبب الحقيقي:** تحميل أعمدة غير مستخدمة يزيد payload ووقت parsing.
- **الأثر:** بطء تحميل المنيو واستهلاك ذاكرة أعلى.
- **الحالة:** Fixed ✅ (حددنا: `id, name, price, image_url`)

### (متوسط) الشات كان يعمل `select()` بدون تحديد أعمدة + dedupe O(n) — **تم التحسين**

- **المكان:** `lib/pages/order_chat_page.dart:48` و `lib/pages/order_chat_page.dart:22`
- **السبب الحقيقي:** تحميل بيانات غير لازمة + `messages.any(...)` لكل رسالة جديدة.
- **الأثر:** بطء/CPU أعلى مع تاريخ شات كبير.
- **الحالة:** Improved ✅ (select محدود + Set للـ ids)

### (متوسط) `order_items` ما زال يستخدم `select('*')`

- **المكان:** `lib/services/orders_service.dart:177`
- **الأثر:** payload أكبر من اللازم في صفحات تفاصيل/تتبع الطلب.
- **حل مقترح:** حدد الأعمدة المطلوبة فقط (مثل: `id, order_id, item_name, price, qty, created_at`).

### (متوسط) Realtime callbacks تقوم بعمل fetch كامل عند كل تغيير

- **مثال:** `lib/pages/orders_page.dart:166` (عند أي update → `getOrderById`)
- **الأثر:** ضغط شبكة/بطء على اتصالات ضعيفة، خصوصًا إذا كانت updates كثيرة.
- **حلول مقترحة:**
  - استخدام `payload.newRecord` لتحديث UI محليًا عندما يكفي.
  - تجميع updates بـ debounce قبل fetch.

### RLS / Backend Checklist (ضروري للأمان والأداء)

الجداول/الوظائف المستخدمة من العميل (حسب الكود):

- Tables: `orders`, `order_items`, `order_messages`, `customers`, `managers`, `categories`, `items`, `restaurant_complaints`, `system_errors`
- RPC: `get_nearby_restaurants`, `estimate_delivery_cost`, `create_order_with_items` (إن كانت موجودة)

**تحقق من:**

- تفعيل RLS للجداول الحساسة (خصوصًا `orders/order_items/order_messages/customers/system_errors`).
- سياسات تمنع قراءة/تعديل بيانات الآخرين باستخدام `auth.uid()`.
- `system_errors`: يفضّل Insert فقط ومنع Select للعملاء + rate limiting (Edge Function أفضل).

---

## 6) Network (timeouts / retries / caching)

### (معلوماتي) HTTP لديها timeouts (جيد)

- `lib/core/location/location_service.dart:32`
- `lib/services/location_distance_service.dart:24`

### (متوسط) لا توجد Retry/Caching في طبقة Supabase/HTTP

- **الأثر:** UX سيئة عند تذبذب الشبكة.
- **حل مقترح:** retry محدد (مع backoff) للـ calls غير الحرجة + caching بسيط للـ lists.

---

## 7) APK Size (Deps/Assets)

### (منخفض) dependency غير مستخدمة

- **المكان:** `pubspec.yaml:13`
- **الملاحظة:** `dio` غير مستخدم (حسب البحث النصي).
- **حل مقترح:** إزالته لتقليل حجم الـ dependencies.

### (عالي) Mapbox Native SDK قد يضخم حجم APK ويعقّد البناء

- **مؤشرات داخل المشروع:**
  - إعدادات Mapbox Maven في `android/build.gradle:8`
  - متغير `MAPBOX_DOWNLOADS_TOKEN` في `android/gradle.properties:8`
  - استخدام Mapbox token في `lib/main.dart:148`
- **ملاحظة مهمة:** إذا كنت تستخدم `flutter_map` + Mapbox tiles/REST فقط، قد لا تحتاج `mapbox_maps_flutter` إطلاقًا (لكن تأكد قبل الإزالة).

### قياس الحجم (موصى به)

- شغّل: `flutter build apk --release --analyze-size`
- أو: `flutter build appbundle --release`
- جرّب: `--split-per-abi` لتقليل حجم APK لكل معمارية.

---

## 8) Android Build Audit

### (عالي) Release signing يستخدم debug keystore

- **المكان:** `android/app/build.gradle:37`
- **الأثر:** غير مناسب للإنتاج/Google Play.
- **حل:** إعداد `signingConfigs.release` مع keystore حقيقي.

### (عالي) Mapbox Maven downloads token مطلوب للبناء

- **المكان:** `android/build.gradle:8` و `android/gradle.properties:8`
- **الأثر:** Gradle قد يفشل (401) بدون توكن.
- **حل:** ضع التوكن في `~/.gradle/gradle.properties` أو env var (لا تلتزم به داخل repo).

---

## 9) Security Findings

### (عالي) `.env` يتم تضمينه كـ asset داخل التطبيق

- **المكان:** `pubspec.yaml:35`
- **السبب الحقيقي:** أي قيمة داخل `.env` يمكن استخراجها من build artifacts.
- **حل:** لا تضع أسرار (service_role/keys السرية). استخدم server-side/Edge Functions أو `--dart-define` حسب الحاجة.

### (متوسط) SharedPreferences يخزن بيانات حساسة (عنوان/إحداثيات)

- **المكان:** `lib/cart/cart_provider.dart:405` وما بعدها
- **الأثر:** بيانات PII تُحفظ plaintext داخل sandbox (خطر أكبر على الأجهزة rooted/backup).
- **حلول:** تقليل ما يُحفظ، أو استخدام تخزين آمن/تشفير.

### (متوسط) Error logging من العميل إلى Supabase

- **المكان:** `lib/core/services/error_logger.dart:29`
- **الأثر:** خطر تسريب stack traces/PII + spam إن لم تكن RLS والسياسات صارمة.

---

## 10) Bottlenecks المحتملة (Startup / صفحات / Scrolling)

- **Startup:** تهيئة `.env` + Supabase داخل `_AppBootstrapper` (OK وظيفيًا، لكن تأكد من UX على شبكات بطيئة).
- **Scrolling:** صور الشبكة + rebuilds عند تحديث السلة داخل صفحات Grid/List.
- **Realtime:** fetch كامل عند كل update (خاصة صفحة الطلبات).

---

## 10.1) كيف تقيس الـ Rebuilds والـ Jank عمليًا (موصى به)

- شغّل على جهاز حقيقي بوضع profile: `flutter run --profile`
- افتح DevTools → تبويب Performance ثم:
  - راقب الـ frame chart (UI/GPU) أثناء scrolling وإضافة عناصر للسلة.
  - التقط Timeline عند فتح الصفحات الثقيلة (Menu / Tracking / Orders).
- فعّل داخل debug فقط (اختياري):
  - `debugProfileBuildsEnabled = true` لرؤية widgets الأكثر بناءً.
  - `RepaintRainbow` لرصد إعادة الرسم المفرطة.

---

## 11) تغييرات تم تنفيذها في هذا الـ audit (مباشرة في الكود)

- تقليل Rebuilds غير المقصودة عبر تعديل `CartProvider.maybeOf`: `lib/cart/cart_provider.dart:68`
- Debounce لحفظ السلة (تقليل JSON/I/O): `lib/cart/cart_provider.dart:317`
- تقليل payload في Supabase items query: `lib/services/items_service.dart:24`
- تحسين شات الطلب (select محدود + dedupe سريع): `lib/pages/order_chat_page.dart:48` و `lib/pages/order_chat_page.dart:22`
