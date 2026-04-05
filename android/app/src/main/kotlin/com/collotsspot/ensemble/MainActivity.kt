package com.collotsspot.ensemble

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.database.ContentObserver
import android.hardware.display.DisplayManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.app.UiModeManager
import android.util.Log
import android.view.Display
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Extend AudioServiceActivity instead of FlutterActivity to support audio_service package
// while also intercepting volume button events
class MainActivity: AudioServiceActivity() {
    private val TAG = "EnsembleVolume"
    private val CHANNEL = "com.collotsspot.ensemble/volume_buttons"
    private val AA_CHANNEL = "com.collotsspot.ensemble/android_auto"
    private var methodChannel: MethodChannel? = null
    private var aaChannel: MethodChannel? = null
    private var carModeReceiver: BroadcastReceiver? = null
    private var isListening = false

    // Volume observer for lockscreen volume changes
    // Watches system STREAM_MUSIC volume and mirrors changes to the MA player
    // when a remote/group player is active
    private var audioManager: AudioManager? = null
    private var volumeObserver: VolumeContentObserver? = null
    private var isObservingVolume = false
    private var lastKnownVolume: Int = -1
    // Guard flag to ignore volume changes triggered by our own setStreamVolume calls
    private var ignoringVolumeChange = false

    // Android Auto projection tracking via display listener
    private var isAATracked = false
    private var displayListener: DisplayManager.DisplayListener? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "Configuring Flutter engine, setting up MethodChannel")

        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            Log.d(TAG, "Received method call: ${call.method}")
            when (call.method) {
                "startListening" -> {
                    isListening = true
                    Log.d(TAG, "Volume listening ENABLED")
                    result.success(null)
                }
                "stopListening" -> {
                    isListening = false
                    Log.d(TAG, "Volume listening DISABLED")
                    result.success(null)
                }
                "startVolumeObserver" -> {
                    // Start observing system volume for lockscreen volume changes.
                    // Optional: initialVolume (0-100) sets the system volume to match
                    // the MA player's current volume for a consistent HUD display.
                    val initialVolume = call.argument<Int>("initialVolume")
                    startVolumeObserver(initialVolume)
                    result.success(null)
                }
                "stopVolumeObserver" -> {
                    stopVolumeObserver()
                    result.success(null)
                }
                "syncSystemVolume" -> {
                    // Sync system volume to match MA player volume (0-100)
                    val volume = call.argument<Int>("volume") ?: 0
                    syncSystemVolume(volume)
                    result.success(null)
                }
                else -> {
                    Log.d(TAG, "Unknown method: ${call.method}")
                    result.notImplemented()
                }
            }
        }

        // Android Auto / car mode detection
        aaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AA_CHANNEL)

        // Receive AA connection signal from Dart side
        aaChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "notifyAAConnected" -> {
                    Log.d(TAG, "AA tracked via Dart notifyAAConnected")
                    isAATracked = true
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        carModeReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    UiModeManager.ACTION_ENTER_CAR_MODE -> {
                        Log.d(TAG, "Car mode ENTERED")
                        isAATracked = true
                        aaChannel?.invokeMethod("onAndroidAutoConnected", null)
                    }
                    UiModeManager.ACTION_EXIT_CAR_MODE -> {
                        Log.d(TAG, "Car mode EXITED")
                        aaChannel?.invokeMethod("onAndroidAutoDisconnected", null)
                    }
                }
            }
        }
        val carModeFilter = IntentFilter().apply {
            addAction(UiModeManager.ACTION_ENTER_CAR_MODE)
            addAction(UiModeManager.ACTION_EXIT_CAR_MODE)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(carModeReceiver, carModeFilter, Context.RECEIVER_EXPORTED)
        } else {
            applicationContext.registerReceiver(carModeReceiver, carModeFilter)
        }

        // Detect AA disconnect via display removal (projection mode)
        val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        displayListener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) {}
            override fun onDisplayChanged(displayId: Int) {}
            override fun onDisplayRemoved(displayId: Int) {
                if (!isAATracked) return
                val hasExtraDisplay = dm.displays.any {
                    it.displayId != Display.DEFAULT_DISPLAY
                }
                if (!hasExtraDisplay) {
                    Log.d(TAG, "AA projection ended (all extra displays removed)")
                    isAATracked = false
                    aaChannel?.invokeMethod("onAndroidAutoDisconnected", null)
                }
            }
        }
        dm.registerDisplayListener(displayListener, Handler(Looper.getMainLooper()))
    }

    /// Start observing system STREAM_MUSIC volume changes.
    /// When a change is detected, sends an "absoluteVolumeChange" event to Flutter
    /// with the new volume mapped to 0-100 scale.
    private fun startVolumeObserver(initialVolume: Int?) {
        if (isObservingVolume) return

        val am = audioManager ?: return

        // Optionally set system volume to match the MA player's current volume
        if (initialVolume != null) {
            syncSystemVolume(initialVolume)
        }

        lastKnownVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)

        volumeObserver = VolumeContentObserver(Handler(Looper.getMainLooper()))
        contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI,
            true,
            volumeObserver!!
        )
        isObservingVolume = true
        Log.d(TAG, "Volume observer STARTED, initial system volume: $lastKnownVolume")
    }

    /// Stop observing system volume changes.
    private fun stopVolumeObserver() {
        if (!isObservingVolume) return

        volumeObserver?.let {
            contentResolver.unregisterContentObserver(it)
        }
        volumeObserver = null
        isObservingVolume = false
        Log.d(TAG, "Volume observer STOPPED")
    }

    /// Set the system STREAM_MUSIC volume to match an MA player volume (0-100).
    /// Maps MA's 0-100 range to the device's 0-maxVolume range.
    private fun syncSystemVolume(maVolume: Int) {
        val am = audioManager ?: return
        val maxSystemVolume = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val systemVolume = (maVolume * maxSystemVolume / 100).coerceIn(0, maxSystemVolume)

        ignoringVolumeChange = true
        am.setStreamVolume(AudioManager.STREAM_MUSIC, systemVolume, 0)
        lastKnownVolume = systemVolume
        ignoringVolumeChange = false
        Log.d(TAG, "Synced system volume: MA $maVolume% -> system $systemVolume/$maxSystemVolume")
    }

    /// ContentObserver that watches for system volume changes.
    /// When volume changes (e.g., from lockscreen hardware buttons),
    /// maps the change to a 0-100 value and sends to Flutter.
    inner class VolumeContentObserver(handler: Handler) : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) {
            super.onChange(selfChange)

            if (ignoringVolumeChange) return

            val am = audioManager ?: return
            val currentVolume = am.getStreamVolume(AudioManager.STREAM_MUSIC)

            if (currentVolume != lastKnownVolume) {
                val maxVolume = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val maVolume = if (maxVolume > 0) (currentVolume * 100 / maxVolume) else 0

                Log.d(TAG, "Volume observer: system $lastKnownVolume -> $currentVolume (MA: $maVolume%)")
                lastKnownVolume = currentVolume

                // Send the absolute volume (0-100) to Flutter
                methodChannel?.invokeMethod("absoluteVolumeChange", maVolume)
            }
        }
    }

    // Use dispatchKeyEvent instead of onKeyDown - Flutter's engine uses dispatchKeyEvent
    // and may consume events before they reach onKeyDown
    override fun dispatchKeyEvent(event: KeyEvent?): Boolean {
        if (event == null) {
            return super.dispatchKeyEvent(event)
        }

        val keyCode = event.keyCode
        val action = event.action

        Log.d(TAG, "dispatchKeyEvent: keyCode=$keyCode, action=$action, isListening=$isListening")

        // Only handle KEY_DOWN events to avoid double-triggering (down + up)
        if (action != KeyEvent.ACTION_DOWN) {
            // For volume keys when listening, also consume ACTION_UP to fully block system volume
            if (isListening && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
                Log.d(TAG, "Consuming ACTION_UP for volume key")
                return true
            }
            return super.dispatchKeyEvent(event)
        }

        if (!isListening) {
            Log.d(TAG, "Not listening, passing to super")
            return super.dispatchKeyEvent(event)
        }

        return when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> {
                Log.d(TAG, "VOLUME UP pressed - sending to Flutter")
                methodChannel?.invokeMethod("volumeUp", null)
                true // Consume the event to prevent system volume change
            }
            KeyEvent.KEYCODE_VOLUME_DOWN -> {
                Log.d(TAG, "VOLUME DOWN pressed - sending to Flutter")
                methodChannel?.invokeMethod("volumeDown", null)
                true // Consume the event to prevent system volume change
            }
            else -> {
                Log.d(TAG, "Other key, passing to super")
                super.dispatchKeyEvent(event)
            }
        }
    }

    // Pause volume interception when app goes to background so hardware buttons
    // only control the system volume (e.g., YouTube, phone ringer) as expected.
    private var wasListeningBeforePause = false
    private var wasObservingBeforePause = false

    override fun onPause() {
        wasListeningBeforePause = isListening
        wasObservingBeforePause = isObservingVolume
        isListening = false
        stopVolumeObserver()
        Log.d(TAG, "onPause: suspended volume interception (wasListening=$wasListeningBeforePause, wasObserving=$wasObservingBeforePause)")
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (wasListeningBeforePause) {
            isListening = true
        }
        if (wasObservingBeforePause) {
            startVolumeObserver(null)
        }
        Log.d(TAG, "onResume: restored volume interception (listening=$isListening, observing=$isObservingVolume)")
    }

    override fun onDestroy() {
        stopVolumeObserver()
        carModeReceiver?.let {
            try { applicationContext.unregisterReceiver(it) } catch (_: Exception) {}
        }
        displayListener?.let {
            val dm = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            dm.unregisterDisplayListener(it)
        }
        super.onDestroy()
    }
}
