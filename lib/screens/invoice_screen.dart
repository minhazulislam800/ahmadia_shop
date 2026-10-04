// ============================================================
// invoice_screen.dart
// বিক্রয়ের পর ইনভয়েস PDF প্রিভিউ দেখানো, শেয়ার/প্রিন্ট করার সুবিধা
// ============================================================

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../utils/invoice_pdf.dart';

class InvoiceScreen extends StatelessWidget {
  final int saleId;
  const InvoiceScreen({super.key, required this.saleId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ইনভয়েস')),
      body: PdfPreview(
        build: (format) => InvoicePdfGenerator.generate(saleId),
        // PdfPreview উইজেট নিজেই "শেয়ার" ও "প্রিন্ট" বাটন দেখায়
        canChangeOrientation: false,
        canChangePageFormat: false,
        allowPrinting: true,
        allowSharing: true,
      ),
    );
  }
}
