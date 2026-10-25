package com.zuancrisp.mosix

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/** Shared-engine permission bridge; ongoing transfers never own an Activity. */
class LocalNetworkPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activityBinding: ActivityPluginBinding? = null
    private val pending = mutableListOf<MethodChannel.Result>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.zuancrisp.mosix/local_network")
        channel.setMethodCallHandler(this)
    }

    private fun isGranted(): Boolean =
        Build.VERSION.SDK_INT < 37 || context.applicationInfo.targetSdkVersion < 37 ||
            context.checkSelfPermission(Manifest.permission.ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isGranted" -> result.success(isGranted())
            "request" -> request(result)
            else -> result.notImplemented()
        }
    }

    private fun request(result: MethodChannel.Result) {
        if (isGranted()) {
            result.success(true)
            return
        }
        if (pending.isNotEmpty()) {
            pending.add(result)
            return
        }
        val activity = activityBinding?.activity
        val lifecycle = (activity as? LifecycleOwner)?.lifecycle
        if (activity == null || activity.isFinishing || activity.isDestroyed ||
            lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) != true) {
            // Background scans/uploads must not open a permission dialog.
            result.success(false)
            return
        }
        pending.add(result)
        try {
            activity.requestPermissions(arrayOf(Manifest.permission.ACCESS_LOCAL_NETWORK), REQUEST_CODE)
        } catch (_: Exception) {
            complete(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE) return false
        complete(isGranted())
        return true
    }

    private fun complete(granted: Boolean) {
        val results = pending.toList()
        pending.clear()
        results.forEach { it.success(granted) }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        if (pending.isNotEmpty() && isGranted()) complete(true)
    }

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        detachActivity()
        complete(false)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        detachActivity()
        complete(false)
    }

    private companion object {
        const val REQUEST_CODE = 3701
    }
}
