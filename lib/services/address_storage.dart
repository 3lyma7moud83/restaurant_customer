import 'address_model.dart';

class AddressStorage {
  static AddressModel? _cache;

  static Future<void> save(AddressModel address) async {
    _cache = address;
  }

  static Future<AddressModel?> load() async {
    return _cache;
  }
}
