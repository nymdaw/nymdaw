module audio.types;

version(HAVE_JACK) {
    import jack.jack;

    alias nframes_t = jack_nframes_t;
    alias sample_t = jack_default_audio_sample_t;
}
else {
    alias nframes_t = uint;
    alias sample_t = float;
}
alias channels_t = uint;
enum maxBufferLength = 8192;

alias ResizeDelegate = bool delegate(nframes_t);

class AudioError: Exception {
    this(string msg) {
        super(msg);
    }
}
