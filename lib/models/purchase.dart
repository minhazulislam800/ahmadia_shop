class Purchase {
  final int? id;
  final int? supplierId;
  final String purchaseDate;
  final double totalAmount;
  final double paidAmount;
  final bool isCredit;
  final int? createdBy;
  final String createdAt;
  final String? syncId;

  const Purchase({
    this.id,
    this.supplierId,
    required this.purchaseDate,
    required this.totalAmount,
    this.paidAmount = 0,
    this.isCredit = false,
    this.createdBy,
    required this.createdAt,
    this.syncId,
  });

  factory Purchase.fromMap(Map<String, dynamic> map) {
    return Purchase(
      id: map['id'] as int?,
      supplierId: map['supplier_id'] as int?,
      purchaseDate: map['purchase_date'] as String,
      totalAmount: (map['total_amount'] as num).toDouble(),
      paidAmount: (map['paid_amount'] as num?)?.toDouble() ?? 0,
      isCredit: (map['is_credit'] as int? ?? 0) == 1,
      createdBy: map['created_by'] as int?,
      createdAt: map['created_at'] as String,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'supplier_id': supplierId,
      'purchase_date': purchaseDate,
      'total_amount': totalAmount,
      'paid_amount': paidAmount,
      'is_credit': isCredit ? 1 : 0,
      'created_by': createdBy,
      'created_at': createdAt,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}

// ক্রয়ের প্রতিটা লাইন = একটা নতুন FIFO ব্যাচ
class PurchaseBatch {
  final int? id;
  final int? purchaseId;
  final int productId;
  final int? productUnitId; // Phase 1 (multi-unit): কোন pack-এ কেনা হয়েছিল
  final double? displayQuantity; // যে pack-এ কেনা হয়েছিল তার সংখ্যা (শুধু তথ্যের জন্য)
  final double quantity; // সবসময় base unit-এ (FIFO হিসাবের মূল ভিত্তি)
  final double remainingQuantity; // সবসময় base unit-এ
  final double unitCost; // সবসময় base unit-এর প্রতি একক (per-base-unit) cost
  final String batchDate;
  final String? syncId;

  const PurchaseBatch({
    this.id,
    this.purchaseId,
    required this.productId,
    this.productUnitId,
    this.displayQuantity,
    required this.quantity,
    required this.remainingQuantity,
    required this.unitCost,
    required this.batchDate,
    this.syncId,
  });

  factory PurchaseBatch.fromMap(Map<String, dynamic> map) {
    return PurchaseBatch(
      id: map['id'] as int?,
      purchaseId: map['purchase_id'] as int?,
      productId: map['product_id'] as int,
      productUnitId: map['product_unit_id'] as int?,
      displayQuantity: (map['display_quantity'] as num?)?.toDouble(),
      quantity: (map['quantity'] as num).toDouble(),
      remainingQuantity: (map['remaining_quantity'] as num).toDouble(),
      unitCost: (map['unit_cost'] as num).toDouble(),
      batchDate: map['batch_date'] as String,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'purchase_id': purchaseId,
      'product_id': productId,
      'product_unit_id': productUnitId,
      'display_quantity': displayQuantity,
      'quantity': quantity,
      'remaining_quantity': remainingQuantity,
      'unit_cost': unitCost,
      'batch_date': batchDate,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}
