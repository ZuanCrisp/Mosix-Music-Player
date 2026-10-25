package com.zarz.spotiflac.discord

import android.app.Activity
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DiscordPresencePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private val handler = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var running = false
    private var loaded = false
    private var lastStatus = -1
    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            val status = nativeTick()
            if (status != lastStatus) {
                lastStatus = status
                channel.invokeMethod("status", when (status) {
                    1 -> "active"
                    2 -> "unavailable"
                    else -> "ready"
                })
            }
            handler.postDelayed(this, 100)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.zarz.spotiflac/discord")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "initialize" -> {
                    val host = activity
                    if (host == null) { result.success(false); return }
                    // Only load/start the SDK after the user enables presence.
                    val init = Class.forName("com.discord.socialsdk.DiscordSocialSdkInit")
                    init.getMethod("setEngineActivity", Activity::class.java).invoke(null, host)
                    if (!loaded) { System.loadLibrary("spotiflac_discord"); loaded = true }
                    if (!running) {
                        running = nativeStart()
                        lastStatus = -1
                        if (running) handler.post(tick)
                    }
                    result.success(running)
                }
                "update" -> {
                    if (running) nativeUpdate(
                        call.argument<String>("title") ?: "",
                        call.argument<String>("state") ?: "",
                        call.argument<String>("album") ?: "",
                        call.argument<String>("artwork") ?: "",
                        call.argument<Number>("start")?.toLong() ?: 0L,
                        call.argument<Number>("end")?.toLong() ?: 0L,
                    )
                    result.success(null)
                }
                "clear" -> { if (running) nativeClear(); result.success(null) }
                "shutdown" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        } catch (_: ClassNotFoundException) {
            result.success(false)
        } catch (_: LinkageError) {
            result.error("sdk_unavailable", "Discord SDK is unavailable in this build.", null)
        } catch (_: Exception) {
            result.error("discord_unavailable", "Unable to connect to Discord.", null)
        }
    }

    private fun stop() {
        handler.removeCallbacks(tick)
        if (running) nativeStop()
        running = false
        lastStatus = -1
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stop()
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }

    private external fun nativeStart(): Boolean
    private external fun nativeTick(): Int
    private external fun nativeUpdate(title: String, artist: String, album: String, artwork: String, start: Long, end: Long)
    private external fun nativeClear()
    private external fun nativeStop()
}
