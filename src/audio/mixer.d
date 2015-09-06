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

abstract class Mixer {
public:
    this(string appName) {
        _appName = appName;

        initializeMixer();

        _masterBus = new MasterBus(sampleRate);
    }

    ~this() {
        cleanupMixer();
        super.destroy();
    }

    void exportSessionToFile(string fileName,
                             AudioFileFormat audioFileFormat,
                             AudioBitDepth bitDepth,
                             SaveState.Callback progressCallback = null) {
        // default to stereo for exporting
        enum exportChannels = 2;

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

    final void reset() {
        _tracks = [];
        _nframes = 0;
        _transportOffset = 0;
        _playing = false;
        _looping = false;
        _soloTrack = false;
        _loopStart = _loopEnd = 0;
    }

    final Track createTrack() {
        Track track = new Track(sampleRate);
        track.resizeDelegate = &resizeIfNecessary;
        _tracks ~= track;
        return track;
    }

    final bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    @property nframes_t sampleRate();

    @property final string appName() const @nogc nothrow {
        return _appName;
    }
    @property final MasterBus masterBus() @nogc nothrow {
        return _masterBus;
    }
    @property final const(MasterBus) masterBus() @nogc nothrow const {
        return _masterBus;
    }
    @property final nframes_t nframes() const @nogc nothrow {
        return _nframes;
    }
    @property final nframes_t nframes(nframes_t newNFrames) @nogc nothrow {
        return (_nframes = newNFrames);
    }
    @property final nframes_t lastFrame() const @nogc nothrow {
        return (_nframes > 0 ? nframes - 1 : 0);
    }
    @property final nframes_t transportOffset() const @nogc nothrow {
        return _transportOffset;
    }
    @property final nframes_t transportOffset(nframes_t newOffset) @nogc nothrow {
        disableLoop();
        return (_transportOffset = min(newOffset, nframes));
    }

    @property final bool playing() const @nogc nothrow {
        return _playing;
    }
    final void play() nothrow {
        GC.disable(); // disable garbage collection while playing

        _playing = true;
    }
    final void pause() nothrow {
        disableLoop();
        _playing = false;

        GC.enable(); // enable garbage collection while paused
    }

    @property final bool soloTrack() const @nogc nothrow { return _soloTrack; }
    @property final bool soloTrack(bool enable) @nogc nothrow { return (_soloTrack = enable); }

    @property final bool looping() const @nogc nothrow {
        return _looping;
    }
    final void enableLoop(nframes_t loopStart, nframes_t loopEnd) @nogc nothrow {
        _looping = true;
        _loopStart = loopStart;
        _loopEnd = loopEnd;
    }
    final void disableLoop() @nogc nothrow {
        _looping = false;
    }

    final void bounceStereoInterleaved(nframes_t bufNFrames,
                                       channels_t nChannels,
                                       sample_t* mixBuf) {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        _bounceTracksStereoInterleaved(_bounceTransportOffset, bufNFrames, nChannels, mixBuf);

        _bounceTransportOffset += bufNFrames / nChannels;
    }

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

protected:
    void initializeMixer();
    void cleanupMixer() nothrow;

private:
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

    alias _bounceTracksStereoInterleaved = _mixTracksStereoInterleaved!"bounceStereoInterleaved";

    // stop playing if the transport is at the end of the project
    bool _transportFinished() @nogc nothrow {
        if(_playing && _transportOffset >= lastFrame) {
            _playing = _looping; // don't stop playing if currently looping
            _transportOffset = lastFrame;
            return true;
        }
        return false;
    }

    string _appName;

    Track[] _tracks;
    MasterBus _masterBus;
    nframes_t _nframes;
    nframes_t _transportOffset;
    nframes_t _bounceTransportOffset;
    bool _playing;
    bool _looping;
    bool _soloTrack;
    nframes_t _loopStart;
    nframes_t _loopEnd;
}

version(HAVE_JACK) {
    final class JackMixer : Mixer {
    public:
        this(string appName) {
            if(_instance !is null) {
                throw new AudioError("Only one JackMixer instance may be constructed per process");
            }
            _instance = this;
            super(appName);
        }

        @property override nframes_t sampleRate() { return jack_get_sample_rate(_client); }

    protected:
        override void initializeMixer() {
            _client = jack_client_open(appName.toStringz, JackOptions.JackNoStartServer, null);
            if(!_client) {
                throw new AudioError("jack_client_open failed");
            }

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
                jack_get_ports(_client, null, null, JackPortFlags.JackPortIsInput | JackPortFlags.JackPortIsPhysical);
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

        override void cleanupMixer() nothrow {
            jack_client_close(_client);
        }

    private:
        extern(C) static int _jackProcessCallback(jack_nframes_t bufNFrames, void* arg) @nogc nothrow {
            sample_t* mixBuf1 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort1, bufNFrames));
            sample_t* mixBuf2 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort2, bufNFrames));

            _instance.mixStereoNonInterleaved(bufNFrames, mixBuf1, mixBuf2);

            return 0;
        };

        __gshared static JackMixer _instance; // there should be only one instance per process

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
        enum outputChannels = 2; // default to stereo

        this(string appName, nframes_t sampleRate = 44100) {
            if(_instance !is null) {
                throw new AudioError("Only one CoreAudioMixer instance may be constructed per process");
            }
            _instance = this;
            _sampleRate = sampleRate;
            super(appName);
        }

        ~this() {
            _instance = null;
        }

        @property override nframes_t sampleRate() { return _sampleRate; }

    protected:
        override void initializeMixer() {
            if(!coreAudioInit(sampleRate, outputChannels, &_coreAudioProcessCallback)) {
                throw new AudioError(to!string(coreAudioErrorString()));
            }
        }

        override void cleanupMixer() nothrow {
            coreAudioCleanup();
        }

    private:
        extern(C) static void _coreAudioProcessCallback(nframes_t bufNFrames,
                                                        channels_t nChannels,
                                                        sample_t* mixBuffer) @nogc nothrow {
            _instance.mixStereoInterleaved(bufNFrames, nChannels, mixBuffer);
        }

        __gshared static CoreAudioMixer _instance; // there should be only one instance per process

        nframes_t _sampleRate;
    }
}

version(HAVE_PORTAUDIO) {
    final class PortAudioMixer : Mixer {
    public:
        enum outputChannels = 2; // default to stereo

        this(string appName, nframes_t sampleRate = 44100) {
            if(_instance !is null) {
                throw new AudioError("Only one PortAudioMixer instance may be constructed per process");
            }
            _instance = this;
            _sampleRate = sampleRate;
            super(appName);
        }

        ~this() {
            _instance = null;
        }

        @property override nframes_t sampleRate() { return _sampleRate; }

    protected:
        static struct Phase {
            sample_t left = 0;
            sample_t right = 0;
        }

        override void initializeMixer() {
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

        override void cleanupMixer() nothrow {
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

        __gshared static PortAudioMixer _instance; // there should be only one instance per process

        nframes_t _sampleRate;
        PaStream* _stream;
    }
}
