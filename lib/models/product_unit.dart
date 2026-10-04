// Phase 1 (multi-unit): product_units টেবিলের model।
// একটা product-এর base unit (products.unit, যেমন "gram") এর ওপর
// ভিত্তি করে একাধিক বিক্রয়যোগ্য pack এখানে সংজ্ঞায়িত হয়।
//
// উদাহরণ: মধু (base unit = gram)
//   ProductUnit(unitLabel: "250g", conversionFactorToBase: 250, sellingPrice: 300)
//   ProductUnit(unitLabel: "500g", conversionFactorToBase: 500, sellingPrice: 580)
//   ProductUnit(unitLabel: "1kg",  conversionFactorToBase: 1000, sellingPrice: 1100)
class ProductUnit {
  final int? id;
  final int productId;
  final String unitLabel;
  final double conversionFactorToBase;
  final double? sellingPrice;
  final bool isDefault;
  final bool isActive;
  final String? syncId;

  const ProductUnit({
    this.id,
    required this.productId,
    required this.unitLabel,
    required this.conversionFactorToBase,
    this.sellingPrice,
    this.isDefault = false,
    this.isActive = true,
    this.syncId,
  });

  /// এই pack-এর কত পরিমাণ = base unit-এ কত পরিমাণ
  double toBaseQuantity(double packQuantity) =>
      packQuantity * conversionFactorToBase;

  ProductUnit copyWith({
    int? id,
    int? productId,
    String? unitLabel,
    double? conversionFactorToBase,
    double? sellingPrice,
    bool? isDefault,
    bool? isActive,
    String? syncId,
  }) {
    return ProductUnit(
      id: id ?? this.id,
      productId: productId ?? this.productId,
      unitLabel: unitLabel ?? this.unitLabel,
      conversionFactorToBase:
          conversionFactorToBase ?? this.conversionFactorToBase,
      sellingPrice: sellingPrice ?? this.sellingPrice,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
      syncId: syncId ?? this.syncId,
    );
  }

  factory ProductUnit.fromMap(Map<String, dynamic> map) {
    return ProductUnit(
      id: map['id'] as int?,
      productId: map['product_id'] as int,
      unitLabel: map['unit_label'] as String,
      conversionFactorToBase: (map['conversion_factor_to_base'] as num).toDouble(),
      sellingPrice: (map['selling_price'] as num?)?.toDouble(),
      isDefault: (map['is_default'] as int? ?? 0) == 1,
      isActive: (map['is_active'] as int? ?? 1) == 1,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'product_id': productId,
      'unit_label': unitLabel,
      'conversion_factor_to_base': conversionFactorToBase,
      'selling_price': sellingPrice,
      'is_default': isDefault ? 1 : 0,
      'is_active': isActive ? 1 : 0,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}
