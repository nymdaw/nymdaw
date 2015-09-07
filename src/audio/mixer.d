/// Mixer abstract class and implementations for various audio drivers

module audio.mixer;

private import std.algorithm;
private import std.conv;
private import std.file;
private import std.string;

private import core.memory;

private import sndfile;

version(HAVE_JACK) {
    private import jack.jack;
}
version(HAVE_PORTAUDIO) {
    private import portaudio.portaudio;
}

private import util.scopedarray;

public import audio.masterbus;
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
    }

    /// The user is responsible for calling cleanup() before the application exits
    /// or the mixer destructor is called.
    /// This ensures that the application won't crash when exiting.
    final void cleanup() {
        onCleanup();
    }

    /// Bounce the entire session to an audio file
    final void exportSessionToFile(string fileName,
                                   AudioFileFormat audioFileFormat,
                                   AudioBitDepth bitDepth,
                                   SaveState.Callback progressCallback = null) {
        // default to stereo for exporting
        enum exportChannels = 2;

        // helper function to remove the partially-written file in the case of an error
        void removeFile() {
            try {
                std.file.remove(fileName);
            }
            catch(FileException e) {
            }
        }

        SNDFILE* outfile;
        SF_INFO sfinfo;

        sfinfo.samplerate = sampleRate;
        sfinfo.frames = nframes;
        sfinfo.channels = exportChannels;
        switch(audioFileFormat) {
            case AudioFileFormat.wavFilterName:
                sfinfo.format = SF_FORMAT_WAV;
                break;

            case AudioFileFormat.flacFilterName:
                sfinfo.format = SF_FORMAT_FLAC;
                break;

            case AudioFileFormat.oggVorbisFilterName:
                sfinfo.format = SF_FORMAT_OGG | SF_FORMAT_VORBIS;
                break;

            case AudioFileFormat.aiffFilterName:
                sfinfo.format = SF_FORMAT_AIFF;
                break;

            case AudioFileFormat.cafFilterName:
                sfinfo.format = SF_FORMAT_CAF;
                break;

            default:
                if(progressCallback !is null) {
                    progressCallback(SaveState.complete, 0);
                    removeFile();
                }
                throw new AudioError("Invalid audio file format");
        }

        if(audioFileFormat == AudioFileFormat.wavFilterName ||
           audioFileFormat == AudioFileFormat.aiffFilterName ||
           audioFileFormat == AudioFileFormat.cafFilterName) {
            if(bitDepth == AudioBitDepth.pcm16Bit) {
                sfinfo.format |= SF_FORMAT_PCM_16;
            }
            else if(bitDepth == AudioBitDepth.pcm24Bit) {
                sfinfo.format |= SF_FORMAT_PCM_24;
            }
        }

        // ensure the constructed sfinfo object is valid
        if(!sf_format_check(&sfinfo)) {
            if(progressCallback !is null) {
                progressCallback(SaveState.complete, 0);
                removeFile();
            }
            throw new AudioError("Invalid output file parameters for " ~ fileName);
        }

        // attempt to open the specified file
        outfile = sf_open(fileName.toStringz(), SFM_WRITE, &sfinfo);
        if(!outfile) {
            if(progressCallback !is null) {
                progressCallback(SaveState.complete, 0);
                removeFile();
            }
            throw new AudioError("Could not open file " ~ fileName ~ " for writing");
        }

        // close the file when leaving this scope
        scope(exit) sf_close(outfile);

        // reset the bounce transport
        _bounceTransportOffset = 0;

        // counters for updating the progress bar
        immutable size_t progressIncrement = (nframes * exportChannels) / SaveState.stepsPerStage;
        size_t progressCount;

        // write all audio data in the current session to the specified file
        ScopedArray!(sample_t[]) buffer = new sample_t[](maxBufferLength * exportChannels);
        sf_count_t writeTotal;
        sf_count_t writeCount;
        while(writeTotal < nframes * exportChannels) {
            auto immutable processNFrames =
                writeTotal + maxBufferLength * exportChannels < nframes * exportChannels ?
                maxBufferLength * exportChannels : nframes * exportChannels - writeTotal;

            bounceStereoInterleaved(cast(nframes_t)(processNFrames), exportChannels, buffer.ptr);

            static if(is(sample_t == float)) {
                writeCount = sf_write_float(outfile, buffer.ptr, processNFrames);
            }
            else if(is(sample_t == double)) {
                writeCount = sf_write_double(outfile, buffer.ptr, processNFrames);
            }

            if(writeCount != processNFrames) {
                if(progressCallback !is null) {
                    progressCallback(SaveState.complete, 0);
                    removeFile();
                }
                throw new AudioError("Could not write to file " ~ fileName);
            }

            writeTotal += writeCount;

            if(progressCallback !is null && writeTotal >= progressCount) {
                progressCount += progressIncrement;
                if(!progressCallback(SaveState.write,
                                     cast(double)(writeTotal) / cast(double)(nframes * exportChannels))) {
                    removeFile();
                    return;
                }
            }
        }

        if(progressCallback !is null) {
            if(!progressCallback(SaveState.complete, 1)) {
                removeFile();
            }
        }
    }

    /// Reset the mixer to an empty state. This is useful for starting new sessions.
    final void reset() {
        _tracks = [];
        _nframes = 0;
        _transportOffset = 0;
        _playing = false;
        _looping = false;
        _soloTrack = false;
        _loopStart = _loopEnd = 0;
    }

    /// Construct a track object and register it with the mixer
    final Track createTrack() {
        Track track = new Track(sampleRate);
        track.resizeDelegate = &resizeIfNecessary;
        _tracks ~= track;
        return track;
    }

    /// Checks if `newNFrames` extends past the last frame of the mixer,
    /// and if so, changes the last frame of the mixer to `newNFrames`.
    /// Returns: `true` if and only if the mixer altered its final frame
    final bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    /// Returns: The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    @property final string appName() const @nogc nothrow {
        return _appName;
    }

    /// The master bus object associated with the mixer
    @property final MasterBus masterBus() @nogc nothrow {
        return _masterBus;
    }
    /// ditto 
    @property final const(MasterBus) masterBus() @nogc nothrow const {
        return _masterBus;
    }

    /// The total number of frames in the current session.
    /// This indicates the temporal length of the session.
    @property final nframes_t nframes() const @nogc nothrow {
        return _nframes;
    }
    /// ditto
    @property final nframes_t nframes(nframes_t newNFrames) @nogc nothrow {
        return (_nframes = newNFrames);
    }

    /// Safely get the index of the last frame in the session.
    /// Returns: Either the last index of the last frame, or 0 if the session is empty.
    @property final nframes_t lastFrame() const @nogc nothrow {
        return (_nframes > 0 ? nframes - 1 : 0);
    }

    /// The current frame index of playback.
    @property final nframes_t transportOffset() const @nogc nothrow {
        return _transportOffset;
    }
    /// ditto
    @property final nframes_t transportOffset(nframes_t newOffset) @nogc nothrow {
        disableLoop();
        return (_transportOffset = min(newOffset, nframes));
    }

    /// Indicates whether the mixer is current playing (i.e., moving the transport), or paused.
    @property final bool playing() const @nogc nothrow {
        return _playing;
    }

    /// If the mixer is currently paused, begin playing
    final void play() nothrow {
        GC.disable(); // disable garbage collection while playing

        _playing = true;
    }

    /// If the mixer is currently playing, pause the mixer
    final void pause() nothrow {
        disableLoop();
        _playing = false;

        GC.enable(); // enable garbage collection while paused
    }

    /// Whether any track registered with the mixer is currently in "solo" mode.
    @property final bool soloTrack() const @nogc nothrow { return _soloTrack; }
    /// ditto
    @property final bool soloTrack(bool enable) @nogc nothrow { return (_soloTrack = enable); }

    /// Indicates whether the mixer is currently looping a section of audio specified by the user.
    @property final bool looping() const @nogc nothrow {
        return _looping;
    }

    /// Specify a section of audio to loop
    final void enableLoop(nframes_t loopStart, nframes_t loopEnd) @nogc nothrow {
        _looping = true;
        _loopStart = loopStart;
        _loopEnd = loopEnd;
    }

    /// Disable looping and return to the conventional playback mode
    final void disableLoop() @nogc nothrow {
        _looping = false;
    }

    /// Mix all registered tracks into an interleaved stereo buffer using a specialized bounce transport.
    /// Params:
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
    final void bounceStereoInterleaved(nframes_t bufNFrames,
                                       channels_t nChannels,
                                       sample_t* mixBuf) {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        _bounceTracksStereoInterleaved(_bounceTransportOffset, bufNFrames, nChannels, mixBuf);

        _bounceTransportOffset += bufNFrames / nChannels;
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
        if(_playing && !_transportFinished()) {
            _mixTracksStereoInterleaved(_transportOffset, bufNFrames, nChannels, mixBuf);

            _transportOffset += bufNFrames / nChannels;

            if(_masterBus !is null) {
                _masterBus.processStereoInterleaved(mixBuf, bufNFrames, nChannels);
            }

            if(_looping && _transportOffset >= _loopEnd) {
                _transportOffset = _loopStart;
            }
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
        if(_playing && !_transportFinished()) {
            _mixTracksStereoNonInterleaved(_transportOffset, bufNFrames, mixBuf1, mixBuf2);

            _transportOffset += bufNFrames;

            if(_looping && _transportOffset >= _loopEnd) {
                _transportOffset = _loopStart;
            }

            if(_masterBus !is null) {
                _masterBus.processStereoNonInterleaved(mixBuf1, mixBuf2, bufNFrames);
            }
        }
    }

    /// Abstract method to get the sample rate, in samples per second, of the session
    @property nframes_t sampleRate();

protected:
    /// Abstract method to initialize the audio driver, audio thread and its associated callback function
    void onInitialize();

    /// Abstract method to uninitialize the audio driver and destroy the audio thread
    void onCleanup() nothrow;

private:
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

    /// Stop playing if the transport is at the end of the session
    bool _transportFinished() @nogc nothrow {
        if(_playing && _transportOffset >= lastFrame) {
            _playing = _looping; // don't stop playing if currently looping
            _transportOffset = lastFrame;
            return true;
        }
        return false;
    }

    /// The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    string _appName;

    /// Array of all tracks curently registered with the mixer
    Track[] _tracks;

    /// The master bus object, should usually check for a null reference in the audio thread,
    /// since the audio driver may be initialized prior to construction of the master bus
    MasterBus _masterBus;

    /// The total number of frames in the current session.
    /// This indicates the temporal length of the session.
    nframes_t _nframes;

    /// The offset, in frames, of the current playback position.
    /// Should always be greater than or equal to 0 and less than `_nframes`.
    nframes_t _transportOffset;

    /// A separate transport offset used for bouncing the session offline.
    nframes_t _bounceTransportOffset;

    /// Indicates whether the mixer is current playing (i.e., moving the transport), or paused.
    bool _playing;

    /// Indicates whether the mixer is currently looping a section of audio specified by the user.
    bool _looping;

    /// The start frame of the currently looping section, as specified by the user.
    nframes_t _loopStart;

    /// The end frame of the currently looping section, as specified by the user.
    nframes_t _loopEnd;

    /// Indicates whether there are any tracks for which "solo" mode is enabled.
    bool _soloTrack;
}

version(HAVE_JACK) {
    /// Mixer implementation using the JACK driver.
    final class JackMixer : Mixer {
    public:
        /// Initialize the JACK mixer.
        /// This creates a singleton instance of the mixer implementation that should exist
        /// throughout the application's lifetime.
        this(string appName) {
            if(_instance !is null) {
                throw new AudioError("Only one JackMixer instance may be constructed per process");
            }
            _instance = this;
            super(appName);
        }

        /// The user is responsible for calling cleanup() before the application exits
        /// or the mixer destructor is called.
        /// This ensures that the application won't crash when exiting.
        ~this() {
            _instance = null;
        }

        /// The sample rate is determined by the current JACK session
        @property override nframes_t sampleRate() { return jack_get_sample_rate(_client); }

    protected:
        /// Initialize the JACK driver and create the audio thread
        override void onInitialize() {
            _client = jack_client_open(appName.toStringz, JackOptions.JackNoStartServer, null);
            if(!_client) {
                throw new AudioError("jack_client_open failed");
            }

            // set up the stereo output ports
            immutable char* mixPort1Name = "StereoMix1";
            immutable char* mixPort2Name = "StereoMix2";
            _mixPort1 = jack_port_register(_client,
                                           mixPort1Name,
                                           JACK_DEFAULT_AUDIO_TYPE,
                                           JackPortFlags.JackPortIsOutput,
                                           0);
            _mixPort2 = jack_port_register(_client,
                                           mixPort2Name,
                                           JACK_DEFAULT_AUDIO_TYPE,
                                           JackPortFlags.JackPortIsOutput,
                                           0);
            if(!_mixPort1 || !_mixPort2) {
                throw new AudioError("jack_port_register failed");
            }

            // callback to process a single period of audio data
            if(jack_set_process_callback(_client, &_jackProcessCallback, null)) {
                throw new AudioError("jack_set_process_callback failed");
            }

            // activate the client
            if(jack_activate(_client)) {
                throw new AudioError("jack_activate failed");
            }

            // attempt to connect to physical playback ports
            const(char)** playbackPorts =
                jack_get_ports(_client,
                               null,
                               null,
                               JackPortFlags.JackPortIsInput | JackPortFlags.JackPortIsPhysical);
            if(playbackPorts && playbackPorts[1]) {
                auto status1 = jack_connect(_client, jack_port_name(_mixPort1), playbackPorts[0]);
                auto status2 = jack_connect(_client, jack_port_name(_mixPort2), playbackPorts[1]);
                import core.stdc.errno : EEXIST;
                if((status1 && status2 != EEXIST) || (status2 && status2 != EEXIST)) {
                    throw new AudioError("jack_connect failed ");
                }
            }
            jack_free(playbackPorts);
        }

        /// Clean up the JACK driver and destroy the audio thread
        override void onCleanup() nothrow {
            jack_client_close(_client);
        }

    private:
        extern(C) static int _jackProcessCallback(jack_nframes_t bufNFrames, void* arg) @nogc nothrow {
            sample_t* mixBuf1 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort1, bufNFrames));
            sample_t* mixBuf2 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort2, bufNFrames));

            _instance.mixStereoNonInterleaved(bufNFrames, mixBuf1, mixBuf2);

            return 0;
        };

        /// There should be only one mixer instance per process.
        __gshared static JackMixer _instance;

        jack_client_t* _client;
        jack_port_t* _mixPort1;
        jack_port_t* _mixPort2;
    }
}

version(HAVE_COREAUDIO) {
    private extern(C) @nogc nothrow {
        char* coreAudioErrorString();
        bool coreAudioInit(nframes_t sampleRate, channels_t nChannels, AudioCallback callback);
        void coreAudioCleanup();
        alias AudioCallback = void function(nframes_t, channels_t, sample_t*);
    }

    final class CoreAudioMixer : Mixer {
    public:
        /// Default to stereo output
        enum outputChannels = 2;

        /// Initialize the CoreAudio mixer.
        /// This creates a singleton instance of the mixer implementation that should exist
        /// throughout the application's lifetime.
        this(string appName, nframes_t sampleRate = 44100) {
            if(_instance !is null) {
                throw new AudioError("Only one CoreAudioMixer instance may be constructed per process");
            }
            _instance = this;
            _sampleRate = sampleRate;
            super(appName);
        }

        /// The user is responsible for calling cleanup() before the application exits
        /// or the mixer destructor is called.
        /// This ensures that the application won't crash when exiting.
        ~this() {
            _instance = null;
        }

        /// CoreAudio allows the application set its own sample rate
        @property override nframes_t sampleRate() { return _sampleRate; }

    protected:
        /// Initialize the CoreAudio driver and create the audio thread
        override void onInitialize() {
            if(!coreAudioInit(sampleRate, outputChannels, &_coreAudioProcessCallback)) {
                throw new AudioError(to!string(coreAudioErrorString()));
            }
        }

        /// Clean up the CoreAudio driver and destroy the audio thread
        override void onCleanup() nothrow {
            coreAudioCleanup();
        }

    private:
        extern(C) static void _coreAudioProcessCallback(nframes_t bufNFrames,
                                                        channels_t nChannels,
                                                        sample_t* mixBuffer) @nogc nothrow {
            _instance.mixStereoInterleaved(bufNFrames, nChannels, mixBuffer);
        }

        /// There should be only one mixer instance per process.
        __gshared static CoreAudioMixer _instance;

        nframes_t _sampleRate;
    }
}

version(HAVE_PORTAUDIO) {
    final class PortAudioMixer : Mixer {
    public:
        /// Default to stereo output
        enum outputChannels = 2;

        /// Initialize the PortAudio mixer.
        /// This creates a singleton instance of the mixer implementation that should exist
        /// throughout the application's lifetime.
        this(string appName, nframes_t sampleRate = 44100) {
            if(_instance !is null) {
                throw new AudioError("Only one PortAudioMixer instance may be constructed per process");
            }
            _instance = this;
            _sampleRate = sampleRate;
            super(appName);
        }

        /// The user is responsible for calling cleanup() before the application exits
        /// or the mixer destructor is called.
        /// This ensures that the application won't crash when exiting.
        ~this() {
            _instance = null;
        }

        /// PortAudio allows the application set its own sample rate
        @property override nframes_t sampleRate() { return _sampleRate; }

    protected:
        static struct Phase {
            sample_t left = 0;
            sample_t right = 0;
        }

        /// Initialize the PortAudio driver and create the audio thread
        override void onInitialize() {
            PaError err;
            Phase phaseData;

            if((err = Pa_Initialize()) != paNoError) {
                throw new AudioError(to!string(Pa_GetErrorText(err)));
            }

            static assert(is(sample_t == float));
            immutable auto sampleFormat = paFloat32;

            if((err = Pa_OpenDefaultStream(&_stream,
                                           0,
                                           outputChannels,
                                           sampleFormat,
                                           cast(double)(_sampleRate),
                                           cast(ulong)(paFramesPerBufferUnspecified),
                                           &_audioCallback,
                                           cast(void*)(&phaseData)))
               != paNoError) {
                throw new AudioError(to!string(Pa_GetErrorText(err)));
            }

            if((err = Pa_StartStream(_stream)) != paNoError) {
                throw new AudioError(to!string(Pa_GetErrorText(err)));
            }
        }

        /// Clean up the PortAudio driver and destroy the audio thread
        override void onCleanup() nothrow {
            Pa_StopStream(_stream);
            Pa_CloseStream(_stream);
            Pa_Terminate();
        }

    private:
        extern(C) static int _audioCallback(const(void)* inputBuffer,
                                            void* outputBuffer,
                                            size_t framesPerBuffer,
                                            const(PaStreamCallbackTimeInfo)* timeInfo,
                                            PaStreamCallbackFlags statusFlags,
                                            void* userData) @nogc nothrow {
            _instance.mixStereoInterleaved(cast(nframes_t)(framesPerBuffer * outputChannels),
                                           outputChannels,
                                           cast(sample_t*)(outputBuffer));
            return paContinue;
        }

        /// There should be only one mixer instance per process.
        __gshared static PortAudioMixer _instance;

        PaStream* _stream;

        nframes_t _sampleRate;
    }
}
