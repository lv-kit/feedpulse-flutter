package dev.feedpulse.flutter

import android.content.Context
import android.os.Build
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

/**
 * Feedpulse のネイティブ側。アプリ証明（Play Integrity）、端末情報、config の保存を Dart に提供する。
 * 実機の Play Integrity 動作は CI では検証していない。
 */
class FeedpulsePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.feedpulse/native")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "environment" -> result.success(
                mapOf(
                    "platform" to "android",
                    "appId" to context.packageName,
                    "os" to "Android ${Build.VERSION.RELEASE}",
                    "timezone" to TimeZone.getDefault().id,
                ),
            )
            "attest" -> {
                val challenge = call.argument<String>("challenge")
                if (challenge == null) {
                    result.error("bad_args", "challenge が無い", null)
                    return
                }
                // classic request。サーバーは復号した判定の nonce == challenge を照合する。
                try {
                    IntegrityManagerFactory.create(context)
                        .requestIntegrityToken(IntegrityTokenRequest.builder().setNonce(challenge).build())
                        .addOnSuccessListener {
                            result.success(mapOf("type" to "play_integrity", "token" to it.token()))
                        }
                        .addOnFailureListener {
                            result.error("play_integrity_failed", it.message, null)
                        }
                } catch (e: Exception) {
                    result.error("play_integrity_failed", e.message, null)
                }
            }
            "resetAttestation" -> result.success(null)
            "storeRead" -> result.success(prefs().getString(call.argument<String>("key"), null))
            "storeWrite" -> {
                prefs().edit().putString(call.argument<String>("key"), call.argument<String>("value")).apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun prefs() = context.getSharedPreferences("dev.feedpulse", Context.MODE_PRIVATE)
}
