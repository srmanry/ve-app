package com.example.video_editor_app

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.FileOutputStream
import java.nio.ByteOrder
import java.util.concurrent.Executors

/**
 * Android side of the `app/person_segmentation` channel (see
 * lib/services/ai/person_segmenter.dart). Uses ML Kit Selfie Segmentation
 * with the model bundled in the APK: runs fully on device, no download.
 *
 * Reads each frame file, segments it and appends an 8-bit mask
 * (255 = person), resampled to the requested size, to the output file — so
 * image data never crosses the platform channel.
 */
class PersonSegmentationPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // Stream mode smooths masks across consecutive video frames.
    private val segmenter: Segmenter by lazy {
        Segmentation.getClient(
            SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
                .build()
        )
    }

    // Photos: each image on its own, no smoothing from earlier frames.
    private val photoSegmenter: Segmenter by lazy {
        Segmentation.getClient(
            SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
                .build()
        )
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "app/person_segmentation").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "segmentFrames") {
            result.notImplemented()
            return
        }
        val paths = call.argument<List<String>>("framePaths") ?: emptyList()
        val width = call.argument<Int>("maskWidth") ?: 0
        val height = call.argument<Int>("maskHeight") ?: 0
        val output = call.argument<String>("outputPath")
        val append = call.argument<Boolean>("append") ?: false
        val singleImage = call.argument<Boolean>("singleImage") ?: false
        if (output == null || width <= 0 || height <= 0) {
            result.error("BAD_ARGS", "Missing arguments", null)
            return
        }
        executor.execute {
            try {
                BufferedOutputStream(FileOutputStream(output, append)).use { out ->
                    val mask = ByteArray(width * height)
                    for (path in paths) {
                        val bitmap = decode(path, if (singleImage) 1536 else 0)
                            ?: throw IllegalStateException("Unreadable frame: $path")
                        val client = if (singleImage) photoSegmenter else segmenter
                        val segmentation = Tasks.await(client.process(InputImage.fromBitmap(bitmap, 0)))
                        val buffer = segmentation.buffer.order(ByteOrder.nativeOrder())
                        val mw = segmentation.width
                        val mh = segmentation.height
                        if (singleImage) {
                            // Bilinear: smooth edges for hair and shoulders.
                            for (y in 0 until height) {
                                val fy = ((y + 0.5f) * mh / height - 0.5f).coerceIn(0f, (mh - 1).toFloat())
                                val y0 = fy.toInt()
                                val y1 = minOf(y0 + 1, mh - 1)
                                val ty = fy - y0
                                for (x in 0 until width) {
                                    val fx = ((x + 0.5f) * mw / width - 0.5f).coerceIn(0f, (mw - 1).toFloat())
                                    val x0 = fx.toInt()
                                    val x1 = minOf(x0 + 1, mw - 1)
                                    val tx = fx - x0
                                    val a = buffer.getFloat((y0 * mw + x0) * 4)
                                    val b = buffer.getFloat((y0 * mw + x1) * 4)
                                    val c = buffer.getFloat((y1 * mw + x0) * 4)
                                    val d = buffer.getFloat((y1 * mw + x1) * 4)
                                    val v = (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
                                    mask[y * width + x] = (v * 255f).toInt().coerceIn(0, 255).toByte()
                                }
                            }
                        } else {
                            // Nearest-neighbour resample of confidences (0..1) to bytes.
                            for (y in 0 until height) {
                                val sy = y * mh / height
                                for (x in 0 until width) {
                                    val sx = x * mw / width
                                    val c = buffer.getFloat((sy * mw + sx) * 4)
                                    mask[y * width + x] = (c * 255f).toInt().coerceIn(0, 255).toByte()
                                }
                            }
                        }
                        out.write(mask)
                        bitmap.recycle()
                    }
                }
                main.post { result.success(paths.size) }
            } catch (e: Exception) {
                main.post { result.error("SEGMENTATION_FAILED", e.message, null) }
            }
        }
    }

    /** Decodes [path], downsampled so its long side is at most [maxSide] (0 = full size). */
    private fun decode(path: String, maxSide: Int): android.graphics.Bitmap? {
        if (maxSide <= 0) return BitmapFactory.decodeFile(path)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
        return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
