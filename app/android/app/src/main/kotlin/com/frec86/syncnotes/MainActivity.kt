package com.frec86.syncnotes

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 接收系统“分享”：文字 → 消息；文件 → 复制到缓存目录后交给 Flutter 上传。
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "syncnotes/share").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "getInitialShare") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        pending = readShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val share = readShare(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("shared", share) else pending = share
    }

    private fun readShare(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            streamExtra(intent)?.let { uris.add(it) }
        } else {
            streamListExtra(intent)?.let { uris.addAll(it) }
        }
        val files = uris.mapNotNull { copyToCache(it) }
        // 用过的 intent 清掉，避免旋转/重建时重复导入
        intent.action = null
        if (text == null && files.isEmpty()) return null
        return mapOf("text" to text, "subject" to subject, "files" to files)
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun streamListExtra(intent: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

    private fun copyToCache(uri: Uri): Map<String, Any?>? {
        return try {
            var name = "shared"
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0)?.let { name = it }
            }
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val out = File(dir, "${System.currentTimeMillis()}_${name.replace('/', '_')}")
            contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } } ?: return null
            mapOf("name" to name, "path" to out.absolutePath)
        } catch (e: Exception) {
            null
        }
    }
}
