module audio.mixer.portaudio;

version(HAVE_PORTAUDIO) {
    private import std.conv;

    private import portaudio;

    private import audio.mixer.mixer;

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
