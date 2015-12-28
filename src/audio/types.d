/// Various types used by classes in the audio module

module audio.types;

version(HAVE_JACK) {
    import jack;

    /// Representation for a quantity of frames.
    /// Typically a 32-bit unsigned integer
    alias nframes_t = jack_nframes_t;

    /// Raw audio data type.
    /// Typically a 32-bit floating point type.
    alias sample_t = jack_default_audio_sample_t;
}
else {
    /// Representation of a quantity of frames.
    /// Set to a 32-bit unsigned integer by default.
    alias nframes_t = uint;

    /// Raw audio data type.
    /// Set to a 32-bit floating-point type by default
    alias sample_t = float;
}

/// Type indicating a number of channels.
/// Typically data of this type either is either one or two, indicating mono or stereo
alias channels_t = uint;

/// No hardware input/output audio buffer should be larger than this in practice
enum maxBufferLength = 8192;

/// Class for any exception thrown by the audio module
class AudioError: Exception {
    this(string msg) {
        super(msg);
    }
}
