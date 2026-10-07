// ============================================================
// invoice_screen.dart
// বিক্রয়ের পর ইনভয়েস PDF প্রিভিউ দেখানো, শেয়ার/প্রিন্ট করার সুবিধা
// শেয়ারের ফাইলের নাম: Invoice_AS_<তারিখ>_<নম্বর>.pdf
// ============================================================

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import '../utils/invoice_pdf.dart';

class InvoiceScreen extends StatefulWidget {
  final int saleId;
  const InvoiceScreen({super.key, required this.saleId});

  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen> {
  String _fileName = 'Invoice_AS.pdf';
  bool _nameReady = false;

  @override
  void initState() {
    super.initState();
    _loadName();
  }

  Future<void> _loadName() async {
    try {
      final name = await InvoicePdfGenerator.fileName(widget.saleId);
      if (!mounted) return;
      setState(() {
        _fileName = name;
        _nameReady = true;
      });
    } catch (_) {
      if (mounted) setState(() => _nameReady = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ইনভয়েস')),
      body: !_nameReady
          ? const Center(child: CircularProgressIndicator())
          : PdfPreview(
              build: (format) => InvoicePdfGenerator.generate(widget.saleId),
              pdfFileName: _fileName,
              // PdfPreview উইজেট নিজেই "শেয়ার" ও "প্রিন্ট" বাটন দেখায়
              canChangeOrientation: false,
              canChangePageFormat: false,
              allowPrinting: true,
              allowSharing: true,
            ),
    );
  }
}
