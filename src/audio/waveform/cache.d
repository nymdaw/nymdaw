module audio.sequence.waveform.cache;

private import std.range;
private import std.typecons;

private import audio.types;
private import audio.waveform.binned;

/// Waveform cache object for a region.
/// Stores caches for all channels at various binning sizes for a specific region.
final class WaveformCache {
public:
    /// Static array of all cache binning sizes computed for all waveforms
    static immutable nframes_t[] cacheBinSizes = [10, 20, 50, 100];
    static assert(cacheBinSizes.length > 0);

    /// Returns: `null` if the specified binning size was not found in the cache;
    ///          otherwise, returns the cache index corresponding to the specified binning size.
    static Nullable!size_t getCacheIndex(nframes_t binSize) {
        Nullable!size_t cacheIndex;
        foreach(i, cacheBinSize; cacheBinSizes) {
            if(binSize == cacheBinSize) {
                cacheIndex = i;
                break;
            }
        }
        return cacheIndex;
    }

    /// Computes the cache for all channels and binning sizes.
    /// Params:
    /// audioBuffer = The raw, interleaved audio data
    /// nChannels = The number of interleaved channels in the audio data
    this(immutable(sample_t[]) audioBuffer, channels_t nChannels) {
        // initialize the cache
        _waveformBinnedChannels = null;
        _waveformBinnedChannels.reserve(nChannels);
        for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
            WaveformBinned[] channelsBinned;
            channelsBinned.reserve(cacheBinSizes.length);

            // compute the first cache from the raw audio data
            channelsBinned ~= new WaveformBinned(cacheBinSizes[0], audioBuffer, nChannels, channelIndex);

            // compute the subsequent caches from previously computed caches
            foreach(binIndex, binSize; cacheBinSizes[1 .. $]) {
                // find a suitable cache from which to compute the next cache
                Nullable!WaveformBinned prevWaveformBinned;
                foreach(waveformBinned; retro(channelsBinned)) {
                    if(binSize % waveformBinned.binSize == 0) {
                        prevWaveformBinned = waveformBinned;
                        break;
                    }
                }

                if(prevWaveformBinned.isNull()) {
                    channelsBinned ~= new WaveformBinned(binSize, audioBuffer, nChannels, channelIndex);
                }
                else {
                    channelsBinned ~= new WaveformBinned(binSize, prevWaveformBinned);
                }
            }
            _waveformBinnedChannels ~= channelsBinned;
        }
    }

    /// Returns: A new waveform cache for the specified slice
    WaveformCache opSlice(size_t startIndex, size_t endIndex) const {
        WaveformBinned[][] result;
        result.reserve(_waveformBinnedChannels.length);
        foreach(channelsBinned; _waveformBinnedChannels) {
            WaveformBinned[] resultChannelsBinned;
            resultChannelsBinned.reserve(channelsBinned.length);
            foreach(waveformBinned; channelsBinned) {
                resultChannelsBinned ~= waveformBinned[startIndex / waveformBinned.binSize ..
                                                       endIndex / waveformBinned.binSize];
            }
            result ~= resultChannelsBinned;
        }
        return new WaveformCache(result);
    }

    /// Params:
    /// channelIndex = The channel for which to return a previoulsy computed binned waveform
    /// cacheIndex = The index (computed from the `getCacheIndex` member function) for which
    ///              to return a previously computed binned waveform.
    ///              Each index corresponds to a specific binning size.
    /// Returns: A previously computed binned waveform
    const(WaveformBinned) getWaveformBinned(channels_t channelIndex, size_t cacheIndex) const {
        return _waveformBinnedChannels[channelIndex][cacheIndex];
    }

private:
    /// Constructor for copying the waveform cache.
    /// This should only be used by this class's implementation.
    this(WaveformBinned[][] waveformBinnedChannels) {
        _waveformBinnedChannels = waveformBinnedChannels;
    }

    /// The cache of binned waveforms, indexed as [channel][waveformBinned]
    WaveformBinned[][] _waveformBinnedChannels;
}
