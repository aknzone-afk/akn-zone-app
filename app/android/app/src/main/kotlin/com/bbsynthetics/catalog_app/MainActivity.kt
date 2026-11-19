package com.bbsynthetics.catalog_app

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.ArrayList

class MainActivity : FlutterActivity() {
    private val channel = "com.bbsynthetics.catalog_app/share"
    private val authority = "com.bbsynthetics.catalog_app.shareprovider"

    /**
     * 19-Nov-2026: tapping a push while the app is CLOSED copies the push's data into the
     * launch intent, and Flutter takes the extra named "route" as the first page. The 9 PM
     * "new designs" push sends route = "daily" (no leading slash); go_router's matcher threw
     * a RangeError on it and the app opened on a dead grey screen (2-7 error reports a day).
     * The Dart side opens the right page from the push itself (PushService -> getInitialMessage),
     * so a launch that comes from a push simply starts at home. Web / aknzone links are not
     * touched: they carry no FCM message id.
     */
    override fun getInitialRoute(): String? {
        val x = intent?.extras
        if (x != null && (x.containsKey("google.message_id") || x.containsKey("message_id"))) return "/"
        return super.getInitialRoute()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "shareToPackage" -> {
                        try {
                            val paths = call.argument<List<String>>("paths") ?: emptyList()
                            val targetPackage = call.argument<String>("package")
                                ?: return@setMethodCallHandler result.error("ARG", "Missing package", null)
                            val message = call.argument<String>("message")

                            if (paths.isEmpty()) {
                                return@setMethodCallHandler result.error("ARG", "No files", null)
                            }

                            // Convert each absolute file path to a content:// Uri via FileProvider.
                            val uris = ArrayList<Uri>()
                            for (p in paths) {
                                val f = File(p)
                                if (!f.exists()) continue
                                uris.add(FileProvider.getUriForFile(this, authority, f))
                            }
                            if (uris.isEmpty()) {
                                return@setMethodCallHandler result.error("FILES", "No readable files", null)
                            }

                            val intent = if (uris.size == 1) {
                                Intent(Intent.ACTION_SEND).apply {
                                    type = "image/*"
                                    putExtra(Intent.EXTRA_STREAM, uris[0])
                                }
                            } else {
                                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                                    type = "image/*"
                                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                                }
                            }
                            if (!message.isNullOrEmpty()) {
                                intent.putExtra(Intent.EXTRA_TEXT, message)
                            }
                            intent.setPackage(targetPackage)
                            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SHARE_FAIL", e.message, null)
                        }
                    }
                    "isPackageInstalled" -> {
                        try {
                            val pkg = call.argument<String>("package")
                                ?: return@setMethodCallHandler result.error("ARG", "Missing package", null)
                            val installed = try {
                                packageManager.getPackageInfo(pkg, 0)
                                true
                            } catch (_: PackageManager.NameNotFoundException) {
                                false
                            }
                            result.success(installed)
                        } catch (e: Exception) {
                            result.error("PKG_FAIL", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
