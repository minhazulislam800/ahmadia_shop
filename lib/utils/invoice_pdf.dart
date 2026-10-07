// ============================================================
// invoice_pdf.dart
// আধুনিক ডিজাইনের ইনভয়েস PDF তৈরি করে।
//
// কেন ছবি (image) হিসেবে আঁকা হচ্ছে: pdf প্যাকেজ বাংলা যুক্তাক্ষর ও
// কার-চিহ্নের সঠিক shaping করতে পারে না, ফলে লেখা ভেঙে যায় ও ঘর
// ঘর (□) দেখায়। তাই ইনভয়েসটা Flutter-এর নিজস্ব টেক্সট ইঞ্জিন দিয়ে
// (যেটা বাংলা সঠিকভাবে দেখায়) ছবিতে এঁকে সেই ছবি PDF-এ বসানো হয়।
//
// লেআউট: A4 কাগজের উপরের অর্ধেকে একটা ইনভয়েস — নিচের অর্ধেক খালি
// থাকে, যাতে একই কাগজে পরে আরেকটা ইনভয়েস প্রিন্ট করা যায়। পণ্য
// ১০টার বেশি হলে ইনভয়েস পুরো পাতা নেয় (বেশি হলে একাধিক পাতা)।
// ============================================================

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart' show NumberFormat;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite/sqflite.dart';
import '../database/db_helper.dart';
import 'app_theme.dart';
import 'shop_defaults.dart';

class _InvoiceRow {
  final String name;
  final String qty;
  final String price;
  final String total;
  const _InvoiceRow(this.name, this.qty, this.price, this.total);
}

class _InvoiceData {
  final int saleId;
  final String date;
  final String shopName;
  final String shopAddress;
  final String shopPhone;
  final ui.Image? logo;
  final bool logoIsBrand;
  final String customerName;
  final String customerContact;
  final String saleType;
  final String invoiceNo; // কমপক্ষে ২ অঙ্ক (০১, ০২ …)
  final String dateText; // DD-MM-YYYY
  final String payLabel; // পরিশোধিত / আংশিক পরিশোধ / সম্পূর্ণ বাকি
  final List<_InvoiceRow> rows;
  final double productsTotal;
  final double courier;
  final double grandTotal;
  final double paid;
  final double due;
  final bool isCredit;

  const _InvoiceData({
    required this.saleId,
    required this.date,
    required this.shopName,
    required this.shopAddress,
    required this.shopPhone,
    required this.logo,
    required this.logoIsBrand,
    required this.customerName,
    required this.customerContact,
    required this.saleType,
    required this.invoiceNo,
    required this.dateText,
    required this.payLabel,
    required this.rows,
    required this.productsTotal,
    required this.courier,
    required this.grandTotal,
    required this.paid,
    required this.due,
    required this.isCredit,
  });
}

class _RenderedPage {
  final Uint8List png;
  final int widthPx;
  final int heightPx;
  const _RenderedPage(this.png, this.widthPx, this.heightPx);
}

class InvoicePdfGenerator {
  // ডিজাইনের মাপ লজিক্যাল পিক্সেলে (A4 = 794 x 1123 @96dpi)
  static const double _w = 794;
  static const double _scale = 2.0; // আউটপুট ছবির sharpness
  // নতুন ডিজাইনে হেডার ও ব্র্যান্ড বক্স আছে, তাই অর্ধেক A4-তে ৮টা পণ্য ধরে
  static const int _halfPageRows = 8;
  static const int _fullPageRows = 28;
  static const double _left = 30;
  static const double _right = _w - 30;
  static const double _rowHeight = 25;
  static const double _brandBoxH = 134;
  static const String _font = 'NotoSansBengali';
  static const Color _green = Color(0xFF3F7637); // লোগোর সবুজ
  static const Color _orange = Color(0xFFFD9E0F); // লোগোর কমলা
  static const Color _tint = Color(0xFFF1F6EF);
  static const Color _red = Color(0xFFD32F2F);
  static const Color _redBg = Color(0xFFFDECEA);
  static const Color _greenBg = Color(0xFFE4F1E1);
  static const Color _zebra = Color(0xFFF7F9F6);

  static final NumberFormat _money = NumberFormat('#,##0');

  static String _taka(double v) => '৳ ${_money.format(v.round())}';

  // রেট ভগ্নাংশ হতে পারে (যেমন প্রতি গ্রাম ৳০.১২) — তাই দশমিক সহ দেখানো হয়
  static String _rate(double v) {
    if (v == v.roundToDouble()) return _taka(v);
    var s = v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
    return '৳ $s';
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  static String _dateText(String raw) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.day)}-${two(dt.month)}-${dt.year}';
  }

  /// শেয়ার করা ফাইলের নাম: Invoice_AS_<তারিখ DD-MM-YY>_<ইনভয়েস নম্বর>.pdf
  /// (যেমন Invoice_AS_01-12-26_01) — তারিখ ইনভয়েসের নিজের (বিক্রয়ের) তারিখ
  static Future<String> fileName(int saleId) async {
    final db = await DBHelper.instance.database;
    final rows = await db.query('sales',
        columns: ['sale_date'], where: 'id = ?', whereArgs: [saleId]);
    var date = '';
    if (rows.isNotEmpty) {
      final dt = DateTime.tryParse('${rows.first['sale_date']}');
      if (dt != null) {
        String two(int v) => v.toString().padLeft(2, '0');
        date = '${two(dt.day)}-${two(dt.month)}-${two(dt.year % 100)}';
      }
    }
    final number = saleId.toString().padLeft(2, '0');
    return 'Invoice_${ShopDefaults.shortName}_${date.isEmpty ? 'NA' : date}_$number.pdf';
  }

  static Future<Uint8List> generate(int saleId) async {
    final db = await DBHelper.instance.database;

    final sale =
        (await db.query('sales', where: 'id = ?', whereArgs: [saleId])).first;

    Map<String, dynamic>? customer;
    if (sale['customer_id'] != null) {
      final result = await db
          .query('customers', where: 'id = ?', whereArgs: [sale['customer_id']]);
      if (result.isNotEmpty) customer = result.first;
    }

    // Phase 1 (multi-unit): sale_items.quantity এখন যে unit-এ বিক্রি হয়েছে
    // তার সংখ্যা (যেমন pack হলে pack-সংখ্যা) — তাই invoice-এ pu.unit_label
    // (pack-এর নাম, যেমন "500g") দেখাতে হবে, শুধু p.unit (base unit,
    // যেমন "gram") না। product_unit_id NULL থাকলে (সরাসরি base unit-এ
    // বিক্রি) COALESCE দিয়ে p.unit-এই ফলব্যাক হবে।
    final items = await db.rawQuery('''
      SELECT si.*, p.name as product_name, p.unit as base_unit,
             pu.unit_label as pack_unit_label
      FROM sale_items si
      JOIN products p ON p.id = si.product_id
      LEFT JOIN product_units pu ON pu.id = si.product_unit_id
      WHERE si.sale_id = ?
    ''', [saleId]);

    final settings = await _getSettings(db);

    // সেটিংসে নিজে বেছে নেওয়া লোগো আগে; না থাকলে অ্যাপের বান্ডল করা
    // Ahmadia Shop লোগো (assets/images/logo_horizontal.png); সেটাও না
    // পেলে শুধু দোকানের নাম লেখা হবে
    ui.Image? logo;
    var logoIsBrand = false;
    final logoPath = settings['shop_logo_path'];
    if (logoPath != null && logoPath.isNotEmpty && File(logoPath).existsSync()) {
      logo = await _decodeLogo(await File(logoPath).readAsBytes());
    }
    if (logo == null) {
      try {
        final data = await rootBundle.load('assets/images/logo_horizontal.png');
        logo = await _decodeLogo(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        logoIsBrand = logo != null;
      } catch (_) {
        logo = null;
      }
    }

    final courierCharge = (sale['courier_charge'] as num).toDouble();
    final productsTotal = (sale['total_amount'] as num).toDouble();
    final paid = (sale['paid_amount'] as num).toDouble();
    final isCredit = sale['is_credit'] == 1;

    final rows = items.map((item) {
      final qty = (item['quantity'] as num).toDouble();
      final price = (item['unit_price'] as num).toDouble();
      final unitLabel =
          (item['pack_unit_label'] as String?) ?? (item['base_unit'] as String);
      return _InvoiceRow(
        '${item['product_name']}',
        '${_num(qty)} $unitLabel',
        _rate(price),
        _taka(qty * price),
      );
    }).toList();

    final contactParts = <String>[];
    if (customer != null) {
      final phone = (customer['phone'] as String? ?? '').trim();
      final address = (customer['address'] as String? ?? '').trim();
      if (phone.isNotEmpty) contactParts.add(phone);
      if (address.isNotEmpty) contactParts.add(address);
    }

    final saleTypeRaw = sale['sale_type'] as String? ?? 'retail';

    final data = _InvoiceData(
      saleId: saleId,
      date: '${sale['sale_date']}',
      shopName: (settings['shop_name'] ?? '').isEmpty
          ? 'Ahmadia Shop'
          : settings['shop_name']!,
      shopAddress: (settings['shop_address'] ?? '').trim().isEmpty
          ? ShopDefaults.address
          : settings['shop_address']!.trim(),
      shopPhone: (settings['shop_phone'] ?? '').trim().isEmpty
          ? ShopDefaults.phone
          : settings['shop_phone']!.trim(),
      logo: logo,
      logoIsBrand: logoIsBrand,
      customerName:
          customer == null ? 'নগদ ক্রেতা' : (customer['name'] as String? ?? ''),
      customerContact: contactParts.join(' • '),
      saleType: saleTypeRaw == 'wholesale' ? 'পাইকারি' : 'খুচরা',
      invoiceNo: saleId.toString().padLeft(2, '0'),
      dateText: _dateText('${sale['sale_date']}'),
      payLabel: (!isCredit || productsTotal - paid <= 0)
          ? 'পরিশোধিত'
          : (paid > 0 ? 'আংশিক পরিশোধ' : 'সম্পূর্ণ বাকি'),
      rows: rows,
      productsTotal: productsTotal,
      courier: courierCharge,
      grandTotal: productsTotal + courierCharge,
      paid: paid,
      due: isCredit ? productsTotal - paid : 0.0,
      isCredit: isCredit,
    );

    // পণ্য ১০টা পর্যন্ত হলে অর্ধেক পাতায়, বেশি হলে পুরো পাতার ভাগে ভাগ করা
    final chunks = <List<_InvoiceRow>>[];
    if (rows.length <= _halfPageRows) {
      chunks.add(rows);
    } else {
      for (var i = 0; i < rows.length; i += _fullPageRows) {
        final end = i + _fullPageRows > rows.length ? rows.length : i + _fullPageRows;
        chunks.add(rows.sublist(i, end));
      }
    }

    final pages = <_RenderedPage>[];
    for (var i = 0; i < chunks.length; i++) {
      pages.add(await _renderChunk(
        data,
        chunks[i],
        i * _fullPageRows,
        i == chunks.length - 1,
        i + 1,
        chunks.length,
      ));
    }
    logo?.dispose();

    final doc = pw.Document();
    final pageWidthPt = PdfPageFormat.a4.width;
    for (final page in pages) {
      final image = pw.MemoryImage(page.png);
      final heightPt = page.heightPx / page.widthPx * pageWidthPt;
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Align(
            alignment: pw.Alignment.topLeft,
            child: pw.Image(
              image,
              width: pageWidthPt,
              height: heightPt,
              fit: pw.BoxFit.fill,
            ),
          ),
        ),
      );
    }

    return doc.save();
  }

  static Future<ui.Image?> _decodeLogo(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec =
          await ui.instantiateImageCodecFromBuffer(buffer, targetWidth: 720);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null; // লোগো পড়া না গেলে লোগো ছাড়াই ইনভয়েস হবে
    }
  }

  // টেক্সট এঁকে তার উচ্চতা ফেরত দেয়। align: left হলে x = বাম প্রান্ত,
  // right হলে x = ডান প্রান্ত, center হলে x = মাঝের বিন্দু
  static double _text(
    Canvas canvas,
    String text,
    double x,
    double y, {
    double size = 11,
    bool bold = false,
    Color color = AppColors.textPrimary,
    double? maxWidth,
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _font,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          color: color,
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );
    painter.layout(maxWidth: maxWidth ?? double.infinity);
    double dx = x;
    if (align == TextAlign.right) {
      dx = x - painter.width;
    } else if (align == TextAlign.center) {
      dx = x - painter.width / 2;
    }
    painter.paint(canvas, Offset(dx, y));
    final h = painter.height;
    painter.dispose();
    return h;
  }

  // টেক্সটের প্রস্থ মাপা (স্ট্যাটাস ক্যাপসুলের মাপ ঠিক করতে)
  static double _textWidth(String text, double size, {bool bold = false}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _font,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  // একাধিক লাইনে ভাঙা অনুচ্ছেদ আঁকে, উচ্চতা ফেরত দেয়
  static double _paragraph(
    Canvas canvas,
    String text,
    double x,
    double y,
    double width, {
    double size = 9.5,
    bool bold = false,
    Color color = AppColors.textSecondary,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _font,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          color: color,
          height: 1.35,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    painter.paint(canvas, Offset(x, y));
    final h = painter.height;
    painter.dispose();
    return h;
  }

  // নতুন ডিজাইন: উপরে রঙিন স্ট্রাইপ, লোগো + ইনভয়েস নম্বর/তারিখ/স্ট্যাটাস, তথ্য-কার্ড,
  // ডোরাকাটা পণ্যের টেবিল, নিচে বাঁয়ে ব্র্যান্ড বক্স ও ডানে মোট হিসাবের বক্স
  static Future<_RenderedPage> _renderChunk(
    _InvoiceData d,
    List<_InvoiceRow> rows,
    int startIndex,
    bool isLast,
    int pageNo,
    int pageCount,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(_scale);
    canvas.drawRect(const Rect.fromLTWH(0, 0, _w, 2000), Paint()..color = Colors.white);

    const left = _left;
    const right = _right;
    final hasDue = d.due > 0;

    // ---------- উপরের রঙিন স্ট্রাইপ ----------
    canvas.drawRect(const Rect.fromLTWH(0, 0, _w, 8), Paint()..color = _green);
    canvas.drawRect(const Rect.fromLTWH(_w - 170, 0, 170, 8), Paint()..color = _orange);

    // ---------- হেডার: বাঁয়ে লোগো ও যোগাযোগ, ডানে ইনভয়েস তথ্য ----------
    const logoBoxW = 230.0;
    const logoBoxH = 52.0;
    const logoTop = 20.0;
    if (d.logo != null) {
      final lw = d.logo!.width.toDouble();
      final lh = d.logo!.height.toDouble();
      final fitScale = math.min(logoBoxW / lw, logoBoxH / lh);
      final dw = lw * fitScale;
      final dh = lh * fitScale;
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(left, logoTop + (logoBoxH - dh) / 2, dw, dh),
        image: d.logo!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
      if (!d.logoIsBrand) {
        // নিজের বেছে নেওয়া লোগো হলে পাশে দোকানের নাম
        _text(canvas, d.shopName, left + dw + 12, logoTop + (logoBoxH - 26) / 2,
            size: 20, bold: true, color: _green, maxWidth: 300 - dw);
      }
    } else {
      _text(canvas, d.shopName, left, logoTop + 10,
          size: 22, bold: true, color: _green, maxWidth: 400);
    }

    // ঠিকানা ও ফোন এক লাইনে — নিচের রেখার সাথে মিশে যায় না
    final contactLine = [
      if (d.shopAddress.isNotEmpty) d.shopAddress,
      if (d.shopPhone.isNotEmpty) 'ফোন: ${d.shopPhone}',
    ].join('   •   ');
    if (contactLine.isNotEmpty) {
      _text(canvas, contactLine, left, 76,
          size: 10, color: AppColors.textSecondary, maxWidth: 470);
    }

    _text(canvas, 'ইনভয়েস', right, 16,
        size: 26, bold: true, color: _green, align: TextAlign.right);
    _text(
        canvas,
        '#${d.invoiceNo}   •   ${d.dateText}${pageCount > 1 ? '   •   পৃষ্ঠা $pageNo/$pageCount' : ''}',
        right,
        50,
        size: 12,
        bold: true,
        align: TextAlign.right);
    final statusText = hasDue ? 'বাকি আছে' : 'পরিশোধিত';
    final pillW = _textWidth(statusText, 10.5, bold: true) + 26;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(right - pillW, 70, pillW, 20), const Radius.circular(10)),
      Paint()..color = hasDue ? _redBg : _greenBg,
    );
    _text(canvas, statusText, right - pillW / 2, 73,
        size: 10.5, bold: true, color: hasDue ? _red : _green, align: TextAlign.center);

    // লোগোর রঙে আলংকারিক রেখা
    canvas.drawRect(Rect.fromLTRB(left, 98, right, 101), Paint()..color = _green);
    canvas.drawRect(const Rect.fromLTWH(left, 98, 90, 3), Paint()..color = _orange);

    // ---------- তথ্য-কার্ড (বিল প্রাপক | বিক্রয়ের ধরন ও পেমেন্ট) ----------
    const cardTop = 112.0;
    const cardH = 50.0;
    const gap = 12.0;
    final cardW = (right - left - gap) / 2;
    final cardPaint = Paint()..color = _tint;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(left, cardTop, cardW, cardH), const Radius.circular(9)),
      cardPaint,
    );
    _text(canvas, 'বিল প্রাপক', left + 14, cardTop + 6,
        size: 9.5, color: AppColors.textSecondary);
    _text(canvas, d.customerName, left + 14, cardTop + 19,
        size: 13, bold: true, maxWidth: cardW - 28);
    if (d.customerContact.isNotEmpty) {
      _text(canvas, d.customerContact, left + 14, cardTop + 35,
          size: 9.5, color: AppColors.textSecondary, maxWidth: cardW - 28);
    }
    final card2Left = left + cardW + gap;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(card2Left, cardTop, cardW, cardH), const Radius.circular(9)),
      cardPaint,
    );
    _text(canvas, 'বিক্রয়ের ধরন', card2Left + 14, cardTop + 6,
        size: 9.5, color: AppColors.textSecondary);
    _text(canvas, d.saleType, card2Left + 14, cardTop + 21, size: 12.5, bold: true);
    _text(canvas, 'পেমেন্ট', card2Left + cardW / 2 + 4, cardTop + 6,
        size: 9.5, color: AppColors.textSecondary);
    _text(canvas, d.payLabel, card2Left + cardW / 2 + 4, cardTop + 21,
        size: 12.5,
        bold: true,
        color: hasDue ? _red : _green,
        maxWidth: cardW / 2 - 18);

    // ---------- পণ্যের টেবিল ----------
    const tableTop = cardTop + cardH + 12;
    const headerH = 24.0;
    const nameLeft = left + 34;
    const totRight = right;
    const rateRight = right - 110;
    const qtyRight = rateRight - 100;

    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(left, tableTop, right - left, headerH),
        topLeft: const Radius.circular(8),
        topRight: const Radius.circular(8),
      ),
      Paint()..color = _green,
    );
    _text(canvas, '#', left + 12, tableTop + 5, size: 10.5, bold: true, color: Colors.white);
    _text(canvas, 'পণ্যের নাম', nameLeft, tableTop + 5,
        size: 10.5, bold: true, color: Colors.white);
    _text(canvas, 'পরিমাণ', qtyRight, tableTop + 5,
        size: 10.5, bold: true, color: Colors.white, align: TextAlign.right);
    _text(canvas, 'রেট', rateRight, tableTop + 5,
        size: 10.5, bold: true, color: Colors.white, align: TextAlign.right);
    _text(canvas, 'মোট', totRight - 12, tableTop + 5,
        size: 10.5, bold: true, color: Colors.white, align: TextAlign.right);

    final zebraPaint = Paint()..color = _zebra;
    final linePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 0.8;
    const rowsTop = tableTop + headerH;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final rowTop = rowsTop + i * _rowHeight;
      if (i.isOdd) {
        canvas.drawRect(Rect.fromLTWH(left, rowTop, right - left, _rowHeight), zebraPaint);
      }
      canvas.drawLine(Offset(left, rowTop + _rowHeight),
          Offset(right, rowTop + _rowHeight), linePaint);
      _text(canvas, '${startIndex + i + 1}', left + 12, rowTop + 5,
          size: 11, color: AppColors.textSecondary);
      _text(canvas, row.name, nameLeft, rowTop + 5,
          size: 11.5, maxWidth: qtyRight - nameLeft - 110);
      _text(canvas, row.qty, qtyRight, rowTop + 5,
          size: 11.5, align: TextAlign.right);
      _text(canvas, row.price, rateRight, rowTop + 5,
          size: 11.5, align: TextAlign.right);
      _text(canvas, row.total, totRight - 12, rowTop + 5,
          size: 11.5, bold: true, align: TextAlign.right);
    }
    final rowsBottom = rowsTop + rows.length * _rowHeight;

    // ---------- নিচের অংশ ----------
    final blockTop = rowsBottom + 14;
    double bottom;
    if (isLast) {
      // বাঁয়ে ব্র্যান্ড বক্স
      const brandW = right - left - 300;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(left, blockTop, brandW, _brandBoxH), const Radius.circular(12)),
        Paint()..color = _tint,
      );
      canvas.drawRect(
          Rect.fromLTWH(left, blockTop + 14, 4, _brandBoxH - 28), Paint()..color = _orange);
      const mx = left + 22;
      final diamond = Path()
        ..moveTo(mx + 4, blockTop + 16)
        ..lineTo(mx + 8, blockTop + 20)
        ..lineTo(mx + 4, blockTop + 24)
        ..lineTo(mx, blockTop + 20)
        ..close();
      canvas.drawPath(diamond, Paint()..color = _orange);
      _text(canvas, 'বিশ্বাসই আমাদের ভিত্তি', mx + 16, blockTop + 10,
          size: 15, bold: true, color: _green, maxWidth: brandW - 60);
      var textY = blockTop + 36;
      textY += _paragraph(
              canvas,
              'Ahmadia Shop — Pure & authentic organic products. Trusted by people who value quality.',
              mx,
              textY,
              brandW - 44) +
          2;
      _paragraph(canvas, 'We deliver what we promise — no compromise.', mx, textY,
          brandW - 44,
          bold: true);
      _text(canvas, 'কেনাকাটার জন্য ধন্যবাদ।', mx, blockTop + _brandBoxH - 26,
          size: 10.5, color: _green);

      // ডানে মোট হিসাব
      const totalsLeft = right - 282;
      var yy = blockTop + 2;
      void summaryRow(String label, String value) {
        _text(canvas, label, totalsLeft + 8, yy,
            size: 11, color: AppColors.textSecondary);
        _text(canvas, value, right - 8, yy, size: 11, align: TextAlign.right);
        yy += 20;
      }

      summaryRow('পণ্যের মোট', _taka(d.productsTotal));
      if (d.courier > 0) summaryRow('কুরিয়ার চার্জ', _taka(d.courier));
      yy += 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(totalsLeft, yy, right - totalsLeft, 36),
            const Radius.circular(10)),
        Paint()..color = _green,
      );
      _text(canvas, 'সর্বমোট', totalsLeft + 14, yy + 9,
          size: 12, bold: true, color: Colors.white);
      _text(canvas, _taka(d.grandTotal), right - 14, yy + 6,
          size: 17, bold: true, color: Colors.white, align: TextAlign.right);
      yy += 44;
      summaryRow('পরিশোধিত', _taka(d.paid));
      if (hasDue) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(totalsLeft, yy - 2, right - totalsLeft, 24),
              const Radius.circular(8)),
          Paint()..color = _redBg,
        );
        _text(canvas, 'বাকি', totalsLeft + 8, yy + 2, size: 12, bold: true, color: _red);
        _text(canvas, _taka(d.due), right - 8, yy + 1,
            size: 13, bold: true, color: _red, align: TextAlign.right);
        yy += 24;
      }
      bottom = math.max(blockTop + _brandBoxH, yy);
    } else {
      _text(canvas, 'পরবর্তী পৃষ্ঠায় চলবে…', right, blockTop,
          size: 10, color: AppColors.textSecondary, align: TextAlign.right);
      bottom = blockTop + 18;
    }
    final totalHeight = bottom + 12;

    final picture = recorder.endRecording();
    final widthPx = (_w * _scale).round();
    final heightPx = (totalHeight * _scale).ceil();
    final image = await picture.toImage(widthPx, heightPx);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();

    final png = byteData!.buffer
        .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
    return _RenderedPage(png, widthPx, heightPx);
  }

  static Future<Map<String, String>> _getSettings(Database db) async {
    final rows = await db.query('app_settings');
    final map = <String, String>{};
    for (final row in rows) {
      map[row['key'] as String] = row['value'] as String? ?? '';
    }
    return map;
  }
}
