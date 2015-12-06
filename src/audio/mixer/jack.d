module audio.mixer.jack;

version(HAVE_JACK) {
    private import std.string;

    private import jack;

    private import audio.mixer.mixer;

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
