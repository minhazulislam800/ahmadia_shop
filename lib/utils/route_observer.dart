// ============================================================
// route_observer.dart
// হোম (ড্যাশবোর্ড) স্ক্রিনে অন্য কোনো স্ক্রিন থেকে ফিরে এলে
// সংখ্যাগুলো (ক্যাশ, বাকি, লাভ ইত্যাদি) নিজে থেকে রিফ্রেশ করার
// জন্য একটা shared RouteObserver।
// ============================================================

import 'package:flutter/material.dart';

final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();
