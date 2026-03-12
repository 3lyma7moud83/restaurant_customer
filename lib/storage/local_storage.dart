import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalStorage {
  static const String restaurantsKey = 'restaurants';
  static const String categoriesKey = 'categories';
  static const String itemsKey = 'items';

  // المطاعم
  static Future<List<Map<String, dynamic>>> getRestaurants() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(restaurantsKey);
    if (json == null) return [];
    final List decoded = jsonDecode(json);
    return decoded.cast<Map<String, dynamic>>();
  }

  // الأنواع
  static Future<List<Map<String, dynamic>>> getCategories() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(categoriesKey);
    if (json == null) return [];
    final List decoded = jsonDecode(json);
    return decoded.cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> getCategoriesByRestaurant(
      String restaurantId) async {
    final list = await getCategories();
    return list.where((c) => c['restaurantId'] == restaurantId).toList();
  }

  // الأصناف
  static Future<List<Map<String, dynamic>>> getItems() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(itemsKey);
    if (json == null) return [];
    final List decoded = jsonDecode(json);
    return decoded.cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> getItemsByCategory(
      String categoryId) async {
    final list = await getItems();
    return list.where((i) => i['categoryId'] == categoryId).toList();
  }
}
