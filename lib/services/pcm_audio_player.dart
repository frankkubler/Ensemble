import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show unawaited;
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart' as pcm;
import 'package:audio_session/audio_session.dart';
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
  Completer<void>? _feedCompleter;  // Tracks when current feed operation completes

  // Error callback for operation failures
  PcmErrorCallback? onError;

  // Maximum chunks to feed at once to keep native buffer small (~200ms)
  // Each chunk is ~25ms of audio, so 8 chunks = ~200ms
  // Reduced from 12 (300ms) to 8 for faster pause response
  static const int _maxChunksPerFeed = 8;

  // Feed threshold - lower = faster pause but more risk of underruns
  // Reduced from 8000 to 5000 frames (~104ms vs ~166ms) for faster response
  static const int _feedThreshold = 5000;

  // Maximum buffer size to prevent memory overflow (~10 seconds of audio)
  // At 48kHz stereo 16-bit: 192KB/sec, so ~2MB for 10 seconds
  // Each chunk is ~4KB, so max ~500 chunks
  static const int _maxBufferChunks = 500;

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

      // CRITICAL: Configure AudioSession BEFORE initializing flutter_pcm_sound
      // This ensures audio is properly routed to Android Auto, car Bluetooth, etc.
      try {
        final session = await AudioSession.instance;
        if (!session.isConfigured) {
          await session.configure(const AudioSessionConfiguration.music());
          _logger.log('PcmAudioPlayer: AudioSession configured for music playback');
        }
      } catch (e) {
        _logger.log('PcmAudioPlayer: AudioSession configuration warning (non-fatal): $e');
        // Continue anyway - AudioSession might already be configured by AudioHandler
      }

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
    if (_state != PcmPlayerState.playing) return;
    if (_shouldBlockFeeding) return;
    if (_audioBuffer.isEmpty || _isFeeding) return;

    _feedNextChunk();
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

    // Handle audio arriving during paused/transitional states
    // This can happen when audio frames arrive before stream/start message (race condition)
    // We need to auto-recover in this case
    if (_shouldBlockFeeding) {
      // If we're paused and audio is arriving, this is likely a new stream
      // starting before the stream/start message. Queue for auto-recovery.
      if (_state == PcmPlayerState.paused && !_isAutoRecovering) {
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

    // Start playback if not already started
    if (!_isStarted && _state == PcmPlayerState.ready) {
      _startPlayback();
    }

    // Feed data if not currently feeding
    if (!_isFeeding && _isStarted) {
      _feedNextChunk();
    }
  }

  /// Auto-recover from paused state when audio arrives unexpectedly
  Future<void> _autoRecoverFromPause() async {
    _logger.log('PcmAudioPlayer: Auto-recovering from pause');

    try {
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

    try {
      await pcm.FlutterPcmSound.start();
      _isStarted = true;
      _state = PcmPlayerState.playing;
      _playbackStartTime = DateTime.now();
      _startElapsedTimeTimer();
      _logger.log('PcmAudioPlayer: Started playback');
    } catch (e) {
      _logger.log('PcmAudioPlayer: Error starting playback: $e');
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

  /// Feed the next chunk of audio data to the player
  /// CRITICAL: Only feeds limited chunks to keep native buffer small (~200ms)
  /// This enables faster pause response by minimizing buffered audio
  Future<void> _feedNextChunk() async {
    if (_isFeeding || _audioBuffer.isEmpty || _shouldBlockFeeding) return;

    _isFeeding = true;
    _feedCompleter = Completer<void>();

    try {
      int chunksProcessed = 0;

      // CRITICAL: Only feed limited chunks to keep native buffer small
      // This is the key to fast pause - we drain ~200ms instead of 5-8 seconds
      while (_audioBuffer.isNotEmpty &&
             chunksProcessed < _maxChunksPerFeed &&
             _state == PcmPlayerState.playing &&
             !_shouldBlockFeeding) {
        final chunk = _audioBuffer.removeAt(0);

        // Convert Uint8List (raw bytes) to Int16 samples
        // Sendspin sends 16-bit little-endian PCM
        final rawSamples = _bytesToInt16List(chunk);
        final samples = _volumeGain == 1.0
            ? rawSamples
            : rawSamples.map((s) => (s * _volumeGain).round().clamp(-32768, 32767)).toList();

        // Check state again before the async feed call
        if (samples.isNotEmpty && !_shouldBlockFeeding) {
          try {
            await pcm.FlutterPcmSound.feed(pcm.PcmArrayInt16.fromList(samples));
          } catch (feedError) {
            // Auto-recover from "must call setup first" error
            // This happens when audio frames arrive before stream/start message
            if (feedError.toString().contains('must call setup first') && !_isAutoRecovering) {
              _logger.log('PcmAudioPlayer: Auto-recovering from setup error');
              _isAutoRecovering = true;

              try {
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
                _logger.log('PcmAudioPlayer: Auto-recovery successful');

                // Retry the feed with the current chunk
                await pcm.FlutterPcmSound.feed(pcm.PcmArrayInt16.fromList(samples));
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

          // Don't update stats if we got paused during the feed
          if (!_shouldBlockFeeding) {
            _framesPlayed++;
            _bytesPlayed += chunk.length;
            chunksProcessed++;

            // Log periodically
            if (_framesPlayed % 100 == 0) {
              _logger.log('PcmAudioPlayer: Played $_framesPlayed frames (${(_bytesPlayed / 1024).toStringAsFixed(1)} KB)');
            }
          }
        }

        // Yield to event loop mid-feed to allow UI to respond
        if (chunksProcessed % 4 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      // Don't log errors during pause/transition - expected when player is released
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
      _logger.log('PcmAudioPlayer: Resuming from pause at ${elapsedTime.inSeconds}s');
      _state = PcmPlayerState.resuming;

      // Re-initialize the PCM player (it was released on pause)
      try {
        await pcm.FlutterPcmSound.setup(
          sampleRate: _format.sampleRate,
          channelCount: _format.channels,
        );
        await pcm.FlutterPcmSound.setFeedThreshold(_feedThreshold);
        pcm.FlutterPcmSound.setFeedCallback(_onFeedRequested);
        await pcm.FlutterPcmSound.start();
        _isStarted = true;
      } catch (e) {
        _logger.log('PcmAudioPlayer: Error re-initializing on resume: $e');
        _emitError(PcmPlayerError.resumeFailed, e.toString());
        _state = PcmPlayerState.error;
        return false;
      }

      _state = PcmPlayerState.playing;
      _startElapsedTimeTimer();

      // Resume feeding - new audio will come from stream
      if (!_isFeeding && _audioBuffer.isNotEmpty) {
        _feedNextChunk();
      }

      _logger.log('PcmAudioPlayer: Resumed playback');
      return true;
    } else if (_state == PcmPlayerState.ready) {
      await _startPlayback();
      _logger.log('PcmAudioPlayer: Started playback');

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
    if (_state != PcmPlayerState.playing) {
      _logger.log('PcmAudioPlayer: Cannot pause - not playing (state: $_state)');
      return false;
    }

    _logger.log('PcmAudioPlayer: Pause requested');

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

    // Schedule release() to clear native buffer - use Future.delayed to yield control
    // This allows UI to update before the potentially blocking release() call
    unawaited(Future.delayed(Duration.zero, () async {
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
    }));

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
