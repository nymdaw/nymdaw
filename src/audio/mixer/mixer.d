module audio.mixer.mixer;

private import core.memory;

public import audio.masterbus;
public import audio.timeline;
public import audio.track;
public import audio.types;

/// This class handles all audio output, such as real-time output to hardware or offline output to a file.
/// It handles the master bus, stores all tracks in the session in an array,
/// and provides routines to control the "transport", which indicates the temporal position of audio playback
/// for the session.
/// It also provides abstract methods to initialize and uninitialize a specific audio driver.
/// Implementations of this class are responsible for setting up an audio thread and callback, which
/// should call either `mixStereoInterleaved` or `mixStereoNonInterleaved` to fill the output device's
/// audio buffers in real time.
/// Note this class's constructor initializes the driver, but the user is responsible for manually
/// calling `cleanupMixer` when the application exits. This ensures that the application will properly
/// destroy the audio thread and exit cleanly, without a segmentation fault.
abstract class Mixer {
public:
    /// Params:
    /// appName = The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    this(string appName) {
        _appName = appName;

        // abstract method to initialize the audio driver
        onInitialize();

        // initialize the master bus
        _masterBus = new MasterBus(sampleRate);

        // initialize the timeline
        _timeline = new Timeline();
    }

    /// Abstract method to get the sample rate, in samples per second, of the session
    @property nframes_t sampleRate();

    /// The user is responsible for calling cleanup() before the application exits
    /// or the mixer destructor is called.
    /// This ensures that the application won't crash when exiting.
    final void cleanup() {
        onCleanup();
    }

    /// Reset the mixer to an empty state. This is useful for starting new sessions.
    final void reset() {
        _tracks = [];
        _soloTrack = false;

        _playing = false;
        _looping = false;
        _loopStart = _loopEnd = 0;

        _timeline.reset();
    }

    /// Construct a track object and register it with the mixer
    final Track createTrack() {
        Track track = new Track(sampleRate, _timeline);
        _tracks ~= track;
        return track;
    }

    /// Returns: The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    @property final string appName() const @nogc nothrow {
        return _appName;
    }

    /// The timeline for this mixer instance; contains the number of frames and transport
    @property final Timeline timeline() @nogc nothrow {
        return _timeline;
    }

    /// The master bus object associated with the mixer
    @property final MasterBus masterBus() @nogc nothrow {
        return _masterBus;
    }
    /// ditto 
    @property final const(MasterBus) masterBus() @nogc nothrow const {
        return _masterBus;
    }

    /// Whether any track registered with the mixer is currently in "solo" mode.
    @property final bool soloTrack() const @nogc nothrow { return _soloTrack; }
    /// ditto
    @property final bool soloTrack(bool enable) @nogc nothrow { return (_soloTrack = enable); }

    /// Indicates whether the mixer is current playing (i.e., moving the transport), or paused.
    @property bool playing() const @nogc nothrow {
        return _playing;
    }

    /// If the mixer is currently paused, begin playing
    void play() nothrow {
        GC.disable(); // disable garbage collection while playing

        _playing = true;
    }

    /// If the mixer is currently playing, pause the mixer
    void pause() nothrow {
        disableLoop();
        _playing = false;

        GC.enable(); // enable garbage collection while paused
    }

    /// Indicates whether the mixer is currently looping a section of audio specified by the user.
    @property bool looping() const @nogc nothrow {
        return _looping;
    }

    /// Specify a section of audio to loop
    void enableLoop(nframes_t loopStart, nframes_t loopEnd) @nogc nothrow {
        _looping = true;
        _loopStart = loopStart;
        _loopEnd = loopEnd;
    }

    /// Disable looping and return to the conventional playback mode
    void disableLoop() @nogc nothrow {
        _looping = false;
    }

    /// Mix all registered tracks into an interleaved stereo buffer using a specialized bounce transport.
    /// Params:
    /// bounceTimeline = A timeline to keep track of a unique transport for this bounce
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
    final void bounceStereoInterleaved(Timeline bounceTimeline,
                                       nframes_t bufNFrames,
                                       channels_t nChannels,
                                       sample_t* mixBuf) {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        _bounceTracksStereoInterleaved(bounceTimeline.transportOffset, bufNFrames, nChannels, mixBuf);

        bounceTimeline.moveTransport(bufNFrames / nChannels);
    }

    /// Mix all registered tracks into an interleaved stereo buffer and update the playback transport
    /// Params:
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
    final void mixStereoInterleaved(nframes_t bufNFrames,
                                    channels_t nChannels,
                                    sample_t* mixBuf) @nogc nothrow {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(playing) {
            _mixTracksStereoInterleaved(_timeline.transportOffset, bufNFrames, nChannels, mixBuf);

            if(_masterBus !is null) {
                _masterBus.processStereoInterleaved(mixBuf, bufNFrames, nChannels);
            }

            _moveTransport(bufNFrames / nChannels);
        }
    }

    /// Mix all registered tracks into a non-interleaved stereo buffer and update the playback transport
    /// Params:
    /// bufNFrames = The individual length of each output buffer
    /// mixBuf1 = The left output buffer
    /// mixBuf2 = The right output buffer
    final void mixStereoNonInterleaved(nframes_t bufNFrames,
                                       sample_t* mixBuf1,
                                       sample_t* mixBuf2) @nogc nothrow {
        // initialize the buffers to silence
        import core.stdc.string: memset;
        memset(mixBuf1, 0, sample_t.sizeof * bufNFrames);
        memset(mixBuf2, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(playing) {
            _mixTracksStereoNonInterleaved(_timeline.transportOffset, bufNFrames, mixBuf1, mixBuf2);

            if(_masterBus !is null) {
                _masterBus.processStereoNonInterleaved(mixBuf1, mixBuf2, bufNFrames);
            }

            _moveTransport(bufNFrames);
        }
    }

protected:
    /// Abstract method to initialize the audio driver, audio thread and its associated callback function
    void onInitialize();

    /// Abstract method to uninitialize the audio driver and destroy the audio thread
    void onCleanup() nothrow;

private:
    /// Move the transport offset forward, and update the playing and looping status.
    void _moveTransport(nframes_t framesPlayed) @nogc nothrow {
        _timeline.moveTransport(framesPlayed);

        _checkTransportFinished();
        _updateLooping();
    }

    /// Stop playing if the transport has moved past the end of the session
    void _checkTransportFinished() @nogc nothrow {
        if(_playing && _timeline.transportOffset >= _timeline.lastFrame) {
            _playing = _looping; // don't stop playing if currently looping
            _timeline.transportOffset = _timeline.lastFrame;
        }
    }

    /// Update the transport if currently looping
    void _updateLooping() @nogc nothrow {
        if(looping && _timeline.transportOffset >= _loopEnd) {
            _timeline.transportOffset = _loopStart;
        }
    }

    /// Template function to mix down all registered tracks to a single buffer,
    /// with interleaved stereo channels.
    /// At this time, the template argument should either be "mixStereoInterleaved" or
    /// "bounceStereoInterleaved". This guarantees identical behavior when mixing or bouncing
    /// to an interleaved stereo device or file.
    final void _mixTracksStereoInterleaved(string MixFunc = "mixStereoInterleaved")
        (nframes_t offset,
         nframes_t bufNFrames,
         channels_t nChannels,
         sample_t* mixBuf) @nogc nothrow {
        if(_soloTrack) {
            foreach(t; _tracks) {
                if(t.solo) {
                    mixin("t." ~ MixFunc ~ "(offset, bufNFrames, nChannels, mixBuf);");
                }
            }
        }
        else {
            foreach(t; _tracks) {
                mixin("t." ~ MixFunc ~ "(offset, bufNFrames, nChannels, mixBuf);");
            }
        }
    }

    /// Mix down all registered tracks to two separate buffers, corresponding to the left and right
    /// channels of a stereo output device.
    final void _mixTracksStereoNonInterleaved(nframes_t offset,
                                              nframes_t bufNFrames,
                                              sample_t* mixBuf1,
                                              sample_t* mixBuf2) @nogc nothrow {
        if(_soloTrack) {
            foreach(t; _tracks) {
                if(t.solo) {
                    t.mixStereoNonInterleaved(offset, bufNFrames, mixBuf1, mixBuf2);
                }
            }
        }
        foreach(t; _tracks) {
            t.mixStereoNonInterleaved(offset, bufNFrames, mixBuf1, mixBuf2);
        }
    }

    /// Wrap the template argument for `_mixTracksStereoInterleaved` in the case when the
    /// mixer is bouncing the session to a file instead of playing it back on an audio device.
    alias _bounceTracksStereoInterleaved = _mixTracksStereoInterleaved!"bounceStereoInterleaved";

    /// The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    string _appName;

    /// Array of all tracks curently registered with the mixer
    Track[] _tracks;

    /// The master bus object, should usually check for a null reference in the audio thread,
    /// since the audio driver may be initialized prior to construction of the master bus
    MasterBus _masterBus;

    /// The timeline for this mixer instance; contains the number of frames and transport
    Timeline _timeline;

    /// Indicates whether there are any tracks for which "solo" mode is enabled.
    bool _soloTrack;

    /// Indicates whether the mixer is current playing (i.e., moving the transport), or paused.
    bool _playing;

    /// Indicates whether the mixer is currently looping a section of audio specified by the user.
    bool _looping;

    /// The start frame of the currently looping section, as specified by the user.
    nframes_t _loopStart;

    /// The end frame of the currently looping section, as specified by the user.
    nframes_t _loopEnd;
}
