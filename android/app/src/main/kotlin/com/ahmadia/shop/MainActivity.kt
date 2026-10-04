package com.ahmadia.shop

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.util.Date

// ব্যাকআপ ফাইল (.backup) হোয়াটসঅ্যাপ/ফাইল ম্যানেজার থেকে "Open with" করলে
// ফাইলটা অ্যাপের cache-এ কপি করে Flutter-কে জানায়, যাতে অ্যাপ ইমপোর্ট স্ক্রিন খোলে।
class MainActivity : FlutterActivity() {
    private val channelName = "ahmadia/incoming_file"
    private var channel: MethodChannel? = null
    private var pendingFile: Map<String, String>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        installCrashLogger()
        super.onCreate(savedInstanceState)
    }

    private fun crashFile(): File = File(filesDir, "native_crash.txt")

    // Android-এর অপ্রত্যাশিত ক্র্যাশের বিবরণ ফাইলে রাখে; পরেরবার অ্যাপ খুললে দেখানো হয়
    private fun installCrashLogger() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val writer = StringWriter()
                throwable.printStackTrace(PrintWriter(writer))
                crashFile().writeText(Date().toString() + "\n" + writer.toString())
            } catch (e: Exception) {
                // লগ লেখা ব্যর্থ হলেও মূল ক্র্যাশ হ্যান্ডলারে যেতে হবে
            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        ch.setMethodCallHandler { call, result ->
            if (call.method == "getInitialFile") {
                val file = pendingFile
                pendingFile = null
                result.success(file)
            } else if (call.method == "getNativeCrash") {
                val f = crashFile()
                if (f.exists()) {
                    val text = f.readText()
                    f.delete()
                    result.success(text)
                } else {
                    result.success(null)
                }
            } else {
                result.notImplemented()
            }
        }
        channel = ch
        pendingFile = extractFile(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val file = extractFile(intent)
        if (file != null) {
            channel?.invokeMethod("onFile", file)
        }
    }

    private fun extractFile(intent: Intent?): Map<String, String>? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        val uri: Uri = intent.data ?: return null
        return try {
            val copied = copyToCache(uri)
            // একই intent যেন দ্বিতীয়বার ইমপোর্ট স্ক্রিন না খোলে
            intent.action = Intent.ACTION_MAIN
            copied
        } catch (e: Exception) {
            null
        }
    }

    private fun copyToCache(uri: Uri): Map<String, String>? {
        var displayName: String? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) {
                    displayName = cursor.getString(idx)
                }
            }
        } catch (e: Exception) {
            // নাম না পেলে নিচে ফলব্যাক ব্যবহার হবে
        }
        val name = displayName ?: uri.lastPathSegment ?: "backup.backup"

        cacheDir.listFiles()?.forEach {
            if (it.name.startsWith("incoming_")) it.delete()
        }
        val target = File(cacheDir, "incoming_" + System.currentTimeMillis() + ".backup")
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { ins ->
            FileOutputStream(target).use { out -> ins.copyTo(out) }
        }
        return mapOf("path" to target.absolutePath, "name" to name)
    }
}
