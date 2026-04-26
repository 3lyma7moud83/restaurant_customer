import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class ItemsService {
  static final _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _ItemsCacheEntry> _itemsCache = {};

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
    required String categoryId,
    bool forceRefresh = false,
  }) async {
    try {
      final cacheKey = categoryId.trim();
      final cached = forceRefresh ? null : _itemsCache[cacheKey];
      if (cached != null && !cached.isExpired) {
        return cached.value;
      }

      final res =
          await SessionManager.instance.runWithValidSession<List<dynamic>>(
        () => _client
            .from('items')
            .select('id, name, price, image_url, created_at')
            .eq('category_id', categoryId)
            .order('created_at'),
      );
      if (res == null) {
        return const [];
      }

      final items = res
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
      final sortedItems = _sortItems(items);
      _itemsCache[cacheKey] = _ItemsCacheEntry(
        value: sortedItems,
        cachedAt: DateTime.now(),
      );
      return sortedItems;
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

          _itemsCache.remove(normalizedCategoryId);
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
    Map<String, dynamic>? categoryRow;
    try {
      categoryRow = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(
        () async {
          final data = await _client
              .from('categories')
              .select('id, manager_id, restaurant_id')
              .eq('id', categoryId)
              .maybeSingle();
          return data == null ? null : Map<String, dynamic>.from(data);
        },
        requireSession: true,
      );
    } on PostgrestException catch (error) {
      if (!_isSchemaMismatchError(error)) {
        rethrow;
      }
      categoryRow = await SessionManager.instance
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
    }

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

    var restaurantId = _stringValue(categoryRow['restaurant_id']);
    if (restaurantId == null || restaurantId.isEmpty) {
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
      restaurantId = _stringValue(managerRow?['restaurant_id']);
    }
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

  // Deterministic order for menu rendering:
  // 1) created_at ascending to keep insertion order stable
  // 2) name
  // 3) id fallback for strict deterministic output
  static List<Map<String, dynamic>> _sortItems(
    List<Map<String, dynamic>> source,
  ) {
    final next = List<Map<String, dynamic>>.from(source);
    next.sort((a, b) {
      final createdA = DateTime.tryParse((a['created_at'] ?? '').toString());
      final createdB = DateTime.tryParse((b['created_at'] ?? '').toString());
      if (createdA != null && createdB != null) {
        final byCreated = createdA.compareTo(createdB);
        if (byCreated != 0) {
          return byCreated;
        }
      } else if (createdA != null) {
        return -1;
      } else if (createdB != null) {
        return 1;
      }

      final nameA = (a['name'] ?? '').toString().trim().toLowerCase();
      final nameB = (b['name'] ?? '').toString().trim().toLowerCase();
      final byName = nameA.compareTo(nameB);
      if (byName != 0) {
        return byName;
      }

      final idA = (a['id'] ?? '').toString();
      final idB = (b['id'] ?? '').toString();
      return idA.compareTo(idB);
    });
    return next;
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
