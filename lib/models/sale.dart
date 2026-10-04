class Sale {
  final int? id;
  final int? customerId;
  final String saleDate;
  final double courierCharge;
  final double totalAmount;
  final double paidAmount;
  final bool isCredit;
  final String saleType; // 'retail' | 'wholesale'
  final int? createdBy;
  final String createdAt;
  final String? syncId;

  const Sale({
    this.id,
    this.customerId,
    required this.saleDate,
    this.courierCharge = 0,
    required this.totalAmount,
    this.paidAmount = 0,
    this.isCredit = false,
    this.saleType = 'retail',
    this.createdBy,
    required this.createdAt,
    this.syncId,
  });

  factory Sale.fromMap(Map<String, dynamic> map) {
    return Sale(
      id: map['id'] as int?,
      customerId: map['customer_id'] as int?,
      saleDate: map['sale_date'] as String,
      courierCharge: (map['courier_charge'] as num?)?.toDouble() ?? 0,
      totalAmount: (map['total_amount'] as num).toDouble(),
      paidAmount: (map['paid_amount'] as num?)?.toDouble() ?? 0,
      isCredit: (map['is_credit'] as int? ?? 0) == 1,
      saleType: map['sale_type'] as String? ?? 'retail',
      createdBy: map['created_by'] as int?,
      createdAt: map['created_at'] as String,
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'customer_id': customerId,
      'sale_date': saleDate,
      'courier_charge': courierCharge,
      'total_amount': totalAmount,
      'paid_amount': paidAmount,
      'is_credit': isCredit ? 1 : 0,
      'sale_type': saleType,
      'created_by': createdBy,
      'created_at': createdAt,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}

class SaleItem {
  final int? id;
  final int saleId;
  final int productId;
  final int? productUnitId; // NULL হলে বোঝাবে product-এর base unit-এ বিক্রি হয়েছে
  final double quantity; // যে unit-এ বিক্রি হয়েছে তার সংখ্যা (যেমন "২ x 500g" হলে 2)
  final double baseQuantity; // stock থেকে বাস্তবে কাটা base-unit পরিমাণ (snapshot)
  final double unitPrice;
  final double totalCost; // FIFO থেকে হিসাব করা মোট cost (profit বের করতে)
  final String? syncId;

  const SaleItem({
    this.id,
    required this.saleId,
    required this.productId,
    this.productUnitId,
    required this.quantity,
    required this.baseQuantity,
    required this.unitPrice,
    required this.totalCost,
    this.syncId,
  });

  double get totalPrice => quantity * unitPrice;
  double get profit => totalPrice - totalCost;

  factory SaleItem.fromMap(Map<String, dynamic> map) {
    return SaleItem(
      id: map['id'] as int?,
      saleId: map['sale_id'] as int,
      productId: map['product_id'] as int,
      productUnitId: map['product_unit_id'] as int?,
      quantity: (map['quantity'] as num).toDouble(),
      // পুরনো (v3-পূর্ববর্তী) row-এ base_quantity নাও থাকতে পারে — সেক্ষেত্রে
      // quantity-কেই base_quantity ধরা নিরাপদ, কারণ তখন multi-unit ছিল না
      baseQuantity: (map['base_quantity'] as num?)?.toDouble() ??
          (map['quantity'] as num).toDouble(),
      unitPrice: (map['unit_price'] as num).toDouble(),
      totalCost: (map['total_cost'] as num).toDouble(),
      syncId: map['sync_id'] as String?,
    );
  }

  Map<String, dynamic> toMap({bool includeId = false}) {
    final map = <String, dynamic>{
      'sale_id': saleId,
      'product_id': productId,
      'product_unit_id': productUnitId,
      'quantity': quantity,
      'base_quantity': baseQuantity,
      'unit_price': unitPrice,
      'total_cost': totalCost,
      'sync_id': syncId,
    };
    if (includeId && id != null) map['id'] = id;
    return map;
  }
}
