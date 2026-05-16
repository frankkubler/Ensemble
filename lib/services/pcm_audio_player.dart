import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show unawaited;
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart' as pcm;
import 'debug_logger.dart';

/// Callback type for elapsed time updates
typedef ElapsedTimeCallback = void Function(Duration elapsed);

/// Audio format configuration matching Sendspin protocol
class PcmAudioFormat {
  final int sampleRate;
  final int channels;
  final int bitDepth;

  const PcmAudioFormat({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bitDepth = 16,
  });

  /// Default Sendspin format: 48kHz, stereo, 16-bit PCM
  static const sendspin = PcmAudioFormat();
}

/// Player state for PCM audio
enum PcmPlayerState {
  idle,
  initializing,
  ready,
  playing,
  pausing,   // Transitional state: pause requested, waiting for completion
  paused,
  resuming,  // Transitional state: resume requested, re-initializing
  stopping,  // Transitional state: stop requested, cleaning up
  error,
}

/// Error types for PCM player operations
enum PcmPlayerError {
  initializationFailed,
  feedFailed,
  pauseFailed,
  resumeFailed,
  streamError,
  releaseTimeout,
}

/// Callback type for error events
typedef PcmErrorCallback = void Function(PcmPlayerError error, String message);

/// Service to play raw PCM audio data from Sendspin WebSocket stream
/// Uses flutter_pcm_sound plugin for low-level PCM playback
///
/// State Machine:
/// - idle → initializing → ready → playing ↔ paused
/// - Any state can transition to error
/// - Transitional states (pausing, resuming, stopping) block operations
class PcmAudioPlayer {
  final _logger = DebugLogger();

  PcmPlayerState _state = PcmPlayerState.idle;
  PcmAudioFormat _format = PcmAudioFormat.sendspin;

  StreamSubscription<Uint8List>? _audioSubscription;

  // Audio buffer for smooth playback
  final List<Uint8List> _audioBuffer = [];
  bool _isFeeding = false;
  bool _isStarted = false;
  bool _isAutoRecovering = false;  // Tracks auto-recovery from setup errors
  bool _userPaused = false;  // True when pause is user-initiated (not transitional)
  Completer<void>? _feedCompleter;  // Tracks when current feed operation completes

  // Error callback for operation failures
  PcmErrorCallback? onError;

  // Chunks to concatenate into a single FlutterPcmSound.feed() call.
  // The Java plugin internally splits each feed() into 200-frame ByteBuffers,
  // so the actual write(WRITE_BLOCKING) per ByteBuffer is only ~4 ms regardless
  // of how much Dart sends in one feed() call.
  // Sending 120 chunks at once (3 s) minimises Dart platform-channel round-trips.
  // Audio stop is instant because the forked cleanup() calls AudioTrack.pause()
  // + mSamples.clear() before join(), so no crackle regardless of feed size.
  static const int _maxChunksPerFeed = 120;

  // Feed threshold — native requests more data when remaining frames drop below this.
  // The native callback wakes up the Dart isolate even when it is throttled in
  // background, so a HIGH threshold gives more time for Dart to respond before
  // the buffer empties. pause() uses release() so the native buffer size has NO
  // effect on pause latency — we can safely make this as large as we like.
  // 480000 frames @ 48kHz stereo = 10 seconds of headroom.
  // The larger value is critical under heavy CPU load (e.g. camera app): the Dart
  // event loop can stall for several seconds while the GPU/camera pipeline runs,
  // and 10s of native buffer survives those stalls without underrunning.
  static const int _feedThreshold = 480000;

  // Require a preroll buffer before starting playback to ensure the native player
  // has enough data on the first feed cycle.
  // 6 chunks × 25ms = 150ms of audio before start().
  static const int _minChunksBeforeStart = 6;

  // Maximum buffer size to prevent memory overflow (~20 seconds of audio)
  // At 48kHz stereo 16-bit: 192KB/sec, so ~3.8MB for 20 seconds
  // Each chunk is ~4KB, so max ~1000 chunks (was 500 = ~10s)
  static const int _maxBufferChunks = 1000;

  // Silence padding: max silence chunks to inject on network stall.
  // Bridges up to 800ms of stall before native player underruns and crackles.
  // Each chunk = 25ms @ 48kHz stereo 16-bit (see _onFeedRequested).
  static const int _silencePaddingMaxChunks = 32; // 32 × 25ms = 800ms
  int _silencePaddingFed = 0;

  // Minimum native buffer level (in frames) below which silence injection is
  // allowed. With _feedThreshold = 192000 (4s), _onFeedRequested fires early
  // while the native AudioTrack still has seconds of audio. Injecting silence
  // at that point creates an audible click in the middle of the stream.
  // Only inject once the native buffer is truly low (< 1s = 48000 frames).
  static const int _silenceInjectionThreshold = 48000; // 1s @ 48kHz

  // Software volume gain (0.0 = silent, 1.0 = full volume)
  double _volumeGain = 1.0;

  // Stats
  int _framesPlayed = 0;
  int _bytesPlayed = 0;

  // Elapsed time tracking for notification sync
  Timer? _elapsedTimeTimer;
  final _elapsedTimeController = StreamController<Duration>.broadcast();
  ElapsedTimeCallback? onElapsedTimeUpdate;

  // Track offset for pause/resume (preserves position across pause cycles)
  int _bytesPlayedAtLastPause = 0;
  DateTime? _playbackStartTime;

  PcmPlayerState get state => _state;
  bool get isPlaying => _state == PcmPlayerState.playing;
  bool get isPaused => _state == PcmPlayerState.paused;
  bool get isReady => _state == PcmPlayerState.ready || _state == PcmPlayerState.playing || _state == PcmPlayerState.paused;
  int get framesPlayed => _framesPlayed;
  int get bytesPlayed => _bytesPlayed;

  /// Check if player is in a transitional state (operation in progress)
  bool get isTransitioning => _state == PcmPlayerState.pausing ||
                               _state == PcmPlayerState.resuming ||
                               _state == PcmPlayerState.stopping;

  /// Set software volume gain (0.0 = silent, 1.0 = full). Applied to PCM samples at feed time.
  void setVolumeGain(double gain) {
    _volumeGain = gain.clamp(0.0, 1.0);
  }

  /// Check if feeding should be blocked
  bool get _shouldBlockFeeding => isTransitioning || _state == PcmPlayerState.paused;

  /// Stream of elapsed time updates (emits every 500ms when playing)
  Stream<Duration> get elapsedTimeStream => _elapsedTimeController.stream;

  /// Calculate elapsed playback time from bytes played
  /// For 48kHz stereo 16-bit: 4 bytes per frame, 48000 frames per second
  Duration get elapsedTime {
    // Bytes per frame = channels * (bitDepth / 8) = 2 * 2 = 4
    final bytesPerFrame = _format.channels * (_format.bitDepth ~/ 8);
    final framesFromBytes = _bytesPlayed / bytesPerFrame;
    final elapsedSeconds = framesFromBytes / _format.sampleRate;
    return Duration(milliseconds: (elapsedSeconds * 1000).round());
  }

  /// Get elapsed time in seconds (for convenience)
  double get elapsedTimeSeconds {
    final bytesPerFrame = _format.channels * (_format.bitDepth ~/ 8);
    final framesFromBytes = _bytesPlayed / bytesPerFrame;
    return framesFromBytes / _format.sampleRate;
  }

  /// Initialize the PCM player with the given format
  Future<bool> initialize({PcmAudioFormat? format}) async {
    if (_state == PcmPlayerState.initializing) return false;

    _format = format ?? PcmAudioFormat.sendspin;
    _state = PcmPlayerState.initializing;

    try {
      _logger.log('PcmAudioPlayer: Initializing (${_format.sampleRate}Hz, ${_format.channels}ch, ${_format.bitDepth}bit)');

      // Setup flutter_pcm_sound with Sendspin audio format
      await pcm.FlutterPcmSound.setup(
        sampleRate: _format.sampleRate,
        channelCount: _format.channels,
      );

      // Set feed threshold - request more data when buffer has fewer frames
      // Lower threshold = lower latency but more risk of underruns
      // Using _feedThreshold (5000 frames = ~104ms) for faster pause response
      await pcm.FlutterPcmSound.setFeedThreshold(_feedThreshold);

      // Set up feed callback for when buffer needs more data
      pcm.FlutterPcmSound.setFeedCallback(_onFeedRequested);

      // Set log level for debugging
      await pcm.FlutterPcmSound.setLogLevel(pcm.LogLevel.standard);

      _state = PcmPlayerState.ready;
      _logger.log('PcmAudioPlayer: Initialized successfully');
      return true;
    } catch (e) {
      _logger.log('PcmAudioPlayer: Initialization failed: $e');
      _state = PcmPlayerState.error;
      return false;
    }
  }

  /// Callback when flutter_pcm_sound needs more audio data
  void _onFeedRequested(int remainingFrames) {
    // This is called from native when buffer is getting low
    // Block feeding during pause, transitional states, or when not playing
    if (_state != PcmPlayerState.playing) {
      _logger.log('PcmAudioPlayer: feed callback blocked (state=$_state, remainingFrames=$remainingFrames)');
      return;
    }
    if (_shouldBlockFeeding) {
      _logger.log('PcmAudioPlayer: feed callback blocked (shouldBlockFeeding, remainingFrames=$remainingFrames)');
      return;
    }
    if (_isFeeding) return;
    // Native player not yet started (preroll in progress) — don't inject silence
    if (!_isStarted) return;

    // Warn when native buffer drops into dangerous territory.
    // At 48kHz stereo this is: 96000=2s, 48000=1s, 24000=0.5s.
    if (remainingFrames < 96000) {
      _logger.log('⚠️ PcmAudioPlayer: Low native buffer: ${remainingFrames} frames '
          '(${(remainingFrames / 48000).toStringAsFixed(2)}s), '
          'dartBuffer=${_audioBuffer.length} chunks, '
          'state=$_state, isStarted=$_isStarted');
    }

    // Silence padding: when buffer is empty during playback, feed silence DIRECTLY
    // to the native player — intentionally bypasses _audioBuffer so that real audio
    // arriving later is NOT delayed by silence chunks in the queue.
    // Guard: only inject when the native buffer is truly running low. If
    // remainingFrames is high (e.g. 10s with threshold=480000), the Dart buffer is
    // just momentarily empty between network bursts — injecting silence here would
    // create an audible click in an otherwise continuous audio stream.
    if (_audioBuffer.isEmpty && !_userPaused && _silencePaddingFed < _silencePaddingMaxChunks) {
      if (remainingFrames > _silenceInjectionThreshold) {
        _logger.log('PcmAudioPlayer: Dart buffer empty but native has ${remainingFrames} frames '
            '(${(remainingFrames / 48000).toStringAsFixed(2)}s) — skipping silence (between bursts)');
        return;
      }
      _silencePaddingFed++;
      if (_silencePaddingFed == 1) {
        _logger.log('PcmAudioPlayer: Network stall ($remainingFrames frames left) — injecting silence to prevent crackle');
      }
      _feedSilenceChunk();
      return;
    }

    if (_audioBuffer.isEmpty) {
      // Silence padding exhausted and buffer still empty: let the native AudioTrack
      // drain to silence would cause an audible underrun glitch.
      // Instead, stop the native player cleanly — auto-recovery will restart it
      // transparently when the next audio frame arrives.
      if (_isStarted && !_isAutoRecovering) {
        _logger.log('PcmAudioPlayer: Silence padding exhausted — stopping native player cleanly to prevent underrun glitch');
        _isStarted = false;
        _state = PcmPlayerState.paused;  // _userPaused stays false → auto-recovery on next frame
        pcm.FlutterPcmSound.setFeedCallback(null);
        unawaited(pcm.FlutterPcmSound.release().catchError((e) {
          _logger.log('PcmAudioPlayer: Error releasing after silence exhaustion: $e');
        }));
      }
      return;
    }
    _feedNextChunk();
  }

  /// Feed a single 25ms silence chunk directly to flutter_pcm_sound.
  /// Does NOT touch _audioBuffer, so real audio is never delayed.
  Future<void> _feedSilenceChunk() async {
    if (_isFeeding) return;
    _isFeeding = true;
    _feedCompleter = Completer<void>();
    try {
      // 25ms of silence: sampleRate × channels × 0.025s samples (Int16)
      final samplesPerChunk = _format.sampleRate * _format.channels * 25 ~/ 1000;
      final silence = List<int>.filled(samplesPerChunk, 0);
      await pcm.FlutterPcmSound.feed(pcm.PcmArrayInt16.fromList(silence));
    } catch (e) {
      _logger.log('PcmAudioPlayer: Silence feed error: $e');
    } finally {
      _isFeeding = false;
      _feedCompleter?.complete();
    }
  }

  /// Connect to a Sendspin audio data stream and start playback
  Future<bool> connectToStream(Stream<Uint8List> audioStream) async {
    if (_state == PcmPlayerState.error || _state == PcmPlayerState.idle) {
      _logger.log('PcmAudioPlayer: Cannot connect - player not initialized');
      return false;
    }

    // Cancel any existing subscription
    await _audioSubscription?.cancel();

    _logger.log('PcmAudioPlayer: Connecting to audio stream');

    // Subscribe to the audio stream
    _audioSubscription = audioStream.listen(
      _onAudioData,
      onError: _onStreamError,
      onDone: _onStreamDone,
    );

    return true;
  }

  /// Safely add audio data to buffer with overflow protection
  void _addToBuffer(Uint8List audioData) {
    // If buffer is full, drop oldest chunks to make room
    while (_audioBuffer.length >= _maxBufferChunks) {
      _audioBuffer.removeAt(0);
      _logger.log('⚠️ PcmAudioPlayer: Buffer overflow - dropping oldest chunk');
    }
    _audioBuffer.add(audioData);
  }

  /// Handle incoming audio data from the stream
  void _onAudioData(Uint8List audioData) {
    // Ignore data if in error state
    if (_state == PcmPlayerState.error) return;

    // Real audio arriving — cancel any active silence padding immediately
    if (_silencePaddingFed > 0) {
      _logger.log('PcmAudioPlayer: Audio resumed after ${_silencePaddingFed} silence chunk(s) — silence→audio transition');
    }
    _silencePaddingFed = 0;

    // Handle audio arriving during paused/transitional states
    // This can happen when audio frames arrive before stream/start message (race condition)
    // We need to auto-recover in this case
    if (_shouldBlockFeeding) {
      // If we're paused and audio is arriving, this is likely a new stream
      // starting before the stream/start message. Queue for auto-recovery.
      // BUT: don't auto-recover if the user explicitly paused — the arriving
      // audio is just the tail end of the previous stream.
      if (_state == PcmPlayerState.paused && !_isAutoRecovering && !_userPaused) {
        _logger.log('PcmAudioPlayer: Audio arriving while paused - initiating auto-recovery');
        _isAutoRecovering = true;
        _addToBuffer(audioData);

        // Trigger async recovery
        _autoRecoverFromPause();
        return;
      }

      // If already recovering or in transitional state, buffer the data
      if (_isAutoRecovering) {
        _addToBuffer(audioData);
        return;
      }

      // For other blocking states (pausing, stopping, resuming), ignore
      return;
    }

    // Add to buffer with overflow protection
    _addToBuffer(audioData);

    // Start only after a small preroll so the native buffer is not nearly
    // empty on the very first feed cycle.  Applies to both initial start
    // (state == ready) and resume-after-pause (state == playing, _isStarted
    // kept false so the preroll can build up before the native player begins).
    if (!_isStarted &&
        (_state == PcmPlayerState.ready || _state == PcmPlayerState.playing) &&
        _audioBuffer.length >= _minChunksBeforeStart) {
      _startPlayback();
    }

    // Feed data if not currently feeding
    if (!_isFeeding && _isStarted) {
      _feedNextChunk();
    }
  }

  /// Auto-recover from paused state when audio arrives unexpectedly
  Future<void> _autoRecoverFromPause() async {
    _logger.log('PcmAudioPlayer: Auto-recovering from pause (buffer: ${_audioBuffer.length} chunks, userPaused: $_userPaused)');

    try {
      // Ensure any previous native instance is fully released before re-setup
      // (guards against overlap when triggered after silence-exhaustion clean stop).
      await pcm.FlutterPcmSound.release().catchError((_) {});
      // Re-initialize the native player
      await pcm.FlutterPcmSound.setup(
        sampleRate: _format.sampleRate,
        channelCount: _format.channels,
      );
      await pcm.FlutterPcmSound.setFeedThreshold(_feedThreshold);
      pcm.FlutterPcmSound.setFeedCallback(_onFeedRequested);
      await pcm.FlutterPcmSound.start();

      _isStarted = true;
      _state = PcmPlayerState.playing;
      _startElapsedTimeTimer();
      _logger.log('PcmAudioPlayer: Auto-recovery from pause successful');

      // Start feeding buffered data
      _isAutoRecovering = false;
      if (_audioBuffer.isNotEmpty && !_isFeeding) {
        _feedNextChunk();
      }
    } catch (e) {
      _logger.log('PcmAudioPlayer: Auto-recovery from pause failed: $e');
      _isAutoRecovering = false;
      _state = PcmPlayerState.error;
      _emitError(PcmPlayerError.resumeFailed, e.toString());
    }
  }

  /// Start audio playback
  Future<void> _startPlayback() async {
    if (_isStarted) return;

    // CRITICAL: set _isStarted = true BEFORE await start().
    // _onAudioData calls _startPlayback() without await, so control returns
    // to the caller before start() resolves. When the native player fires
    // _onFeedRequested immediately after start(), _isStarted must already be
    // true or the guard in _onFeedRequested blocks the first feed → underrun
    // → audible crackle. Reset to false only on error.
    _isStarted = true;

    try {
      await pcm.FlutterPcmSound.start();
      _state = PcmPlayerState.playing;
      _playbackStartTime = DateTime.now();
      _startElapsedTimeTimer();
      _logger.log('PcmAudioPlayer: Started playback');
      // Pre-fill the native buffer with already-buffered chunks.
      if (!_isFeeding && _audioBuffer.isNotEmpty) {
        unawaited(_feedNextChunk());
      }
    } catch (e) {
      _logger.log('PcmAudioPlayer: Error starting playback: $e');
      _isStarted = false;
      _state = PcmPlayerState.error;
    }
  }

  /// Start the elapsed time update timer
  void _startElapsedTimeTimer() {
    _elapsedTimeTimer?.cancel();
    _elapsedTimeTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _emitElapsedTime(),
    );
    // Emit immediately
    _emitElapsedTime();
  }

  /// Stop the elapsed time update timer
  void _stopElapsedTimeTimer() {
    _elapsedTimeTimer?.cancel();
    _elapsedTimeTimer = null;
  }

  /// Emit the current elapsed time to listeners
  void _emitElapsedTime() {
    if (_state != PcmPlayerState.playing) return;

    final elapsed = elapsedTime;
    if (!_elapsedTimeController.isClosed) {
      _elapsedTimeController.add(elapsed);
    }
    onElapsedTimeUpdate?.call(elapsed);
  }

  /// Feed available audio data to the native player in one batched call.
  /// Up to [_maxChunksPerFeed] chunks (3 s) are concatenated into a single
  /// FlutterPcmSound.feed() call to minimise platform-channel round-trips.
  /// The Java plugin splits the buffer into ~4 ms ByteBuffers internally,
  /// so the actual AudioTrack.write() granularity is always small.
  Future<void> _feedNextChunk() async {
    if (_isFeeding || _audioBuffer.isEmpty || _shouldBlockFeeding) return;

    _isFeeding = true;
    _feedCompleter = Completer<void>();

    try {
      while (_audioBuffer.isNotEmpty &&
             _state == PcmPlayerState.playing &&
             !_shouldBlockFeeding) {
        // Collect up to _maxChunksPerFeed chunks into one contiguous sample list.
        final allSamples = <int>[];
        int bytesConsumed = 0;
        int chunksConsumed = 0;

        while (_audioBuffer.isNotEmpty &&
               chunksConsumed < _maxChunksPerFeed &&
               !_shouldBlockFeeding) {
          final chunk = _audioBuffer.removeAt(0);
          final rawSamples = _bytesToInt16List(chunk);
          if (_volumeGain == 1.0) {
            allSamples.addAll(rawSamples);
          } else {
            allSamples.addAll(
                rawSamples.map((s) => (s * _volumeGain).round().clamp(-32768, 32767)));
          }
          bytesConsumed += chunk.length;
          chunksConsumed++;
        }

        if (allSamples.isEmpty || _shouldBlockFeeding) break;

        try {
          await pcm.FlutterPcmSound.feed(pcm.PcmArrayInt16.fromList(allSamples));
        } catch (feedError) {
          // Auto-recover from "must call setup first" error
          // This happens when audio frames arrive before stream/start message
          if (feedError.toString().contains('must call setup first') && !_isAutoRecovering) {
            _logger.log('PcmAudioPlayer: Auto-recovering from setup error');
            _isAutoRecovering = true;
            try {
              await pcm.FlutterPcmSound.setup(
                sampleRate: _format.sampleRate,
                channelCount: _format.channels,
              );
              await pcm.FlutterPcmSound.setFeedThreshold(_feedThreshold);
              pcm.FlutterPcmSound.setFeedCallback(_onFeedRequested);
              await pcm.FlutterPcmSound.start();
              _isStarted = true;
              _state = PcmPlayerState.playing;
              _startElapsedTimeTimer();
              _logger.log('PcmAudioPlayer: Auto-recovery successful');
              await pcm.FlutterPcmSound.feed(pcm.PcmArrayInt16.fromList(allSamples));
            } catch (recoveryError) {
              _logger.log('PcmAudioPlayer: Auto-recovery failed: $recoveryError');
              _isAutoRecovering = false;
              rethrow;
            }
            _isAutoRecovering = false;
          } else {
            rethrow;
          }
        }

        if (!_shouldBlockFeeding) {
          _framesPlayed += chunksConsumed;
          _bytesPlayed += bytesConsumed;
          if (_framesPlayed % 100 < chunksConsumed) {
            _logger.log('PcmAudioPlayer: Played $_framesPlayed frames (${(_bytesPlayed / 1024).toStringAsFixed(1)} KB)');
          }
        }

        // Yield to event loop after each batch to keep UI responsive.
        await Future.delayed(Duration.zero);
      }
    } catch (e) {
      if (!_shouldBlockFeeding) {
        _logger.log('PcmAudioPlayer: Error feeding audio: $e');
        _emitError(PcmPlayerError.feedFailed, e.toString());
      }
    }

    _isFeeding = false;
    _feedCompleter?.complete();
    _feedCompleter = null;
  }

  /// Emit an error to the callback
  void _emitError(PcmPlayerError error, String message) {
    _logger.log('PcmAudioPlayer: Error - $error: $message');
    onError?.call(error, message);
  }

  /// Convert raw bytes (Uint8List) to Int16 samples
  /// Assumes little-endian 16-bit PCM
  List<int> _bytesToInt16List(Uint8List bytes) {
    if (bytes.length < 2) return [];

    final byteData = ByteData.sublistView(bytes);
    final samples = <int>[];

    for (int i = 0; i < bytes.length - 1; i += 2) {
      samples.add(byteData.getInt16(i, Endian.little));
    }

    return samples;
  }

  /// Stop feeding data to the native player immediately.
  ///
  /// Removes the feed callback and drains the Dart buffer so no new data
  /// is queued. Does NOT call release() — the forked flutter_pcm_sound
  /// plugin already handles instant audio cutoff in its cleanup() method
  /// by calling AudioTrack.pause() + mSamples.clear() before join().
  /// The caller must follow up with pause() to complete the state transition.
  void silenceNow() {
    if (_state != PcmPlayerState.playing) return;
    pcm.FlutterPcmSound.setFeedCallback(null);
    _audioBuffer.clear();
    _silencePaddingFed = _silencePaddingMaxChunks;
    _isFeeding = false;
    _logger.log('PcmAudioPlayer: silenceNow — feed stopped, Dart buffer cleared');
  }

  /// Handle stream errors - notify listeners and pause playback
  void _onStreamError(dynamic error) {
    _logger.log('PcmAudioPlayer: Stream error: $error');
    _emitError(PcmPlayerError.streamError, error.toString());

    // Pause on stream error to prevent playback of corrupted/incomplete audio
    if (_state == PcmPlayerState.playing) {
      _logger.log('PcmAudioPlayer: Pausing due to stream error');
      pause();
    }
  }

  /// Handle stream completion
  void _onStreamDone() {
    _logger.log('PcmAudioPlayer: Audio stream ended');
    // Don't stop immediately - let buffered audio finish
  }

  /// Start playback (if paused or ready)
  /// Returns true if playback started successfully
  Future<bool> play() async {
    if (_state == PcmPlayerState.error) return false;
    if (isTransitioning) {
      _logger.log('PcmAudioPlayer: Cannot play - operation in progress (state: $_state)');
      return false;
    }

    if (_state == PcmPlayerState.paused) {
      // Resume from pause - need to re-initialize since we released on pause
      _userPaused = false;
      _logger.log('PcmAudioPlayer: Resuming from pause at ${elapsedTime.inSeconds}s');
      _state = PcmPlayerState.resuming;

      // Re-initialize the native PCM player (it was released on pause).
      // Important: do NOT call start() here — keep _isStarted = false so that
      // _onAudioData will wait for a preroll buffer before starting the native
      // player.  Starting with an empty buffer causes _onFeedRequested to fire
      // immediately, injecting silence that interleaves with the first real
      // audio chunks and produces an audible crackle on resume.
      try {
        await pcm.FlutterPcmSound.setup(
          sampleRate: _format.sampleRate,
          channelCount: _format.channels,
        );
        await pcm.FlutterPcmSound.setFeedThreshold(_feedThreshold);
        pcm.FlutterPcmSound.setFeedCallback(_onFeedRequested);
        // _isStarted stays false — _onAudioData will call _startPlayback()
        // once _minChunksBeforeStart chunks have buffered.
      } catch (e) {
        _logger.log('PcmAudioPlayer: Error re-initializing on resume: $e');
        _emitError(PcmPlayerError.resumeFailed, e.toString());
        _state = PcmPlayerState.error;
        return false;
      }

      _state = PcmPlayerState.playing;
      _startElapsedTimeTimer();

      _logger.log('PcmAudioPlayer: Resumed playback');
      return true;
    } else if (_state == PcmPlayerState.ready) {
      await _startPlayback();  // _startPlayback() already logs 'Started playback'

      // Start feeding
      if (!_isFeeding && _audioBuffer.isNotEmpty) {
        _feedNextChunk();
      }
      return true;
    }

    return false;
  }

  /// Pause playback - stops feeding and releases player for instant stop
  /// Position is preserved via _bytesPlayed tracking
  /// Uses release() to clear native buffer for instant audio stop
  /// Returns true if pause was successful
  Future<bool> pause() async {
    if (_state != PcmPlayerState.playing && _state != PcmPlayerState.pausing) {
      _logger.log('PcmAudioPlayer: Cannot pause - not playing/pausing (state: $_state)');
      return false;
    }

    _logger.log('PcmAudioPlayer: Pause requested');
    _userPaused = true;

    // Set pausing state FIRST to stop feed loop from starting new feeds
    _state = PcmPlayerState.pausing;

    // Clear our buffer - no more data will be fed
    _audioBuffer.clear();

    // Clear feed callback to prevent native from triggering more feeds
    pcm.FlutterPcmSound.setFeedCallback(null);

    // Mark as not feeding
    _isFeeding = false;

    // Save position and stop timer
    _bytesPlayedAtLastPause = _bytesPlayed;
    _stopElapsedTimeTimer();

    // Release immediately (awaited) to clear the native PCM buffer.
    // Critical: must happen BEFORE we set state = paused so that if play() is
    // called immediately after (rapid next/prev), the old audio is already gone
    // from the native player. The old approach (Future.delayed + state guard)
    // was skipping release() on rapid transitions, causing old audio to bleed
    // into the new track and the user having to wait for the buffer to drain.
    try {
      await pcm.FlutterPcmSound.release().timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          _logger.log('PcmAudioPlayer: Release timed out');
          _emitError(PcmPlayerError.releaseTimeout, 'release() timed out');
        },
      );
      _isStarted = false;
      _logger.log('PcmAudioPlayer: Player released for instant stop');
    } catch (e) {
      _logger.log('PcmAudioPlayer: Release error (expected if already released): $e');
    }

    // Transition to paused state
    _state = PcmPlayerState.paused;
    _logger.log('PcmAudioPlayer: Paused playback at ${elapsedTime.inSeconds}s');
    return true;
  }

  /// Stop playback (clears buffer and resets position)
  /// Returns true if stop was successful
  Future<bool> stop() async {
    if (_state == PcmPlayerState.idle) return true;

    _logger.log('PcmAudioPlayer: Stop requested');

    // Set stopping state to block any in-flight feed operations
    _state = PcmPlayerState.stopping;
    _isStarted = false;
    _stopElapsedTimeTimer();

    // Clear the feed callback to prevent native code from triggering new feeds
    pcm.FlutterPcmSound.setFeedCallback(null);

    // Wait for any in-progress feed operation to complete (with timeout)
    final completer = _feedCompleter;
    if (completer != null && !completer.isCompleted) {
      await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          _logger.log('PcmAudioPlayer: Feed wait timed out on stop');
        },
      );
    }

    _audioBuffer.clear();
    _isFeeding = false;

    try {
      await pcm.FlutterPcmSound.release();
    } catch (e) {
      _logger.log('PcmAudioPlayer: Error releasing: $e');
    }

    _state = PcmPlayerState.ready;
    _framesPlayed = 0;
    _bytesPlayed = 0;
    _bytesPlayedAtLastPause = 0;
    _playbackStartTime = null;
    _userPaused = false;        // Reset so silence padding works on next track
    _silencePaddingFed = 0;     // Reset padding counter for next stream
    _logger.log('PcmAudioPlayer: Stopped playback');

    // Re-initialize for next playback
    await initialize(format: _format);
    return true;
  }

  /// Reset position to zero (for new track) without stopping playback
  void resetPosition() {
    _framesPlayed = 0;
    _bytesPlayed = 0;
    _bytesPlayedAtLastPause = 0;
    _playbackStartTime = DateTime.now();
    _logger.log('PcmAudioPlayer: Position reset to 0');
    _emitElapsedTime();
  }

  /// Disconnect from audio stream
  Future<void> disconnect() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await stop();
    _logger.log('PcmAudioPlayer: Disconnected from stream');
  }

  /// Release all resources
  Future<void> dispose() async {
    _logger.log('PcmAudioPlayer: Disposing...');

    // Set stopping state to block any feed operations
    _state = PcmPlayerState.stopping;
    _isStarted = false;
    _stopElapsedTimeTimer();

    // Clear the feed callback first
    pcm.FlutterPcmSound.setFeedCallback(null);

    // Wait for any in-progress feed operation
    final completer = _feedCompleter;
    if (completer != null && !completer.isCompleted) {
      await completer.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          _logger.log('PcmAudioPlayer: Feed wait timed out on dispose');
        },
      );
    }

    _isFeeding = false;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    _audioBuffer.clear();

    try {
      await pcm.FlutterPcmSound.release().timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          _logger.log('PcmAudioPlayer: Release timed out on dispose');
        },
      );
    } catch (e) {
      _logger.log('PcmAudioPlayer: Error releasing: $e');
    }

    if (!_elapsedTimeController.isClosed) {
      await _elapsedTimeController.close();
    }

    _state = PcmPlayerState.idle;
    _logger.log('PcmAudioPlayer: Disposed');
  }
}
