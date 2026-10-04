// ============================================================
// report_pdf.dart
// সব রিপোর্টের PDF (বিক্রয়/ক্রয় রিপোর্ট, ইনভেন্টরি, বাৎসরিক সামারি)
// বানানোর একটাই shared কোড।
//
// pdf প্যাকেজ বাংলা যুক্তাক্ষর ও কার-চিহ্ন ঠিকভাবে সাজাতে পারে না,
// তাই লেখা ভেঙে যায়। এখানে প্রতিটা পাতা Flutter-এর নিজস্ব টেক্সট
// ইঞ্জিন দিয়ে (যেটা বাংলা সঠিকভাবে দেখায়) ছবিতে এঁকে A4 PDF-এ
// বসানো হয়। টেবিল বড় হলে নিজে থেকেই পরের পাতায় যায় এবং প্রতি
// নতুন পাতায় টেবিলের হেডার আবার বসে।
// ============================================================

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'app_theme.dart';

abstract class ReportBlock {
  const ReportBlock();
}

class ReportHeading extends ReportBlock {
  final String text;
  const ReportHeading(this.text);
}

class ReportKeyValue extends ReportBlock {
  final String label;
  final String value;
  final bool bold;
  const ReportKeyValue(this.label, this.value, {this.bold = false});
}

class ReportSpace extends ReportBlock {
  final double height;
  const ReportSpace(this.height);
}

class ReportDivider extends ReportBlock {
  const ReportDivider();
}

class ReportTable extends ReportBlock {
  final List<String> headers;
  final List<List<String>> rows;
  final List<double> flex;
  final List<bool> rightAlign;
  const ReportTable({
    required this.headers,
    required this.rows,
    required this.flex,
    required this.rightAlign,
  });
}

class ReportPdf {
  static const double _w = 794;
  static const double _h = 1123;
  static const double _scale = 2.0;
  static const double _margin = 36;
  static const double _bottom = _h - 54;
  static const String _font = 'NotoSansBengali';

  static TextPainter _painter(
    String text, {
    double size = 11,
    bool bold = false,
    Color color = AppColors.textPrimary,
    required double width,
    bool right = false,
    int? maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: _font,
          fontSize: size,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          color: color,
          height: 1.3,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: right ? TextAlign.right : TextAlign.left,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    );
    painter.layout(minWidth: width, maxWidth: width);
    return painter;
  }

  static Future<Uint8List> build({
    required String title,
    List<String> subtitles = const [],
    required List<ReportBlock> blocks,
    String shopName = 'Ahmadia Shop',
  }) async {
    const contentW = _w - 2 * _margin;
    final pages = <List<void Function(Canvas)>>[<void Function(Canvas)>[]];
    var y = _margin;

    List<void Function(Canvas)> cur() => pages.last;

    void newPage() {
      pages.add(<void Function(Canvas)>[]);
      y = _margin;
      final running = _painter('$title — $shopName',
          size: 9, color: AppColors.textSecondary, width: contentW, maxLines: 1);
      final yy = y;
      cur().add((c) => running.paint(c, Offset(_margin, yy)));
      y += 24;
    }

    // ---------- প্রথম পাতার শিরোনাম ----------
    final titleP = _painter(title,
        size: 20,
        bold: true,
        color: AppColors.primary,
        width: contentW,
        maxLines: 2);
    final titleY = y;
    cur().add((c) => titleP.paint(c, Offset(_margin, titleY)));
    y += titleP.height + 4;
    for (final line in subtitles) {
      final p = _painter(line,
          size: 11, color: AppColors.textSecondary, width: contentW, maxLines: 2);
      final yy = y;
      cur().add((c) => p.paint(c, Offset(_margin, yy)));
      y += p.height + 2;
    }
    final ruleY = y + 6;
    cur().add((c) => c.drawLine(
        Offset(_margin, ruleY),
        Offset(_w - _margin, ruleY),
        Paint()
          ..color = AppColors.primary
          ..strokeWidth = 2));
    y += 20;

    // ---------- ব্লকগুলো সাজানো ----------
    for (final block in blocks) {
      if (block is ReportSpace) {
        y += block.height;
      } else if (block is ReportDivider) {
        if (y + 12 > _bottom) newPage();
        final yy = y + 4;
        cur().add((c) => c.drawLine(
            Offset(_margin, yy),
            Offset(_w - _margin, yy),
            Paint()
              ..color = AppColors.border
              ..strokeWidth = 1));
        y += 12;
      } else if (block is ReportHeading) {
        if (y + 40 > _bottom) newPage();
        y += 8;
        final p = _painter(block.text,
            size: 14, bold: true, width: contentW, maxLines: 2);
        final yy = y;
        cur().add((c) => p.paint(c, Offset(_margin, yy)));
        y += p.height + 6;
      } else if (block is ReportKeyValue) {
        const valueW = 150.0;
        final size = block.bold ? 12.5 : 11.5;
        final labelP = _painter(block.label,
            size: size,
            bold: block.bold,
            width: contentW - valueW - 12,
            maxLines: 2);
        final valueP = _painter(block.value,
            size: size, bold: block.bold, width: valueW, right: true, maxLines: 1);
        final rowH = math.max(labelP.height, valueP.height);
        if (y + rowH > _bottom) newPage();
        final yy = y;
        cur().add((c) {
          labelP.paint(c, Offset(_margin, yy));
          valueP.paint(c, Offset(_w - _margin - valueW, yy));
        });
        y += rowH + 6;
      } else if (block is ReportTable) {
        final flexSum = block.flex.fold<double>(0, (a, b) => a + b);
        final widths = block.flex.map((f) => contentW * f / flexSum).toList();

        void drawHeader() {
          final painters = <TextPainter>[];
          var hh = 0.0;
          for (var i = 0; i < block.headers.length; i++) {
            final p = _painter(block.headers[i],
                size: 10.5,
                bold: true,
                color: Colors.white,
                width: widths[i] - 12,
                right: block.rightAlign[i],
                maxLines: 2);
            painters.add(p);
            hh = math.max(hh, p.height);
          }
          hh += 10;
          final yy = y;
          cur().add((c) {
            c.drawRect(Rect.fromLTWH(_margin, yy, contentW, hh),
                Paint()..color = AppColors.primary);
            var x = _margin;
            for (var i = 0; i < painters.length; i++) {
              painters[i].paint(c, Offset(x + 6, yy + 5));
              x += widths[i];
            }
          });
          y += hh;
        }

        if (y + 60 > _bottom) newPage();
        drawHeader();

        for (var r = 0; r < block.rows.length; r++) {
          final row = block.rows[r];
          final painters = <TextPainter>[];
          var rh = 0.0;
          for (var i = 0; i < widths.length; i++) {
            final text = i < row.length ? row[i] : '';
            final p = _painter(text,
                size: 10.5,
                width: widths[i] - 12,
                right: block.rightAlign[i],
                maxLines: 3);
            painters.add(p);
            rh = math.max(rh, p.height);
          }
          rh += 10;

          if (y + rh > _bottom) {
            newPage();
            drawHeader();
          }

          final yy = y;
          final zebra = r.isOdd;
          cur().add((c) {
            if (zebra) {
              c.drawRect(Rect.fromLTWH(_margin, yy, contentW, rh),
                  Paint()..color = const Color(0xFFF7F8FA));
            }
            c.drawLine(
                Offset(_margin, yy + rh),
                Offset(_w - _margin, yy + rh),
                Paint()
                  ..color = AppColors.border
                  ..strokeWidth = 0.8);
            var x = _margin;
            for (var i = 0; i < painters.length; i++) {
              painters[i].paint(c, Offset(x + 6, yy + 5));
              x += widths[i];
            }
          });
          y += rh;
        }
        y += 8;
      }
    }

    // ---------- ছবি → PDF ----------
    final total = pages.length;
    final doc = pw.Document();
    for (var i = 0; i < total; i++) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.scale(_scale);
      canvas.drawRect(
          const Rect.fromLTWH(0, 0, _w, _h), Paint()..color = Colors.white);
      for (final draw in pages[i]) {
        draw(canvas);
      }
      final footer = _painter('$shopName  •  পৃষ্ঠা ${i + 1}/$total',
          size: 9, color: AppColors.textSecondary, width: contentW, maxLines: 1);
      canvas.drawLine(
          const Offset(_margin, _h - 40),
          const Offset(_w - _margin, _h - 40),
          Paint()
            ..color = AppColors.border
            ..strokeWidth = 0.8);
      footer.paint(canvas, const Offset(_margin, _h - 32));

      final picture = recorder.endRecording();
      final image = await picture.toImage(
          (_w * _scale).round(), (_h * _scale).round());
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final png = byteData!.buffer
          .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);

      final pdfImage = pw.MemoryImage(png);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.Image(
            pdfImage,
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.fill,
          ),
        ),
      );
    }
    return doc.save();
  }
}
