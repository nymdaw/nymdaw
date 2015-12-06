module audio.mixer.coreaudio;

version(HAVE_COREAUDIO) {
    private import std.conv;

    private import audio.mixer.mixer;

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
