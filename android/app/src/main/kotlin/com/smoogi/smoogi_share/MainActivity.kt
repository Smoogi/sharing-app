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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "smoogi/vault")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "read" -> result.success(vaultRead())
                        "write" -> { vaultWrite(call.arguments as String); result.success(null) }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("vault", e.message, null)
                }
            }
        handleIntent(intent)
    }

    // --- Android Keystore vault: the AES-GCM key never leaves the Keystore ----
    private fun vaultKey(): javax.crypto.SecretKey {
        val ks = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey("smoogi_seed_key", null) as? javax.crypto.SecretKey)?.let { return it }
        val gen = javax.crypto.KeyGenerator.getInstance(
            android.security.keystore.KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(android.security.keystore.KeyGenParameterSpec.Builder(
            "smoogi_seed_key",
            android.security.keystore.KeyProperties.PURPOSE_ENCRYPT or
                android.security.keystore.KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(android.security.keystore.KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(android.security.keystore.KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build())
        return gen.generateKey()
    }

    private fun vaultWrite(value: String) {
        val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        c.init(javax.crypto.Cipher.ENCRYPT_MODE, vaultKey())
        val blob = c.iv + c.doFinal(value.toByteArray(Charsets.UTF_8))
        getSharedPreferences("smoogi_vault", MODE_PRIVATE).edit()
            .putString("seed", android.util.Base64.encodeToString(blob, android.util.Base64.NO_WRAP))
            .apply()
    }

    private fun vaultRead(): String? {
        val s = getSharedPreferences("smoogi_vault", MODE_PRIVATE).getString("seed", null) ?: return null
        val blob = android.util.Base64.decode(s, android.util.Base64.NO_WRAP)
        val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        c.init(javax.crypto.Cipher.DECRYPT_MODE, vaultKey(),
            javax.crypto.spec.GCMParameterSpec(128, blob.copyOfRange(0, 12)))
        return String(c.doFinal(blob.copyOfRange(12, blob.size)), Charsets.UTF_8)
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
