import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class ItemsService {
  static final _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _ItemsCacheEntry> _itemsCache = {};
  static const int _defaultPageSize = 80;
  static const String _variantSelectColumns =
      'id, item_id, name, price, sort_order, created_at';

  static void _ensureManager() {
    final role = _client.auth.currentUser?.userMetadata?['role'];
    if (role != 'manager') {
      throw Exception('Not authorized');
    }
  }

  static String? _stringValue(dynamic value) {
    final normalized = value?.toString().trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized.toLowerCase() == 'null') {
      return null;
    }
    return normalized;
  }

  static Future<List<Map<String, dynamic>>> fetchByCategory({
    required String restaurantId,
    required String categoryId,
    bool forceRefresh = false,
    int page = 0,
    int pageSize = _defaultPageSize,
  }) async {
    final normalizedRestaurantId = restaurantId.trim();
    final normalizedCategoryId = categoryId.trim();
    final safePageSize = pageSize <= 0 ? _defaultPageSize : pageSize;
    final from = page < 0 ? 0 : page * safePageSize;
    final to = from + safePageSize - 1;

    try {
      final cacheKey = '$normalizedRestaurantId::$normalizedCategoryId';
      final cached = forceRefresh ? null : _itemsCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.value;
      }

      debugPrint(
        '[ItemsService.fetchByCategory] query: restaurant_id=$normalizedRestaurantId '
        'category_id=$normalizedCategoryId range=$from:$to',
      );

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('items')
            .select(
                'id, restaurant_id, category_id, name, price, image_url, sort_order, created_at')
            .eq('restaurant_id', normalizedRestaurantId)
            .eq('category_id', normalizedCategoryId)
            .order('sort_order', ascending: true)
            .range(from, to),
      );
      if (res == null) {
        return const [];
      }

      final items = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final sortedItems = _sortItems(items);
      final itemsWithVariants = await _attachVariants(sortedItems);
      debugPrint(
        '[ItemsService.fetchByCategory] response_count=${itemsWithVariants.length} '
        'restaurant_id=$normalizedRestaurantId category_id=$normalizedCategoryId',
      );

      if (itemsWithVariants.isEmpty) {
        debugPrint(
          '[ItemsService.fetchByCategory] empty response reason: '
          'no_data OR wrong_filter OR RLS_blocker | restaurant_id=$normalizedRestaurantId '
          'category_id=$normalizedCategoryId',
        );
      }

      _itemsCache[cacheKey] = _ItemsCacheEntry(
        value: itemsWithVariants,
        cachedAt: DateTime.now(),
      );
      return itemsWithVariants;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'items_service.fetchByCategory',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<Map<String, dynamic>> addItem({
    required String categoryId,
    required String name,
    required num price,
    String? imageUrl,
  }) async {
    _ensureManager();
    final normalizedCategoryId = categoryId.trim();
    final normalizedName = name.trim();
    if (normalizedCategoryId.isEmpty || normalizedName.isEmpty) {
      throw Exception(ErrorLogger.userMessage);
    }

    try {
      final context = await _resolveInsertContext(normalizedCategoryId);
      final payloads = _buildInsertPayloads(
        context: context,
        name: normalizedName,
        price: price,
        imageUrl: imageUrl,
      );

      PostgrestException? lastSchemaError;
      PostgrestException? foreignKeyError;

      for (final payload in payloads) {
        try {
          final res = await SessionManager.instance
              .runWithValidSession<Map<String, dynamic>>(
            () async {
              final data =
                  await _client.from('items').insert(payload).select().single();
              return Map<String, dynamic>.from(data);
            },
            requireSession: true,
          );
          if (res == null) {
            throw const SessionExpiredException();
          }

          _itemsCache.remove(
            '${context.restaurantId?.trim() ?? ''}::$normalizedCategoryId',
          );
          return res;
        } on PostgrestException catch (error) {
          if (_isSchemaMismatchError(error)) {
            lastSchemaError = error;
            continue;
          }
          if (_isForeignKeyConstraintError(error)) {
            foreignKeyError = error;
            break;
          }
          rethrow;
        }
      }

      if (foreignKeyError != null) {
        throw Exception(
          'تعذر إضافة الصنف لأن الربط بين النوع/المطعم غير صحيح.',
        );
      }
      if (lastSchemaError != null) {
        throw lastSchemaError;
      }
      throw Exception(ErrorLogger.userMessage);
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'items_service.addItem',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<void> updateItem({
    required String itemId,
    required String name,
    required num price,
  }) async {
    _ensureManager();
    final updated = await SessionManager.instance.runWithValidSession<bool>(
      () async {
        await _client.from('items').update({
          'name': name,
          'price': price,
        }).eq('id', itemId);
        return true;
      },
      requireSession: true,
    );
    if (updated != true) {
      throw const SessionExpiredException();
    }

    _itemsCache.clear();
  }

  static Future<void> updateItemImageUrl({
    required String itemId,
    required String imageUrl,
  }) async {
    _ensureManager();
    final updated = await SessionManager.instance.runWithValidSession<bool>(
      () async {
        await _client.from('items').update({
          'image_url': imageUrl,
        }).eq('id', itemId);
        return true;
      },
      requireSession: true,
    );
    if (updated != true) {
      throw const SessionExpiredException();
    }

    _itemsCache.clear();
  }

  static Future<void> deleteItem({
    required String itemId,
  }) async {
    _ensureManager();
    final deleted = await SessionManager.instance.runWithValidSession<bool>(
      () async {
        await _client.from('items').delete().eq('id', itemId);
        return true;
      },
      requireSession: true,
    );
    if (deleted != true) {
      throw const SessionExpiredException();
    }

    _itemsCache.clear();
  }

  static Future<_ItemInsertContext> _resolveInsertContext(
    String categoryId,
  ) async {
    final categoryRow = await SessionManager.instance
        .runWithValidSession<Map<String, dynamic>?>(
      () async {
        final data = await _client
            .from('categories')
            .select('id, manager_id')
            .eq('id', categoryId)
            .maybeSingle();
        return data == null ? null : Map<String, dynamic>.from(data);
      },
      requireSession: true,
    );

    if (categoryRow == null) {
      throw Exception('نوع الصنف غير موجود.');
    }

    final managerId = _stringValue(categoryRow['manager_id']);
    if (managerId == null || managerId.isEmpty) {
      throw Exception('نوع الصنف غير مرتبط بحساب مطعم صالح.');
    }

    final currentUserId = _stringValue(_client.auth.currentUser?.id);
    if (currentUserId != null &&
        currentUserId.isNotEmpty &&
        currentUserId != managerId) {
      throw Exception('نوع الصنف لا يتبع هذا الحساب.');
    }

    final managerRow = await SessionManager.instance
        .runWithValidSession<Map<String, dynamic>?>(
      () async {
        final data = await _client
            .from('managers')
            .select('restaurant_id, user_id')
            .eq('user_id', managerId)
            .maybeSingle();
        return data == null ? null : Map<String, dynamic>.from(data);
      },
      requireSession: true,
    );
    final restaurantId = _stringValue(managerRow?['restaurant_id']);
    if (restaurantId == null || restaurantId.isEmpty) {
      throw Exception('تعذر تحديد restaurant_id المرتبط بنوع الصنف.');
    }

    return _ItemInsertContext(
      categoryId: categoryId,
      managerId: managerId,
      restaurantId: restaurantId,
    );
  }

  static List<Map<String, dynamic>> _buildInsertPayloads({
    required _ItemInsertContext context,
    required String name,
    required num price,
    String? imageUrl,
  }) {
    final base = <String, dynamic>{
      'category_id': context.categoryId,
      'name': name,
      'price': price,
      'image_url': imageUrl,
    };

    final payloads = <Map<String, dynamic>>[
      {
        ...base,
        'manager_id': context.managerId,
        if (context.restaurantId != null &&
            context.restaurantId!.trim().isNotEmpty)
          'restaurant_id': context.restaurantId,
      },
      {
        ...base,
        'manager_id': context.managerId,
      },
      if (context.restaurantId != null &&
          context.restaurantId!.trim().isNotEmpty)
        {
          ...base,
          'restaurant_id': context.restaurantId,
        },
      base,
    ];

    final unique = <String>{};
    final deduped = <Map<String, dynamic>>[];
    for (final payload in payloads) {
      final signature = payload.keys.toList()..sort();
      final key = signature.join('|');
      if (unique.add(key)) {
        deduped.add(payload);
      }
    }
    return deduped;
  }

  static bool _isSchemaMismatchError(PostgrestException error) {
    final message = error.message.toLowerCase();
    return error.code == 'PGRST204' ||
        message.contains('schema cache') ||
        (message.contains('column') &&
            (message.contains('does not exist') ||
                message.contains('not found') ||
                message.contains('unknown')));
  }

  static bool _isForeignKeyConstraintError(PostgrestException error) {
    final message = error.message.toLowerCase();
    final details = error.details?.toString().toLowerCase() ?? '';
    return error.code == '23503' ||
        message.contains('foreign key') ||
        details.contains('foreign key');
  }

  static Future<List<Map<String, dynamic>>> _attachVariants(
    List<Map<String, dynamic>> items,
  ) async {
    if (items.isEmpty) {
      return items;
    }

    final itemIds = items
        .map((item) => _stringValue(item['id']))
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (itemIds.isEmpty) {
      final itemsWithEmptyVariants = _itemsWithAttachedVariants(
        items: items,
        groupedVariants: const {},
      );
      _logAttachedVariants(itemsWithEmptyVariants);
      return itemsWithEmptyVariants;
    }

    try {
      final rows =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('item_variants')
            .select(_variantSelectColumns)
            .inFilter('item_id', itemIds),
      );
      if (rows == null || rows.isEmpty) {
        final itemsWithEmptyVariants = _itemsWithAttachedVariants(
          items: items,
          groupedVariants: const {},
        );
        _logAttachedVariants(itemsWithEmptyVariants);
        return itemsWithEmptyVariants;
      }

      final grouped = <String, List<Map<String, dynamic>>>{};
      for (final row in rows.whereType<Map>()) {
        final source = Map<String, dynamic>.from(row);
        final itemId = _stringValue(source['item_id']) ?? '';
        if (itemId.isEmpty) {
          continue;
        }
        final variant = <String, dynamic>{
          'id': source['id'],
          'item_id': itemId,
          'name': _stringValue(source['name']) ?? '',
          'price': source['price'],
          'sort_order': source['sort_order'],
          'created_at': source['created_at'],
        };
        grouped
            .putIfAbsent(itemId, () => <Map<String, dynamic>>[])
            .add(variant);
      }
      if (grouped.isEmpty) {
        final itemsWithEmptyVariants = _itemsWithAttachedVariants(
          items: items,
          groupedVariants: const {},
        );
        _logAttachedVariants(itemsWithEmptyVariants);
        return itemsWithEmptyVariants;
      }

      grouped.updateAll((_, variants) {
        final indexed = variants.indexed.toList(growable: false);
        indexed.sort((a, b) {
          final bySortOrder = _sortOrderOf(a.$2).compareTo(_sortOrderOf(b.$2));
          if (bySortOrder != 0) {
            return bySortOrder;
          }
          return a.$1.compareTo(b.$1);
        });
        return indexed.map((entry) => entry.$2).toList(growable: false);
      });

      final itemsWithVariants = _itemsWithAttachedVariants(
        items: items,
        groupedVariants: grouped,
      );
      _logAttachedVariants(itemsWithVariants);
      return itemsWithVariants;
    } on PostgrestException catch (error, stack) {
      if (_isOptionalVariantsSourceMissing(error)) {
        final itemsWithEmptyVariants = _itemsWithAttachedVariants(
          items: items,
          groupedVariants: const {},
        );
        _logAttachedVariants(itemsWithEmptyVariants);
        return itemsWithEmptyVariants;
      }
      await ErrorLogger.logError(
        module: 'items_service.attachVariants',
        error: error,
        stack: stack,
      );
      final itemsWithEmptyVariants = _itemsWithAttachedVariants(
        items: items,
        groupedVariants: const {},
      );
      _logAttachedVariants(itemsWithEmptyVariants);
      return itemsWithEmptyVariants;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'items_service.attachVariants',
        error: error,
        stack: stack,
      );
      final itemsWithEmptyVariants = _itemsWithAttachedVariants(
        items: items,
        groupedVariants: const {},
      );
      _logAttachedVariants(itemsWithEmptyVariants);
      return itemsWithEmptyVariants;
    }
  }

  static List<Map<String, dynamic>> _itemsWithAttachedVariants({
    required List<Map<String, dynamic>> items,
    required Map<String, List<Map<String, dynamic>>> groupedVariants,
  }) {
    return items.map((item) {
      final itemId = _stringValue(item['id']) ?? '';
      final variants =
          groupedVariants[itemId] ?? const <Map<String, dynamic>>[];
      return {
        ...item,
        'variants': variants,
      };
    }).toList(growable: false);
  }

  static void _logAttachedVariants(List<Map<String, dynamic>> items) {
    var multiVariantItemsCount = 0;
    for (final item in items) {
      final itemId = _stringValue(item['id']) ?? '';
      final variants = (item['variants'] as List?)
              ?.whereType<Map>()
              .toList(growable: false) ??
          const <Map>[];
      if (variants.length > 1) {
        multiVariantItemsCount += 1;
      }
      final variantNames = variants
          .map((variant) => _stringValue(variant['name']) ?? '<empty>')
          .join(', ');
      debugPrint(
        '[ItemsService.attachVariants] item_id=$itemId '
        'variants_count=${variants.length} variant_names=[$variantNames]',
      );
    }
    debugPrint(
      '[ItemsService.attachVariants] multi_variant_items_count=$multiVariantItemsCount '
      'total_items=${items.length}',
    );
  }

  static bool _isOptionalVariantsSourceMissing(PostgrestException error) {
    final message = error.message.toLowerCase();
    final details = error.details?.toString().toLowerCase() ?? '';
    return _isSchemaMismatchError(error) ||
        error.code == '42P01' ||
        message.contains('item_variants') ||
        details.contains('item_variants') ||
        message.contains('does not exist') ||
        details.contains('does not exist');
  }

  static num _sortOrderOf(Map<String, dynamic> row) {
    final value =
        row.containsKey('sort_order') ? row['sort_order'] : row['sortOrder'];
    if (value is num) {
      return value;
    }
    return num.tryParse(value?.toString().trim() ?? '') ?? 0;
  }

  static List<Map<String, dynamic>> _sortItems(
    List<Map<String, dynamic>> source,
  ) {
    final indexed = source.indexed.toList(growable: false);
    indexed.sort((a, b) {
      final bySortOrder = _sortOrderOf(a.$2).compareTo(_sortOrderOf(b.$2));
      if (bySortOrder != 0) {
        return bySortOrder;
      }
      return a.$1.compareTo(b.$1);
    });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }
}

class _ItemsCacheEntry {
  const _ItemsCacheEntry({
    required this.value,
    required this.cachedAt,
  });

  final List<Map<String, dynamic>> value;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > ItemsService._cacheTtl;
}

class _ItemInsertContext {
  const _ItemInsertContext({
    required this.categoryId,
    required this.managerId,
    required this.restaurantId,
  });

  final String categoryId;
  final String managerId;
  final String? restaurantId;
}
