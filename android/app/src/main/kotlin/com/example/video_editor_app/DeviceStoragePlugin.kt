package com.example.video_editor_app

import android.app.ActivityManager
import android.content.Context
import android.os.StatFs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android side of the `app/device_storage` channel (see
 * lib/core/storage/device_storage.dart). Reports free space on the volume
 * holding app-private files, used to refuse imports/exports that would fill
 * the device.
 */
class DeviceStoragePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var filesDir: java.io.File? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        filesDir = binding.applicationContext.filesDir
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app/device_storage").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getFreeBytes" -> try {
                val stat = StatFs(filesDir!!.absolutePath)
                result.success(stat.availableBytes)
            } catch (e: Exception) {
                result.error("UNAVAILABLE", e.message, null)
            }
            // Total RAM, used to avoid settings the phone can't sustain
            // (e.g. 4K recording on low-memory devices).
            "getTotalMemory" -> try {
                val am = context!!.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val info = ActivityManager.MemoryInfo()
                am.getMemoryInfo(info)
                result.success(info.totalMem)
            } catch (e: Exception) {
                result.error("UNAVAILABLE", e.message, null)
            }
            else -> result.notImplemented()
        }
    }
}
