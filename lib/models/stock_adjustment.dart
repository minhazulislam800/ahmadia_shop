// Phase 2-তে "Stock Adjustment" মডিউল বানানোর সময় এই ক্লাস ব্যবহার
// হবে। সংশোধনী: schema ও backend service (TransactionService.
// recordStockAdjustment) দুটোই আগে থেকেই আছে — যা নেই তা হলো
// dedicated UI screen (মূল ব্রিফের §7 অনুযায়ী আলাদা মেনু চাওয়া
// হয়েছে)। Phase 2-এ recordStockAdjustment-কে multi-unit-aware
// করতে হবে (product_unit_id/base_quantity প্যারামিটার যোগ) এবং
// এর ওপর ভিত্তি করে screen বানাতে হবে।
class StockAdjustment {
  final int? id;
  final int productId;
  final int? productUnitId; // NULL হলে base unit-এ সরাসরি adjustment
  final double quantity; // input করা unit-এ (পজিটিভ/নেগেটিভ)
  final double baseQuantity; // base unit-এ প্রকৃত stock পরিবর্তন (snapshot)
  final double totalCost; // এই adjustment-এর টাকার মূল্য (রিপোর্টে damaged/gift/excess আলাদা দেখানোর জন্য)
  final String reason; // 'damaged' | 'shortage' | 'excess_found' | 'gift' | 'sample' | 'internal_use' | 'other'
  final String? note;
  final String adjustmentDate;
  final int? createdBy;
  final String? syncId;

  const StockAdjustment({
    this.id,
    required this.productId,
    this.productUnitId,
    required this.quantity,
    required this.baseQuantity,
    this.totalCost = 0,
    required this.reason,
    this.note,
    required this.adjustmentDate,
    this.createdBy,
    this.syncId,
  });

  factory StockAdjustment.fromMap(Map<String, dynamic> map) {
    return StockAdjustment(
      id: map['id'] as int?,
      productId: map['product_id'] as int,
      productUnitId: map['product_unit_id'] as int?,
      quantity: (map['quantity'] as num).toDouble(),
      baseQuantity: (map['base_quantity'] as num?)?.toDouble() ??
          (map['quantity'] as num).toDouble(),
      totalCost: (map['total_cost'] as num?)?.toDouble() ?? 0,
      reason: map['reason'] as String,
      note: map['note'] as String?,
      adjustmentDate: map['adjustment_date'] as String,
      createdBy: map['created_by'] as int?,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'product_id': productId,
      'product_unit_id': productUnitId,
      'quantity': quantity,
      'base_quantity': baseQuantity,
      'total_cost': totalCost,
      'reason': reason,
      'note': note,
      'adjustment_date': adjustmentDate,
      'created_by': createdBy,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}
