class AddressModel {
  final String phone;
  final String street;
  final String building;
  final String apartment;
  final String landmark;

  AddressModel({
    required this.phone,
    required this.street,
    required this.building,
    required this.apartment,
    required this.landmark,
  });

  Map<String, dynamic> toMap() => {
        'phone': phone,
        'street': street,
        'building': building,
        'apartment': apartment,
        'landmark': landmark,
      };

  factory AddressModel.fromMap(Map<String, dynamic> map) => AddressModel(
        phone: map['phone'] ?? '',
        street: map['street'] ?? '',
        building: map['building'] ?? '',
        apartment: map['apartment'] ?? '',
        landmark: map['landmark'] ?? '',
      );
}
