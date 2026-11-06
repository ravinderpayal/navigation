package com.vinfastcopilot.vinfast_copilot

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vinfast_copilot/alert")
            .setMethodCallHandler { call, result ->
                if (call.method == "alert") {
                    val urgent = call.argument<Boolean>("urgent") ?: false
                    DriverAlertPlayer.play(applicationContext, urgent)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}

/** Plays the chime as navigation guidance, so it reaches the car speakers too, and vibrates. */
object DriverAlertPlayer {
    private const val TAG = "DriverAlert"
    private const val ASSET = "assets/sounds/chime.wav"
    private const val REPEAT_GAP_MS = 1000L

    fun play(context: Context, urgent: Boolean) {
        chime(context)
        if (urgent) Handler(Looper.getMainLooper()).postDelayed({ chime(context) }, REPEAT_GAP_MS)
        vibrate(context, if (urgent) longArrayOf(0, 400, 150, 400, 150, 700) else longArrayOf(0, 300, 150, 300))
    }

    private fun chime(context: Context) {
        try {
            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(ASSET)
            val file = context.assets.openFd(key)
            val player = MediaPlayer()
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            player.setDataSource(file.fileDescriptor, file.startOffset, file.length)
            file.close()
            player.setOnCompletionListener { it.release() }
            player.setOnErrorListener { mp, _, _ -> mp.release(); true }
            player.prepare()
            player.start()
            Log.i(TAG, "Chime played")
        } catch (e: Exception) {
            Log.w(TAG, "Chime failed: $e")
        }
    }

    @Suppress("DEPRECATION")
    private fun vibrate(context: Context, pattern: LongArray) {
        val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
        } else {
            vibrator.vibrate(pattern, -1)
        }
    }
}
