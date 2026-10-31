package com.frec86.syncnotes

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 系统分享、拍照、语音、通知、桌面快捷方式。
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null
    private var pendingLink: String? = null
    private var photoResult: MethodChannel.Result? = null

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "syncnotes/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                "listen" -> listen(result)
                "capture" -> capture(result)
                "notify" -> {
                    val title = call.argument<String>("title") ?: "SyncNotes"
                    val text = call.argument<String>("text") ?: ""
                    notify(title, text)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        pending = readShare(intent)
        pendingLink = readLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingLink = readLink(intent) ?: pendingLink
        val share = readShare(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("shared", share) else pending = share
    }

    private fun readLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        if (data.scheme != "syncnotes") return null
        return data.host ?: data.path?.trim('/')
    }

    private fun capture(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 42)
            result.error("camera", "需要相机权限，允许后再按一次扫描", null)
            return
        }
        photoResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(Intent(MediaStore.ACTION_IMAGE_CAPTURE), 7)
    }

    @Deprecated("Android camera result")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7) return
        val result = photoResult
        photoResult = null
        if (result == null) return
        val bitmap = data?.extras?.get("data") as? Bitmap
        if (bitmap == null) {
            result.success(null)
            return
        }
        val file = File(cacheDir, "scan_${System.currentTimeMillis()}.jpg")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        result.success(mapOf("name" to file.name, "path" to file.absolutePath))
    }

    private fun listen(result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("speech", "这台手机没有语音识别", null)
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), 41)
            result.error("mic", "需要麦克风权限，允许后再按一次语音", null)
            return
        }
        val recognizer = SpeechRecognizer.createSpeechRecognizer(this)
        val listen = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
        }
        var done = false
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onResults(bundle: Bundle?) {
                if (done) return
                done = true
                val text = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
                result.success(text)
                recognizer.destroy()
            }

            override fun onError(error: Int) {
                if (done) return
                done = true
                result.error("speech", "没听清", error)
                recognizer.destroy()
            }

            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        recognizer.startListening(listen)
    }

    private fun notify(title: String, text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel("reminders", "提醒", NotificationManager.IMPORTANCE_DEFAULT))
        }
        if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 43)
            return
        }
        val notification = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, "reminders")
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }.setContentTitle(title).setContentText(text).setSmallIcon(android.R.drawable.ic_dialog_info).build()
        nm.notify(title.hashCode(), notification)
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
