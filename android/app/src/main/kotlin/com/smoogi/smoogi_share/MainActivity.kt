package com.smoogi.smoogi_share

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

/**
 * Android Share target. Shared content URIs are copied (streamed, no whole-file
 * buffering) into the app cache so the Dart side gets plain file paths that
 * stay valid after the sending app revokes its URI permission.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null
    private var dartReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smoogi/share")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> {
                    dartReady = true
                    result.success(pending)
                    pending = null
                }
                else -> result.notImplemented()
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val uris = ArrayList<Uri>()
        if (action == Intent.ACTION_SEND) {
            val u = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (u != null) uris.add(u)
        } else {
            val l = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (l != null) uris.addAll(l)
        }
        // Mark consumed so rotation / relaunch does not re-import.
        intent.action = null

        thread {
            val files = ArrayList<Map<String, Any?>>()
            for (u in uris) {
                try {
                    files.add(importUri(u))
                } catch (e: Exception) {
                    // Skip unreadable items; the rest still import.
                }
            }
            val payload = mapOf("text" to text, "subject" to subject, "files" to files)
            runOnUiThread {
                if (dartReady && channel != null) {
                    channel!!.invokeMethod("onShare", payload)
                } else {
                    pending = payload
                }
            }
        }
    }

    private fun importUri(uri: Uri): Map<String, Any?> {
        var name: String? = null
        if (uri.scheme == "content") {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (i >= 0 && c.moveToFirst()) name = c.getString(i)
            }
        }
        if (name == null) name = uri.lastPathSegment ?: "shared-file"
        val safe = name!!.substringAfterLast('/').ifBlank { "shared-file" }
        val dir = File(cacheDir, "shared/${UUID.randomUUID()}")
        dir.mkdirs()
        val out = File(dir, safe)
        contentResolver.openInputStream(uri)!!.use { input ->
            out.outputStream().use { input.copyTo(it) }
        }
        return mapOf("path" to out.absolutePath, "name" to safe, "mime" to contentResolver.getType(uri))
    }
}
