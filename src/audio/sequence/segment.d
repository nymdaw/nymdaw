module audio.sequence.segment;

private import audio.waveform.cache;
private import audio.types;

/// A wrapper structure around a buffer of raw, interleaved audio data.
/// Stores the audio data, the number of channels, and its corresponding waveform cache.
struct AudioSegment {
    /// Initialize this segment and compute the waveform cache
    this(immutable(sample_t[]) audioBuffer, channels_t nChannels) {
        this.audioBuffer = audioBuffer;
        this.nChannels = nChannels;
        waveformCache = new WaveformCache(audioBuffer, nChannels);
    }

    @disable this();
    @disable this(sample_t[]);

    /// Returns: The length of the audio buffer corresponding to this segment.
    @property size_t length() const @nogc nothrow {
        return audioBuffer.length;
    }

    alias opDollar = length;

    /// Params:
    /// index = An array index relative to the audio buffer corresponding to this segment.
    /// Returns: The audio sample at the specified index
    sample_t opIndex(size_t index) const @nogc nothrow {
        return audioBuffer[index];
    }

    /// Returns: A new AudioSegment corresponding to the specified slice.
    immutable(AudioSegment) opSlice(size_t startIndex, size_t endIndex) const {
        return cast(immutable)(AudioSegment(audioBuffer[startIndex .. endIndex],
                                            nChannels,
                                            waveformCache[startIndex / nChannels .. endIndex / nChannels]));
    }

    /// Raw, interleaved audio data
    immutable(sample_t[]) audioBuffer;

    /// The number of channels in the audio buffer
    channels_t nChannels;

    /// The waveform cache corresponding to the audio buffer
    WaveformCache waveformCache;

private:
    /// This copy constructor should only be used by this structure's implementation.
    this(immutable(sample_t[]) audioBuffer, channels_t nChannels, WaveformCache waveformCache) {
        this.audioBuffer = audioBuffer;
        this.nChannels = nChannels;
        this.waveformCache = waveformCache;
    }
}
