package com.lib.flutter_pcm_sound;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.AudioAttributes;
import android.os.SystemClock;
import android.util.Log;

import androidx.annotation.NonNull;

import java.util.Map;
import java.util.HashMap;
import java.util.List;
import java.util.ArrayList;
import java.util.concurrent.LinkedBlockingQueue;
import java.io.StringWriter;
import java.io.PrintWriter;
import java.nio.ByteBuffer;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.StandardMethodCodec;

/**
 * FlutterPcmSoundPlugin implements a "one pedal" PCM sound playback mechanism.
 * Playback starts automatically when samples are fed and stops when no more samples are available.
 */
public class FlutterPcmSoundPlugin implements
    FlutterPlugin,
    MethodChannel.MethodCallHandler
{
    private static final String CHANNEL_NAME = "flutter_pcm_sound/methods";
    private static final int MAX_FRAMES_PER_BUFFER = 200;
    // Playback buffer held by AudioTrack itself, in milliseconds. 500ms cleared
    // Instagram, Gmail and WhatsApp's in-app camera on a Pixel 7 Pro; the stock
    // camera app is a heavier spike still, hence the larger margin.
    private static final int BUFFER_TARGET_MS = 1500;

    private MethodChannel mMethodChannel;
    // OnFeedSamples must be dispatched from the main thread: see invokeFeedCallback().
    private final Handler mainThreadHandler = new Handler(Looper.getMainLooper());
    private Thread playbackThread;
    private volatile boolean mShouldCleanup = false;

    private volatile AudioTrack mAudioTrack;
    private int mNumChannels;
    private int mMinBufferSize;
    private int mBufferSize;
    private int mLastUnderrunCount = 0;
    private volatile boolean mDidSetup = false;

    private long mFeedThreshold = 8000;
    private long mTotalFeeds = 0;
    private long mLastLowBufferFeed = 0;
    private long mLastZeroFeed = 0;

    // Thread-safe queue for storing audio samples
    private final LinkedBlockingQueue<ByteBuffer> mSamples = new LinkedBlockingQueue<>();

    // Log level enum (kept for potential future use)
    private enum LogLevel {
        NONE,
        ERROR,
        STANDARD,
        VERBOSE
    }

    private LogLevel mLogLevel = LogLevel.VERBOSE;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        BinaryMessenger messenger = binding.getBinaryMessenger();
        // Serve this channel from a dedicated background thread instead of the
        // Android main thread.
        //
        // Every feed() from Dart is handled by onMethodCall, and the OnFeedSamples
        // callback is dispatched back through the same channel. On the default
        // (platform-thread) channel, both directions are blocked whenever the main
        // thread stalls — which is exactly what happens when a heavy activity
        // starts (camera, Gmail): surface allocation and the activity transition
        // monopolise the main thread for hundreds of ms.
        //
        // The playback thread then drains mSamples, blocks on take(), and AudioTrack
        // underruns — an audible crackle. No buffer size can prevent it, because the
        // buffer cannot be refilled while the main thread is blocked. Nor can the
        // Dart-side silence padding, since it reaches the native player through this
        // very channel.
        //
        // The feed handler only pushes ByteBuffers onto a LinkedBlockingQueue and
        // touches no UI state, so it is safe off the main thread.
        BinaryMessenger.TaskQueue taskQueue = messenger.makeBackgroundTaskQueue();
        mMethodChannel = new MethodChannel(
            messenger, CHANNEL_NAME, StandardMethodCodec.INSTANCE, taskQueue);
        mMethodChannel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        mMethodChannel.setMethodCallHandler(null);
        cleanup();
    }

    @Override
    @SuppressWarnings("deprecation") // Needed for compatibility with Android < 23
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "setLogLevel": {
                    result.success(true);
                    break;
                }
                case "setup": {
                    int sampleRate = call.argument("sample_rate");
                    mNumChannels = call.argument("num_channels");

                    // Cleanup existing resources if any
                    if (mAudioTrack != null) {
                        cleanup();
                    }

                    int channelConfig = (mNumChannels == 2) ?
                        AudioFormat.CHANNEL_OUT_STEREO :
                        AudioFormat.CHANNEL_OUT_MONO;

                    mMinBufferSize = AudioTrack.getMinBufferSize(
                        sampleRate, channelConfig, AudioFormat.ENCODING_PCM_16BIT);

                    if (mMinBufferSize == AudioTrack.ERROR || mMinBufferSize == AudioTrack.ERROR_BAD_VALUE) {
                        result.error("AudioTrackError", "Invalid buffer size.", null);
                        return;
                    }

                    // getMinBufferSize() is ~20-40ms at 48kHz, which leaves the DAC no
                    // margin: any preemption of the playback thread longer than that
                    // underruns, which is exactly what a camera/Instagram/Gmail launch
                    // does to a normal-priority thread. Everything upstream (the Dart
                    // buffer, mSamples, the server's ~10s of lead) is irrelevant once
                    // this one runs dry, which is why resizing those never helped.
                    // pause()+flush() still cuts output immediately, so a larger buffer
                    // costs no stop latency.
                    int frameSize = mNumChannels * 2; // 16-bit samples
                    long target = (long) sampleRate * frameSize * BUFFER_TARGET_MS / 1000L;
                    target -= target % frameSize;
                    mBufferSize = (int) Math.max((long) mMinBufferSize, target);
                    mLastUnderrunCount = 0;

                    if (Build.VERSION.SDK_INT >= 23) { // Android 6 (Marshmallow) and above
                        AudioTrack.Builder builder = new AudioTrack.Builder()
                            .setAudioAttributes(new AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_MEDIA)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                                    .build())
                            .setAudioFormat(new AudioFormat.Builder()
                                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                    .setSampleRate(sampleRate)
                                    .setChannelMask(channelConfig)
                                    .build())
                            .setBufferSizeInBytes(mBufferSize)
                            .setTransferMode(AudioTrack.MODE_STREAM);
                        if (Build.VERSION.SDK_INT >= 26) {
                            // Asking for getMinBufferSize() steered AudioFlinger towards the
                            // fast-mixer path, which is the one that starves first under load.
                            // POWER_SAVING asks for the deep-buffer output instead: the HAL
                            // itself keeps larger buffers and wakes up less often, which is
                            // what music playback wants. Costs output latency, which does not
                            // matter here — Ensemble applies no clock sync, and pause()+flush()
                            // still cuts immediately.
                            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_POWER_SAVING);
                        }
                        mAudioTrack = builder.build();
                    } else {
                        mAudioTrack = new AudioTrack(
                            AudioManager.STREAM_MUSIC,
                            sampleRate,
                            channelConfig,
                            AudioFormat.ENCODING_PCM_16BIT,
                            mBufferSize,
                            AudioTrack.MODE_STREAM);
                    }

                    if (mAudioTrack.getState() != AudioTrack.STATE_INITIALIZED) {
                        result.error("AudioTrackError", "AudioTrack initialization failed.", null);
                        mAudioTrack.release();
                        mAudioTrack = null;
                        return;
                    }

                    // reset
                    mSamples.clear();
                    mShouldCleanup = false;

                    // start playback thread
                    playbackThread = new Thread(this::playbackThreadLoop, "PCMPlaybackThread");
                    playbackThread.setPriority(Thread.MAX_PRIORITY);
                    playbackThread.start();

                    mDidSetup = true;

                    result.success(true);
                    break;
                }
                case "feed": {

                    // check setup (to match iOS behavior)
                    if (mDidSetup == false) {
                        result.error("Setup", "must call setup first", null);
                        return;
                    }

                    byte[] buffer = call.argument("buffer");

                    // Split for better performance
                    List<ByteBuffer> chunks = split(buffer, MAX_FRAMES_PER_BUFFER);

                    // Push samples
                    synchronized (mSamples) {
                        for (ByteBuffer chunk : chunks) {
                            mSamples.add(chunk);
                        }
                        mTotalFeeds += 1;
                    }

                    result.success(true);
                    break;
                }
                case "setFeedThreshold": {
                    long feedThreshold = ((Number) call.argument("feed_threshold")).longValue();

                    synchronized (mSamples) {
                        mFeedThreshold = feedThreshold;
                    }

                    result.success(true);
                    break;
                }
                case "softPause": {
                    softPause();
                    result.success(true);
                    break;
                }
                case "softResume": {
                    softResume();
                    result.success(true);
                    break;
                }
                case "release": {
                    cleanup();
                    result.success(true);
                    break;
                }
                default:
                    result.notImplemented();
                    break;
            }


        } catch (Exception e) {
            StringWriter sw = new StringWriter();
            PrintWriter pw = new PrintWriter(sw);
            e.printStackTrace(pw);
            String stackTrace = sw.toString();
            result.error("androidException", e.toString(), stackTrace);
            return;
        }
    }

    /**
     * Cleans up resources by stopping the playback thread and releasing AudioTrack.
     */
    private void cleanup() {
        // stop playback thread
        if (playbackThread != null) {
            mShouldCleanup = true;
            // Mute immediately — takes effect on the next AudioFlinger mix cycle (~2-5ms)
            // before any stop/flush reaches the DAC, preventing an audible click/pop.
            if (mAudioTrack != null) {
                try { mAudioTrack.setVolume(0.0f); } catch (Exception ignored) {}
            }
            // Discard queued samples so the thread unblocks from take() immediately.
            mSamples.clear();
            // Interrupt thread blocked in take() or write().
            playbackThread.interrupt();
            try {
                // 500 ms timeout guards against a stalled AudioTrack write().
                playbackThread.join(500);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
            playbackThread = null;
            mDidSetup = false;
        }
    }

    /**
     * Silently mutes audio by setting hardware volume to 0.
     * The playback thread and AudioTrack keep running; the Sendspin stream continues.
     * No AudioTrack stop/pause — avoids any click/deadlock.
     * Call softResume() to restore volume.
     */
    private void softPause() {
        if (mAudioTrack == null) return;
        try { mAudioTrack.setVolume(0.0f); } catch (Exception ignored) {}
    }

    /**
     * Restores audio volume after softPause().
     */
    private void softResume() {
        if (mAudioTrack == null) return;
        try { mAudioTrack.setVolume(1.0f); } catch (Exception ignored) {}
    }

    /**
     * Invokes the 'OnFeedSamples' callback with the number of remaining frames.
     *
     * Must run on the main thread. The background TaskQueue installed in
     * onAttachedToEngine only covers the INCOMING direction: MethodChannel uses it
     * solely in setMethodCallHandler. Outgoing calls go invokeMethod (@UiThread) ->
     * DartMessenger.send -> FlutterJNI.dispatchPlatformMessage (@UiThread), whose
     * ensureRunningOnMainThread() throws a RuntimeException off the main thread --
     * which would kill the playback thread, and with it the process.
     */
    private void invokeFeedCallback(long remainingFrames) {
        Map<String, Object> response = new HashMap<>();
        response.put("remaining_frames", remainingFrames);
        mMethodChannel.invokeMethod("OnFeedSamples", response);
    }

    /**
     * The main loop of the playback thread.
     */
    private void playbackThreadLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO);
        // An uncaught throwable in any thread kills the whole process on Android,
        // so the loop never lets one escape: the track is torn down and playback
        // goes silent, but the app survives.
        try {
            mAudioTrack.play();

            while (!mShouldCleanup) {
                ByteBuffer data = null;
                try {
                    data = mSamples.take();
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    continue;
                }

                // write
                mAudioTrack.write(data, data.remaining(), AudioTrack.WRITE_BLOCKING);

                long remainingFrames;
                long totalFeeds;
                long feedThreshold;

                // grab shared data
                synchronized (mSamples) {
                    long totalBytes = 0;
                    for (ByteBuffer sampleBuffer : mSamples) {
                        totalBytes += sampleBuffer.remaining();
                    }
                    remainingFrames = totalBytes / (2 * mNumChannels);
                    totalFeeds = mTotalFeeds;
                    feedThreshold = mFeedThreshold;
                }

                // Hard evidence of DAC starvation, independent of any Dart-side guess.
                if (Build.VERSION.SDK_INT >= 24) {
                    int underruns = mAudioTrack.getUnderrunCount();
                    if (underruns != mLastUnderrunCount) {
                        Log.w("FlutterPcmSound", "AudioTrack underrun count " + mLastUnderrunCount
                            + " -> " + underruns + " (buffer " + mBufferSize + " bytes, "
                            + remainingFrames + " frames queued)");
                        mLastUnderrunCount = underruns;
                    }
                }

                // check for events
                boolean isLowBufferEvent = (remainingFrames <= feedThreshold) && (mLastLowBufferFeed != totalFeeds);
                boolean isZeroCrossingEvent = (remainingFrames == 0) && (mLastZeroFeed != totalFeeds);

                // send events
                if (isLowBufferEvent || isZeroCrossingEvent) {
                    if (isLowBufferEvent) {mLastLowBufferFeed = totalFeeds;}
                    if (isZeroCrossingEvent) {mLastZeroFeed = totalFeeds;}
                    // Hop to the main thread: invokeMethod is @UiThread and throws anywhere
                    // else (see invokeFeedCallback). The TaskQueue added for the camera/Gmail
                    // crackle only applies to the incoming direction, which is what actually
                    // mattered: feed() from Dart no longer queues behind a stalled main
                    // thread. This callback is only a top-up hint — Dart already feeds on
                    // every Sendspin packet (pcm_audio_player.dart:429-432) from the 1.ui
                    // isolate, which a blocked platform thread does not stall.
                    mainThreadHandler.post(() -> invokeFeedCallback(remainingFrames));
                }
            }

        } catch (Throwable t) {
            Log.e("FlutterPcmSound", "playback thread aborted", t);
        } finally {
            AudioTrack track = mAudioTrack;
            mAudioTrack = null;
            if (track != null) {
                try {
                    track.pause();   // immediate hardware cutoff — no remaining samples reach the DAC
                    track.flush();   // purge any samples still in the HAL/kernel buffer
                    track.stop();    // clean stop (nothing left to drain — no click)
                    track.release();
                } catch (Throwable t) {
                    Log.e("FlutterPcmSound", "AudioTrack teardown failed", t);
                }
            }
        }
    }


    private List<ByteBuffer> split(byte[] buffer, int maxSize) {
        List<ByteBuffer> chunks = new ArrayList<>();
        int offset = 0;
        while (offset < buffer.length) {
            int length = Math.min(buffer.length - offset, maxSize);
            ByteBuffer b = ByteBuffer.wrap(buffer, offset, length);
            chunks.add(b);
            offset += length;
        }
        return chunks;
    }
}
