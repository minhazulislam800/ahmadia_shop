class Customer {
  final int? id;
  final String name;
  final String? phone;
  final String? address;
  final bool isActive;
  final String? syncId;

  const Customer({
    this.id,
    required this.name,
    this.phone,
    this.address,
    this.isActive = true,
    this.syncId,
  });

  factory Customer.fromMap(Map<String, dynamic> map) {
    return Customer(
      id: map['id'] as int?,
      name: map['name'] as String,
      phone: map['phone'] as String?,
      address: map['address'] as String?,
      isActive: (map['is_active'] as int? ?? 1) == 1,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'name': name,
      'phone': phone,
      'address': address,
      'is_active': isActive ? 1 : 0,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }

  Customer copyWith(
      {int? id, String? name, String? phone, String? address, bool? isActive, String? syncId}) {
    return Customer(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      isActive: isActive ?? this.isActive,
      syncId: syncId ?? this.syncId,
    );
  }
}
