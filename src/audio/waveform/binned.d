module audio.sequence.waveform.binned;

private import std.algorithm;

private import audio.types;

/// Stores the min/max sample values of a single-channel waveform at a specified binning size
final class WaveformBinned {
public:
    /// Compute this cache via raw audio data. The cache is for a single channel only.
    /// Params:
    /// binSize = The number of consecutive samples to bin for this cache
    /// audioBuffer = The buffer of audio data to bin
    /// nChannels = The number of interleaved channels in the audio buffer
    /// channelIndex = The channel index to use for this cache
    this(nframes_t binSize, immutable(sample_t[]) audioBuffer, channels_t nChannels, channels_t channelIndex) {
        assert(binSize > 0);

        _binSize = binSize;
        immutable auto cacheLength = (audioBuffer.length / nChannels) / binSize;

        sample_t[] minValues = new sample_t[](cacheLength);
        sample_t[] maxValues = new sample_t[](cacheLength);

        for(auto i = 0, j = 0; i < audioBuffer.length && j < cacheLength; i += binSize * nChannels, ++j) {
            auto audioSlice = audioBuffer[i .. i + binSize * nChannels];
            minValues[j] = 1;
            maxValues[j] = -1;

            for(auto k = channelIndex; k < audioSlice.length; k += nChannels) {
                if(audioSlice[k] > maxValues[j]) maxValues[j] = audioSlice[k];
                if(audioSlice[k] < minValues[j]) minValues[j] = audioSlice[k];
            }
        }

        _minValues = cast(immutable)(minValues);
        _maxValues = cast(immutable)(maxValues);
    }

    /// Compute this cache via another cache. The cache is for a single channel only.
    /// Params:
    /// binSize = The number of consecutive samples (with respect to the original audio buffer)
    ///           to bin for this cache.
    /// other = The source cache from which to compute this cache.
    this(nframes_t binSize, in WaveformBinned other) {
        assert(binSize > 0);

        immutable auto binScale = binSize / other.binSize;
        _binSize = binSize;

        immutable size_t srcCount = min(other.minValues.length, other.maxValues.length);
        immutable size_t destCount = srcCount / binScale;
        
        sample_t[] minValues = new sample_t[](destCount);
        sample_t[] maxValues = new sample_t[](destCount);

        for(auto i = 0, j = 0; i < srcCount && j < destCount; i += binScale, ++j) {
            for(auto k = 0; k < binScale; ++k) {
                minValues[j] = 1;
                maxValues[j] = -1;
                if(other.minValues[i + k] < minValues[j]) {
                    minValues[j] = other.minValues[i + k];
                }
                if(other.maxValues[i + k] > maxValues[j]) {
                    maxValues[j] = other.maxValues[i + k];
                }
            }
        }

        _minValues = cast(immutable)(minValues);
        _maxValues = cast(immutable)(maxValues);
    }

    /// This constructor is for initializing this cache from a slice of a previously computed cache.
    /// No binning occurs; the newly constructed cache will be identical to the source cache.
    this(nframes_t binSize, immutable(sample_t[]) minValues, immutable(sample_t[]) maxValues) {
        _binSize = binSize;
        _minValues = minValues;
        _maxValues = maxValues;
    }

    /// The number of consecutive samples (with respect to the original audio buffer)
    @property nframes_t binSize() const { return _binSize; }

    /// An array of binned cache values.
    /// Each element represents the minimum sample value found over the binning length.
    @property const(sample_t[]) minValues() const { return _minValues; }

    /// An array of binned cache values.
    /// Each element represents the maximum sample value found over the binning length.
    @property const(sample_t[]) maxValues() const { return _maxValues; }

    /// Returns: A new binned waveform for the specified slice.
    WaveformBinned opSlice(size_t startIndex, size_t endIndex) const {
        return new WaveformBinned(_binSize, _minValues[startIndex .. endIndex], _maxValues[startIndex .. endIndex]);
    }

private:
    immutable(nframes_t) _binSize;

    immutable(sample_t[]) _minValues;
    immutable(sample_t[]) _maxValues;
}
