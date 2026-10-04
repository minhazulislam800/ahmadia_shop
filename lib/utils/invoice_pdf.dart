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
  static const double _margin = 24;
  static const double _rowH = 22;
  static const int _halfPageRows = 10;
  static const int _fullPageRows = 32;
  static const String _font = 'NotoSansBengali';
  static const Color _green = Color(0xFF3F7637); // লোগোর সবুজ
  static const Color _orange = Color(0xFFFD9E0F); // লোগোর কমলা
  static const Color _tint = Color(0xFFF1F6EF);

  static final NumberFormat _money = NumberFormat('#,##0');

  static String _taka(double v) => '৳ ${_money.format(v.round())}';

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

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
        _taka(price),
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
      shopAddress: settings['shop_address'] ?? '',
      shopPhone: settings['shop_phone'] ?? '',
      logo: logo,
      logoIsBrand: logoIsBrand,
      customerName:
          customer == null ? 'নগদ ক্রেতা' : (customer['name'] as String? ?? ''),
      customerContact: contactParts.join(' • '),
      saleType: saleTypeRaw == 'wholesale' ? 'পাইকারি' : 'খুচরা',
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
    canvas.drawRect(Rect.fromLTWH(0, 0, _w, 2000), Paint()..color = Colors.white);

    final left = _margin;
    final right = _w - _margin;

    // ---------- হেডার: বাঁয়ে লোগো/দোকানের তথ্য, ডানে ইনভয়েস নম্বর ও তারিখ ----------
    const logoBoxW = 230.0;
    const logoBoxH = 56.0;
    const headerTop = 14.0;
    if (d.logo != null) {
      final lw = d.logo!.width.toDouble();
      final lh = d.logo!.height.toDouble();
      final fitScale = math.min(logoBoxW / lw, logoBoxH / lh);
      final dw = lw * fitScale;
      final dh = lh * fitScale;
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(left, headerTop + (logoBoxH - dh) / 2, dw, dh),
        image: d.logo!,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      );
      if (!d.logoIsBrand) {
        // নিজের বেছে নেওয়া লোগো হলে পাশে দোকানের নাম
        _text(canvas, d.shopName, left + dw + 12, headerTop + (logoBoxH - 26) / 2,
            size: 20, bold: true, color: _green, maxWidth: 300 - dw);
      }
    } else {
      _text(canvas, d.shopName, left, headerTop + 12,
          size: 22, bold: true, color: _green, maxWidth: 400);
    }
    var addrY = headerTop + logoBoxH + 4;
    if (d.shopAddress.isNotEmpty) {
      addrY += _text(canvas, d.shopAddress, left, addrY,
          size: 10, color: AppColors.textSecondary, maxWidth: 440);
    }
    if (d.shopPhone.isNotEmpty) {
      _text(canvas, 'ফোন: ${d.shopPhone}', left, addrY,
          size: 10, color: AppColors.textSecondary, maxWidth: 440);
    }

    _text(canvas, 'ইনভয়েস', right, headerTop, size: 21, bold: true, color: _green, align: TextAlign.right);
    _text(
        canvas,
        '#${d.saleId}${pageCount > 1 ? '  •  পৃষ্ঠা $pageNo/$pageCount' : ''}',
        right,
        headerTop + 30,
        size: 12.5,
        bold: true,
        align: TextAlign.right);
    _text(canvas, 'তারিখ: ${d.date}', right, headerTop + 50,
        size: 10.5, color: AppColors.textSecondary, align: TextAlign.right);

    // লোগোর রঙে আলংকারিক রেখা
    canvas.drawRect(Rect.fromLTWH(left, 96, right - left, 3), Paint()..color = _green);
    canvas.drawRect(Rect.fromLTWH(left, 96, 96, 3), Paint()..color = _orange);

    // ---------- তথ্য বক্স (কাস্টমার | পেমেন্ট) ----------
    const gap = 12.0;
    final boxW = (right - left - gap) / 2;
    const boxTop = 112.0;
    const boxH = 50.0;
    final infoPaint = Paint()..color = _tint;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(left, boxTop, boxW, boxH), const Radius.circular(10)),
      infoPaint,
    );
    _text(canvas, 'বিল প্রাপক', left + 12, boxTop + 6,
        size: 9.5, color: AppColors.textSecondary);
    _text(canvas, d.customerName, left + 12, boxTop + 18,
        size: 12.5, bold: true, maxWidth: boxW - 24);
    if (d.customerContact.isNotEmpty) {
      _text(canvas, d.customerContact, left + 12, boxTop + 34,
          size: 10, color: AppColors.textSecondary, maxWidth: boxW - 24);
    }

    final box2Left = left + boxW + gap;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(box2Left, boxTop, boxW, boxH), const Radius.circular(10)),
      infoPaint,
    );
    final isDue = d.due > 0;
    _text(canvas, 'পেমেন্ট অবস্থা', box2Left + 12, boxTop + 6,
        size: 9.5, color: AppColors.textSecondary);
    _text(canvas, isDue ? 'বাকি আছে' : 'পরিশোধিত', box2Left + 12, boxTop + 18,
        size: 12.5,
        bold: true,
        color: isDue ? AppColors.danger : AppColors.success);
    _text(canvas, 'বিক্রয়ের ধরন: ${d.saleType}', box2Left + 12, boxTop + 34,
        size: 10, color: AppColors.textSecondary, maxWidth: boxW - 24);

    // ---------- পণ্যের টেবিল ----------
    var y = 172.0;
    const colNo = 30.0;
    const colQty = 112.0;
    const colPrice = 84.0;
    const colTotal = 96.0;
    final totalColLeft = right - colTotal;
    final priceColLeft = totalColLeft - colPrice;
    final qtyColLeft = priceColLeft - colQty;
    final nameColLeft = left + colNo;
    final nameMaxW = qtyColLeft - nameColLeft - 8;

    const headerH = 24.0;
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(left, y, right - left, headerH),
        topLeft: const Radius.circular(8),
        topRight: const Radius.circular(8),
      ),
      Paint()..color = _green,
    );
    const headerStyleSize = 10.5;
    _text(canvas, '#', left + 8, y + 5,
        size: headerStyleSize, bold: true, color: Colors.white);
    _text(canvas, 'পণ্যের নাম', nameColLeft, y + 5,
        size: headerStyleSize, bold: true, color: Colors.white);
    _text(canvas, 'পরিমাণ', priceColLeft - 8, y + 5,
        size: headerStyleSize,
        bold: true,
        color: Colors.white,
        align: TextAlign.right);
    _text(canvas, 'একক দাম', totalColLeft - 8, y + 5,
        size: headerStyleSize,
        bold: true,
        color: Colors.white,
        align: TextAlign.right);
    _text(canvas, 'মোট', right - 8, y + 5,
        size: headerStyleSize,
        bold: true,
        color: Colors.white,
        align: TextAlign.right);

    final zebraPaint = Paint()..color = const Color(0xFFF7F8FA);
    final linePaint = Paint()
      ..color = AppColors.border
      ..strokeWidth = 0.8;
    final rowsTop = y + headerH;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final rowTop = rowsTop + i * _rowH;
      if (i.isOdd) {
        canvas.drawRect(Rect.fromLTWH(left, rowTop, right - left, _rowH), zebraPaint);
      }
      canvas.drawLine(Offset(left, rowTop + _rowH),
          Offset(right, rowTop + _rowH), linePaint);
      _text(canvas, '${startIndex + i + 1}', left + 8, rowTop + 4, size: 11);
      _text(canvas, row.name, nameColLeft, rowTop + 4,
          size: 11, maxWidth: nameMaxW);
      _text(canvas, row.qty, priceColLeft - 8, rowTop + 4,
          size: 11, maxWidth: colQty - 16, align: TextAlign.right);
      _text(canvas, row.price, totalColLeft - 8, rowTop + 4,
          size: 11, maxWidth: colPrice - 16, align: TextAlign.right);
      _text(canvas, row.total, right - 8, rowTop + 4,
          size: 11, bold: true, maxWidth: colTotal - 16, align: TextAlign.right);
    }

    y = rowsTop + rows.length * _rowH + 12;

    // ---------- মোট হিসাব (শুধু শেষ পাতায়) ----------
    if (isLast) {
      const totalsW = 250.0;
      final bx = right - totalsW;
      final hasCourier = d.courier > 0;
      final double totalsH = 8.0 +
          18 +
          (hasCourier ? 18 : 0) +
          8 +
          26 +
          18 +
          (d.isCredit ? 18 : 0) +
          8;

      if (hasCourier) {
        _text(canvas, 'কুরিয়ার চার্জ গ্রাহক বহন করবেন', left, y + 8,
            size: 9.5, color: AppColors.textSecondary, maxWidth: bx - left - 12);
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(bx, y, totalsW, totalsH), const Radius.circular(10)),
        Paint()..color = _tint,
      );

      var ly = y + 8;
      void line(String label, String value,
          {bool bold = false,
          double size = 11,
          Color color = AppColors.textPrimary,
          double step = 18}) {
        _text(canvas, label, bx + 12, ly, size: size, bold: bold, color: color);
        _text(canvas, value, bx + totalsW - 12, ly,
            size: size, bold: bold, color: color, align: TextAlign.right);
        ly += step;
      }

      line('পণ্যের মোট', _taka(d.productsTotal));
      if (hasCourier) line('কুরিয়ার চার্জ', _taka(d.courier));
      canvas.drawLine(Offset(bx + 12, ly + 2), Offset(bx + totalsW - 12, ly + 2),
          Paint()
            ..color = AppColors.border
            ..strokeWidth = 1);
      ly += 8;
      line('সর্বমোট', _taka(d.grandTotal),
          bold: true, size: 14, color: _green, step: 26);
      line('পরিশোধিত', _taka(d.paid));
      if (d.isCredit) {
        line('বাকি', _taka(d.due),
            bold: true, color: AppColors.danger);
      }

      y += totalsH + 14;
    } else {
      _text(canvas, 'পরবর্তী পৃষ্ঠায় চলবে…', right, y,
          size: 10, color: AppColors.textSecondary, align: TextAlign.right);
      y += 18;
    }

    // ---------- ফুটার ----------
    canvas.drawLine(Offset(left, y), Offset(right, y), linePaint);
    y += 8;
    final footerH = _text(
      canvas,
      isLast ? 'কেনাকাটার জন্য ধন্যবাদ — ${d.shopName}' : d.shopName,
      _w / 2,
      y,
      size: 10.5,
      color: AppColors.textSecondary,
      maxWidth: right - left,
      align: TextAlign.center,
    );
    final totalHeight = y + footerH + 14;

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
