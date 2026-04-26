import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/services/error_logger.dart';
import 'session_manager.dart';

class CustomerAddress {
  const CustomerAddress({
    required this.id,
    required this.userId,
    required this.primaryAddress,
    required this.houseApartmentNo,
    required this.area,
    required this.additionalNotes,
    required this.isPrimary,
    required this.createdAt,
    required this.updatedAt,
    this.lat,
    this.lng,
  });

  final String id;
  final String userId;
  final String primaryAddress;
  final String houseApartmentNo;
  final String area;
  final String additionalNotes;
  final bool isPrimary;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double? lat;
  final double? lng;

  bool get isComplete =>
      primaryAddress.trim().isNotEmpty && houseApartmentNo.trim().isNotEmpty;

  static CustomerAddress fromRow(Map<String, dynamic> row) {
    final createdAt =
        DateTime.tryParse((row['created_at'] ?? '').toString())?.toUtc() ??
            DateTime.now().toUtc();
    final updatedAt =
        DateTime.tryParse((row['updated_at'] ?? '').toString())?.toUtc() ??
            createdAt;

    final hasIsPrimaryColumn = row.containsKey('is_primary');
    return CustomerAddress(
      id: (row['id'] ?? '').toString(),
      userId: (row['user_id'] ?? '').toString(),
      primaryAddress: (row['full_address'] ?? '').toString().trim(),
      houseApartmentNo: (row['building_number'] ?? '').toString().trim(),
      area: (row['area'] ?? '').toString().trim(),
      additionalNotes: (row['additional_notes'] ?? '').toString().trim(),
      isPrimary: hasIsPrimaryColumn ? row['is_primary'] == true : true,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lat: (row['lat'] as num?)?.toDouble(),
      lng: (row['lng'] as num?)?.toDouble(),
    );
  }
}

class CustomerAddressService {
  CustomerAddressService._();

  static final SupabaseClient _client = Supabase.instance.client;
  static const Duration _cacheTtl = Duration(minutes: 3);
  static final Map<String, _AddressCacheEntry> _cacheByUserId = {};

  static bool _hasIsPrimaryColumn = true;
  static bool _hasUserIdUniqueConstraint = true;

  static const String _selectFieldsWithIsPrimary = '''
    id,
    user_id,
    full_address,
    building_number,
    area,
    additional_notes,
    is_primary,
    lat,
    lng,
    created_at,
    updated_at
  ''';

  static const String _selectFieldsWithoutIsPrimary = '''
    id,
    user_id,
    full_address,
    building_number,
    area,
    additional_notes,
    lat,
    lng,
    created_at,
    updated_at
  ''';

  static Future<CustomerAddress?> getPrimaryAddress({
    bool forceRefresh = false,
  }) async {
    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    final user = session?.user;
    if (user == null) {
      return null;
    }

    final cached = forceRefresh ? null : _cacheByUserId[user.id];
    if (cached != null && !cached.isExpired) {
      return cached.value;
    }

    try {
      final row = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>?>(() async {
        return _fetchLatestAddressRow(user.id);
      }, requireSession: true);

      final address = row == null ? null : CustomerAddress.fromRow(row);
      _cacheByUserId[user.id] = _AddressCacheEntry(
        value: address,
        cachedAt: DateTime.now(),
      );
      return address;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'customer_address_service.getPrimaryAddress',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<CustomerAddress> savePrimaryAddress({
    required String primaryAddress,
    required String houseApartmentNo,
    String? area,
    String? additionalNotes,
    double? lat,
    double? lng,
  }) async {
    final session = await SessionManager.instance.ensureValidSession(
      requireSession: true,
    );
    final user = session?.user;
    if (user == null) {
      throw const SessionExpiredException();
    }

    final normalizedAddress = primaryAddress.trim();
    final normalizedHouseNumber = houseApartmentNo.trim();
    final normalizedArea = (area ?? '').trim();
    final normalizedNotes = (additionalNotes ?? '').trim();

    try {
      final row = await SessionManager.instance
          .runWithValidSession<Map<String, dynamic>>(
        () async {
          final payload = <String, dynamic>{
            'user_id': user.id,
            'full_address': normalizedAddress,
            'building_number': normalizedHouseNumber,
            'area': normalizedArea,
            'additional_notes': normalizedNotes,
            'lat': lat,
            'lng': lng,
          };

          return _saveAddressRow(
            userId: user.id,
            payload: payload,
          );
        },
        requireSession: true,
      );

      if (row == null) {
        throw const SessionExpiredException();
      }

      final address = CustomerAddress.fromRow(row);
      _cacheByUserId[user.id] = _AddressCacheEntry(
        value: address,
        cachedAt: DateTime.now(),
      );
      return address;
    } catch (error, stack) {
      await ErrorLogger.logError(
        module: 'customer_address_service.savePrimaryAddress',
        error: error,
        stack: stack,
      );
      throw Exception(ErrorLogger.userMessage);
    }
  }

  static Future<Map<String, dynamic>?> _fetchLatestAddressRow(
    String userId,
  ) async {
    final selectFields = _hasIsPrimaryColumn
        ? _selectFieldsWithIsPrimary
        : _selectFieldsWithoutIsPrimary;

    try {
      final rows = await _client
          .from('customer_addresses')
          .select(selectFields)
          .eq('user_id', userId)
          .order('updated_at', ascending: false)
          .limit(1);
      final mappedRows = _mapRows(rows);
      if (mappedRows.isEmpty) {
        return null;
      }
      return _normalizeAddressRow(mappedRows.first);
    } on PostgrestException catch (error) {
      if (_hasIsPrimaryColumn && _isMissingIsPrimaryColumnError(error)) {
        _hasIsPrimaryColumn = false;
        return _fetchLatestAddressRow(userId);
      }
      rethrow;
    }
  }

  static Future<Map<String, dynamic>> _saveAddressRow({
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    final upsertPayload = <String, dynamic>{
      ...payload,
      if (_hasIsPrimaryColumn) 'is_primary': true,
    };

    final selectFields = _hasIsPrimaryColumn
        ? _selectFieldsWithIsPrimary
        : _selectFieldsWithoutIsPrimary;

    if (_hasUserIdUniqueConstraint) {
      try {
        final row = await _client
            .from('customer_addresses')
            .upsert(upsertPayload, onConflict: 'user_id')
            .select(selectFields)
            .single();
        return _normalizeAddressRow(Map<String, dynamic>.from(row));
      } on PostgrestException catch (error) {
        if (_hasIsPrimaryColumn && _isMissingIsPrimaryColumnError(error)) {
          _hasIsPrimaryColumn = false;
          return _saveAddressRow(
            userId: userId,
            payload: payload,
          );
        }

        if (_isMissingUserIdConflictConstraint(error)) {
          _hasUserIdUniqueConstraint = false;
          return _saveWithoutUpsert(
            userId: userId,
            payload: payload,
          );
        }
        rethrow;
      }
    }

    return _saveWithoutUpsert(
      userId: userId,
      payload: payload,
    );
  }

  static Future<Map<String, dynamic>> _saveWithoutUpsert({
    required String userId,
    required Map<String, dynamic> payload,
  }) async {
    final latest = await _fetchLatestAddressRow(userId);
    final hasExisting =
        latest != null && (latest['id'] ?? '').toString().isNotEmpty;
    final savePayload = <String, dynamic>{
      ...payload,
      if (_hasIsPrimaryColumn) 'is_primary': true,
    };
    final selectFields = _hasIsPrimaryColumn
        ? _selectFieldsWithIsPrimary
        : _selectFieldsWithoutIsPrimary;

    if (!hasExisting) {
      final inserted = await _client
          .from('customer_addresses')
          .insert(savePayload)
          .select(selectFields)
          .single();
      return _normalizeAddressRow(Map<String, dynamic>.from(inserted));
    }

    final existingId = latest['id'].toString();
    final updatePayload = Map<String, dynamic>.from(savePayload)
      ..remove('user_id');

    final updated = await _client
        .from('customer_addresses')
        .update(updatePayload)
        .eq('id', existingId)
        .select(selectFields)
        .single();
    return _normalizeAddressRow(Map<String, dynamic>.from(updated));
  }

  static List<Map<String, dynamic>> _mapRows(dynamic rows) {
    if (rows is! List) {
      return const [];
    }

    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
  }

  static Map<String, dynamic> _normalizeAddressRow(Map<String, dynamic> row) {
    if (!_hasIsPrimaryColumn || !row.containsKey('is_primary')) {
      return {
        ...row,
        'is_primary': true,
      };
    }
    return row;
  }

  static bool _isMissingIsPrimaryColumnError(PostgrestException error) {
    final message = error.message.toLowerCase();
    return message.contains('is_primary') &&
        (message.contains('does not exist') ||
            message.contains('not found') ||
            message.contains('unknown') ||
            error.code == 'PGRST204');
  }

  static bool _isMissingUserIdConflictConstraint(PostgrestException error) {
    final message = error.message.toLowerCase();
    return error.code == '42P10' ||
        (message.contains('on conflict') &&
            message.contains('constraint') &&
            message.contains('user_id'));
  }
}

class _AddressCacheEntry {
  const _AddressCacheEntry({
    required this.value,
    required this.cachedAt,
  });

  final CustomerAddress? value;
  final DateTime cachedAt;

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > CustomerAddressService._cacheTtl;
}
