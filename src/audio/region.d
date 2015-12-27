/// Collection of classes implementing audio sequences and audio regions

module audio.region;

private import std.algorithm;
private import std.conv;
private import std.math;
private import std.path;
private import std.range;
private import std.string;
private import std.traits;
private import std.typecons;

private import core.atomic;

private import aubio;
private import rubberband;
private import samplerate;

private import util.scopedarray;

public import audio.sequence;
public import audio.timeline;
public import audio.types;
public import audio.waveform;

/// Class for an audio region that implements functionality for various audio editing operations.
/// A region corresponds to an audio sequence, which may be linked to any number of other regions.
/// Every such region may have different start/end points in relation to its source sequence.
/// Edits to one such region will be immediately reflected in all regions linked to the same
/// source sequence.
final class Region {
public:
    /// Construct a region from an audio sequence.
    /// This constructor does not automatically add this region to the
    /// list of soft links for the source sequence.
    /// Params:
    /// audioSeq = The source audio sequence for the new region.
    /// name = The name of this region. This is typically displayed in the UI.
    this(AudioSequence audioSeq, string name) {
        _sampleRate = audioSeq.sampleRate;
        _nChannels = audioSeq.nChannels;
        _name = name;

        _audioSeq = audioSeq;

        _sliceStartFrame = 0;
        _sliceEndFrame = audioSeq.nframes;
        _updateSlice();
    }

    /// Construct a region from an audio sequence with a default name.
    /// Params:
    /// audioSeq = The source audio sequence for the new region.
    this(AudioSequence audioSeq) {
        this(audioSeq, stripExtension(audioSeq.name));
    }

    /// Create a soft copy using the underlying audio sequence of this region
    Region softCopy() {
        Region newRegion = new Region(_audioSeq);
        newRegion._sliceStartFrame = _sliceStartFrame;
        newRegion._sliceEndFrame = _sliceEndFrame;
        newRegion._updateSlice();
        return newRegion;
    }

    /// Create a hard copy by cloning underlying audio sequence of this region
    Region hardCopy() {
        Region newRegion = new Region(new AudioSequence(_audioSeq));
        newRegion._sliceStartFrame = _sliceStartFrame;
        newRegion._sliceEndFrame = _sliceEndFrame;
        newRegion._updateSlice();
        return newRegion;
    }

    /// Compute the onsets for both channels.
    /// All channels are summed before onset detection.
    /// Params:
    /// params = Parameter structure for the onset detection algorithm
    /// Returns: An array of frames at which an onset occurs, with frames given locally for this region
    Onset[] getOnsetsLinkedChannels(ref const(OnsetParams) params,
                                    ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          _audioSlice,
                          sampleRate,
                          nChannels,
                          0,
                          true,
                          progressCallback);
    }

    /// Compute the onsets for a single channel.
    /// Params:
    /// params = Parameter structure for the onset detection algorithm
    /// channelIndex = The channel for which to detect onsets
    /// Returns: An array of frames at which an onset occurs, with frames given locally for this region
    Onset[] getOnsetsSingleChannel(ref const(OnsetParams) params,
                                   channels_t channelIndex,
                                   ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          _audioSlice,
                          sampleRate,
                          nChannels,
                          channelIndex,
                          false,
                          progressCallback);
    }

    /// Compute the onsets for both channels of a given audio sequence slice.
    /// All channels are summed before onset detection.
    /// Params:
    /// params = Parameter structure for the onset detection algorithm
    /// pieceTable = The audio sequence slice for which to detect onsets
    /// sampleRate = The sampling rate, in samples per second, of the given audio sequence slice
    /// nChannels = The number of channels in the given audio sequence slice
    /// Returns: An array of frames at which an onset occurs in a given piece table,
    ///          with frames given locally
    static Onset[] getOnsetsLinkedChannels(ref const(OnsetParams) params,
                                           AudioSequence.AudioPieceTable pieceTable,
                                           nframes_t sampleRate,
                                           channels_t nChannels,
                                           ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          pieceTable,
                          sampleRate,
                          nChannels,
                          0,
                          true,
                          progressCallback);
    }

    /// Compute the onsets for a single channel of a given audio sequence slice.
    /// Params:
    /// params = Parameter structure for the onset detection algorithm
    /// pieceTable = The audio sequence slice for which to detect onsets
    /// sampleRate = The sampling rate, in samples per second, of the given audio sequence slice
    /// nChannels = The number of channels in the given audio sequence slice
    /// channelIndex = The channel for which to detect onsets
    /// Returns: An array of frames at which an onset occurs in a given piece table, with frames given locally
    static Onset[] getOnsetsSingleChannel(ref const(OnsetParams) params,
                                          AudioSequence.AudioPieceTable pieceTable,
                                          nframes_t sampleRate,
                                          channels_t nChannels,
                                          channels_t channelIndex,
                                          ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          pieceTable,
                          sampleRate,
                          nChannels,
                          channelIndex,
                          false,
                          progressCallback);
    }

    /// Stretches the subregion between the given local indices according to stretchRatio
    /// Returns: The local end frame of the stretch
    nframes_t stretchSubregion(nframes_t localStartFrame, nframes_t localEndFrame, double stretchRatio) {
        immutable channels_t nChannels = this.nChannels;

        uint subregionLength = cast(uint)(localEndFrame - localStartFrame);
        ScopedArray!(float[][]) subregionChannels = new float[][](nChannels);
        ScopedArray!(float*[]) subregionPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] subregion = new float[](subregionLength);
            subregionChannels[i] = subregion;
            subregionPtr[i] = subregion.ptr;
        }

        foreach(channels_t channelIndex, channel; subregionChannels) {
            foreach(i, ref sample; channel) {
                sample = _audioSlice[(localStartFrame + i) * this.nChannels + channelIndex];
            }
        }

        uint subregionOutputLength = cast(uint)(subregionLength * stretchRatio);
        ScopedArray!(float[][]) subregionOutputChannels = new float[][](nChannels);
        ScopedArray!(float*[]) subregionOutputPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] subregionOutput = new float[](subregionOutputLength);
            subregionOutputChannels[i] = subregionOutput;
            subregionOutputPtr[i] = subregionOutput.ptr;
        }

        RubberBandState rState = rubberband_new(sampleRate,
                                                nChannels,
                                                RubberBandOption.RubberBandOptionProcessOffline,
                                                stretchRatio,
                                                1.0);
        rubberband_set_max_process_size(rState, subregionLength);
        rubberband_set_expected_input_duration(rState, subregionLength);
        rubberband_study(rState, subregionPtr.ptr, subregionLength, 1);
        rubberband_process(rState, subregionPtr.ptr, subregionLength, 1);
        while(rubberband_available(rState) < subregionOutputLength) {}
        rubberband_retrieve(rState, subregionOutputPtr.ptr, subregionOutputLength);
        rubberband_delete(rState);

        sample_t[] subregionOutput = new sample_t[](subregionOutputLength * nChannels);
        foreach(channels_t channelIndex, channel; subregionOutputChannels) {
            foreach(i, sample; channel) {
                subregionOutput[i * nChannels + channelIndex] = sample;
            }
        }

        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(subregionOutput), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);

        return localStartFrame + subregionOutputLength;
    }

    /// Stretch the audio between `localStartFrame` and `localEndFrame`,
    /// such that the frame at `localSrcFrame` becomes the frame at `localDestFrame`.
    /// A call to this function should correspond to onset move operation.
    /// If linkChannels is `true`, perform the stretch for all channels simultaneously, ignoring `channelIndex`.
    /// Otherwise, perform the stretch only for the channel given by `singleChannelIndex`.
    /// The `leftSource` and `rightSource` parameters should correspond to the `leftSource` and `rightSource`
    /// members of the onset that is being moved.
    /// These members ensure that successive three-point stretche operations are not computed from previously
    /// stretched audio data, thereby avoiding any unnessary loss in sound quality.
    void stretchThreePoint(nframes_t localStartFrame,
                           nframes_t localSrcFrame,
                           nframes_t localDestFrame,
                           nframes_t localEndFrame,
                           bool linkChannels = false,
                           channels_t singleChannelIndex = 0,
                           AudioSequence.AudioPieceTable leftSource = AudioSequence.AudioPieceTable.init,
                           AudioSequence.AudioPieceTable rightSource = AudioSequence.AudioPieceTable.init) {
        immutable channels_t stretchNChannels = linkChannels ? nChannels : 1;
        immutable bool useSource = leftSource && rightSource;

        immutable auto removeStartIndex = clamp((_sliceStartFrame + localStartFrame) * nChannels,
                                                0,
                                                _audioSeq.length);
        immutable auto removeEndIndex = clamp((_sliceStartFrame + localEndFrame) * nChannels,
                                              removeStartIndex,
                                              _audioSeq.length);

        immutable double firstScaleFactor = (localSrcFrame > localStartFrame) ?
            (cast(double)(localDestFrame - localStartFrame) /
             cast(double)(useSource ? leftSource.length / nChannels : localSrcFrame - localStartFrame)) : 0;
        immutable double secondScaleFactor = (localEndFrame > localSrcFrame) ?
            (cast(double)(localEndFrame - localDestFrame) /
             cast(double)(useSource ? rightSource.length / nChannels : localEndFrame - localSrcFrame)) : 0;

        if(useSource) {
            localStartFrame = 0;
            localSrcFrame = (localStartFrame < localSrcFrame) ? localSrcFrame - localStartFrame : 0;
            localDestFrame = (localStartFrame < localDestFrame) ? localDestFrame - localStartFrame : 0;
            localEndFrame = (localStartFrame < localEndFrame) ? localEndFrame - localStartFrame : 0;
        }

        uint firstHalfLength = cast(uint)(useSource ?
                                          leftSource.length / nChannels :
                                          localSrcFrame - localStartFrame);
        uint secondHalfLength = cast(uint)(useSource ?
                                           rightSource.length / nChannels :
                                           localEndFrame - localSrcFrame);
        ScopedArray!(float[][]) firstHalfChannels = new float[][](stretchNChannels);
        ScopedArray!(float[][]) secondHalfChannels = new float[][](stretchNChannels);
        ScopedArray!(float*[]) firstHalfPtr = new float*[](stretchNChannels);
        ScopedArray!(float*[]) secondHalfPtr = new float*[](stretchNChannels);
        for(auto i = 0; i < stretchNChannels; ++i) {
            float[] firstHalf = new float[](firstHalfLength);
            float[] secondHalf = new float[](secondHalfLength);
            firstHalfChannels[i] = firstHalf;
            secondHalfChannels[i] = secondHalf;
            firstHalfPtr[i] = firstHalf.ptr;
            secondHalfPtr[i] = secondHalf.ptr;
        }

        if(useSource) {
            if(linkChannels) {
                foreach(channels_t channelIndex, channel; firstHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = leftSource[i * nChannels + channelIndex];
                    }
                }
                foreach(channels_t channelIndex, channel; secondHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = rightSource[i * nChannels + channelIndex];
                    }
                }
            }
            else {
                foreach(i, ref sample; firstHalfChannels[0]) {
                    sample = leftSource[i * nChannels + singleChannelIndex];
                }
                foreach(i, ref sample; secondHalfChannels[0]) {
                    sample = rightSource[i * nChannels + singleChannelIndex];
                }
            }
        }
        else {
            if(linkChannels) {
                foreach(channels_t channelIndex, channel; firstHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = _audioSlice[(localStartFrame + i) * nChannels + channelIndex];
                    }
                }
                foreach(channels_t channelIndex, channel; secondHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = _audioSlice[(localSrcFrame + i) * nChannels + channelIndex];
                    }
                }
            }
            else {
                foreach(i, ref sample; firstHalfChannels[0]) {
                    sample = _audioSlice[(localStartFrame + i) * nChannels + singleChannelIndex];
                }
                foreach(i, ref sample; secondHalfChannels[0]) {
                    sample = _audioSlice[(localSrcFrame + i) * nChannels + singleChannelIndex];
                }
            }
        }

        uint firstHalfOutputLength = cast(uint)(firstHalfLength * firstScaleFactor);
        uint secondHalfOutputLength = cast(uint)(secondHalfLength * secondScaleFactor);
        ScopedArray!(float[][]) firstHalfOutputChannels = new float[][](stretchNChannels);
        ScopedArray!(float[][]) secondHalfOutputChannels = new float[][](stretchNChannels);
        ScopedArray!(float*[]) firstHalfOutputPtr = new float*[](stretchNChannels);
        ScopedArray!(float*[]) secondHalfOutputPtr = new float*[](stretchNChannels);
        for(auto i = 0; i < stretchNChannels; ++i) {
            float[] firstHalfOutput = new float[](firstHalfOutputLength);
            float[] secondHalfOutput = new float[](secondHalfOutputLength);
            firstHalfOutputChannels[i] = firstHalfOutput;
            secondHalfOutputChannels[i] = secondHalfOutput;
            firstHalfOutputPtr[i] = firstHalfOutput.ptr;
            secondHalfOutputPtr[i] = secondHalfOutput.ptr;
        }

        if(firstScaleFactor > 0) {
            RubberBandState rState = rubberband_new(sampleRate,
                                                    stretchNChannels,
                                                    RubberBandOption.RubberBandOptionProcessOffline,
                                                    firstScaleFactor,
                                                    1.0);
            rubberband_set_max_process_size(rState, firstHalfLength);
            rubberband_set_expected_input_duration(rState, firstHalfLength);
            rubberband_study(rState, firstHalfPtr.ptr, firstHalfLength, 1);
            rubberband_process(rState, firstHalfPtr.ptr, firstHalfLength, 1);
            while(rubberband_available(rState) < firstHalfOutputLength) {}
            rubberband_retrieve(rState, firstHalfOutputPtr.ptr, firstHalfOutputLength);
            rubberband_delete(rState);
        }

        if(secondScaleFactor > 0) {
            RubberBandState rState = rubberband_new(sampleRate,
                                                    stretchNChannels,
                                                    RubberBandOption.RubberBandOptionProcessOffline,
                                                    secondScaleFactor,
                                                    1.0);
            rubberband_set_max_process_size(rState, secondHalfLength);
            rubberband_set_expected_input_duration(rState, secondHalfLength);
            rubberband_study(rState, secondHalfPtr.ptr, secondHalfLength, 1);
            rubberband_process(rState, secondHalfPtr.ptr, secondHalfLength, 1);
            while(rubberband_available(rState) < secondHalfOutputLength) {}
            rubberband_retrieve(rState, secondHalfOutputPtr.ptr, secondHalfOutputLength);
            rubberband_delete(rState);
        }

        sample_t[] outputBuffer = new sample_t[]((firstHalfOutputLength + secondHalfOutputLength) * nChannels);
        if(linkChannels) {
            foreach(channels_t channelIndex, channel; firstHalfOutputChannels) {
                foreach(i, sample; channel) {
                    outputBuffer[i * nChannels + channelIndex] = sample;
                }
            }
            auto secondHalfOffset = firstHalfOutputLength * nChannels;
            foreach(channels_t channelIndex, channel; secondHalfOutputChannels) {
                foreach(i, sample; channel) {
                    outputBuffer[secondHalfOffset + i * nChannels + channelIndex] = sample;
                }
            }
        }
        else {
            auto firstHalfSourceOffset = removeStartIndex;
            foreach(i, sample; firstHalfOutputChannels[0]) {
                for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
                    if(channelIndex == singleChannelIndex) {
                        outputBuffer[i * nChannels + channelIndex] = sample;
                    }
                    else {
                        outputBuffer[i * nChannels + channelIndex] =
                            _audioSeq[firstHalfSourceOffset + i * nChannels + channelIndex];
                    }
                }
            }
            auto secondHalfOutputOffset = firstHalfOutputLength * nChannels;
            auto secondHalfSourceOffset = firstHalfSourceOffset + secondHalfOutputOffset;
            foreach(i, sample; secondHalfOutputChannels[0]) {
                for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
                    if(channelIndex == singleChannelIndex) {
                        outputBuffer[secondHalfOutputOffset + i * nChannels + channelIndex] = sample;
                    }
                    else {
                        outputBuffer[secondHalfOutputOffset + i * nChannels + channelIndex] =
                            _audioSeq[secondHalfSourceOffset + i * nChannels + channelIndex];
                    }
                }
            }
        }

        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(outputBuffer), nChannels)),
                          removeStartIndex, removeEndIndex);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
    }

    /// Adjust the gain, in dBFS, of the subregion from `localStartFrame` to `localEndFrame`
    void gain(nframes_t localStartFrame,
              nframes_t localEndFrame,
              sample_t gainDB,
              GainState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(GainState.gain, 0);
        }

        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        _gainBuffer(audioBuffer, gainDB);

        // write the gain-adjusted buffer to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(GainState.complete, 1);
        }        
    }

    /// Adjust the gain, in dBFS, of the entire region
    void gain(sample_t gainDB, GainState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(GainState.gain, 0);
        }

        sample_t[] audioBuffer = _audioSeq[].toArray();
        _gainBuffer(audioBuffer, gainDB);

        // write the gain-adjusted region to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          0, _audioSeq.length);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(GainState.complete, 1);
        }
    }

    /// Normalize subregion from `localStartFrame` to `localEndFrame` to the given maximum gain, in dBFS
    void normalize(nframes_t localStartFrame,
                   nframes_t localEndFrame,
                   sample_t maxGainDB = 0.1f,
                   NormalizeState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(NormalizeState.normalize, 0);
        }

        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        _normalizeBuffer(audioBuffer, maxGainDB);

        // write the normalized buffer to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(NormalizeState.complete, 1);
        }
    }

    /// Normalize entire region to the given maximum gain, in dBFS
    void normalize(sample_t maxGainDB = -0.1f, NormalizeState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(NormalizeState.normalize, 0);
        }

        sample_t[] audioBuffer = _audioSeq[].toArray();
        _normalizeBuffer(audioBuffer, maxGainDB);

        // write the normalized region to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          0,
                          _audioSeq.length);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(NormalizeState.complete, 1);
        }
    }

    /// Reverse a subregion from `localStartFrame` to `localEndFrame`
    void reverse(nframes_t localStartFrame, nframes_t localEndFrame) {
        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        std.algorithm.reverse(audioBuffer);

        // write the reversed buffer to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
    }

    /// Linearly fade in a subregion from `localStartFrame` to `localEndFrame`
    void fadeIn(nframes_t localStartFrame, nframes_t localEndFrame) {
        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        _fadeInBuffer(audioBuffer);

        // write the faded buffer to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
    }

    /// Linearly fade out a subregion from `localStartFrame` to `localEndFrame`
    void fadeOut(nframes_t localStartFrame, nframes_t localEndFrame) {
        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        _fadeOutBuffer(audioBuffer);

        // write the faded buffer to the audio sequence
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
    }

    /// Static array of all cache binning sizes computed for all waveforms
    alias cacheBinSizes = WaveformCache.cacheBinSizes;

    /// Get the cache index for a specific bin size. This allows any waveform rendering routines
    /// to compute the correct cache index for a given binning size only once,
    /// then subsequently access the correct cache via array indexing
    /// Returns: `null` if the specified binning size was not found in the cache;
    ///          otherwise, returns the cache index corresponding to the specified binning size.
    static Nullable!size_t getCacheIndex(nframes_t binSize) {
        return WaveformCache.getCacheIndex(binSize);
    }

    /// Returns the minimum sample over a given binning size at the relative offset specified by
    /// `sampleOffset`, using the specified cache index to speed up the computation.
    sample_t getMin(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) {
        immutable auto cacheSize = WaveformCache.cacheBinSizes[cacheIndex];
        foreach(piece; _audioSlice.table) {
            immutable auto logicalStart = piece.logicalOffset / nChannels;
            immutable auto logicalEnd = (piece.logicalOffset + piece.length) / nChannels;
            if(sampleOffset * binSize >= logicalStart && sampleOffset * binSize < logicalEnd) {
                return sliceMin(piece.buffer.waveformCache.getWaveformBinned(channelIndex, cacheIndex).minValues
                                [(sampleOffset * binSize - logicalStart) / cacheSize..
                                 ((sampleOffset + 1) * binSize - logicalStart) / cacheSize]);
            }
        }
        return 0;
    }

    /// Returns the maximum sample over a given binning size at the relative offset specified by
    /// `sampleOffset`, using the specified cache index to speed up the computation.
    sample_t getMax(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) {
        immutable auto cacheSize = WaveformCache.cacheBinSizes[cacheIndex];
        foreach(piece; _audioSlice.table) {
            immutable auto logicalStart = piece.logicalOffset / nChannels;
            immutable auto logicalEnd = (piece.logicalOffset + piece.length) / nChannels;
            if(sampleOffset * binSize >= logicalStart && sampleOffset * binSize < logicalEnd) {
                return sliceMax(piece.buffer.waveformCache.getWaveformBinned(channelIndex, cacheIndex).maxValues
                                [(sampleOffset * binSize - logicalStart) / cacheSize ..
                                 ((sampleOffset + 1) * binSize - logicalStart) / cacheSize]);
            }
        }
        return 0;
    }

    /// Returns: The sample value at a given channel and frame, globally indexed
    sample_t getSampleGlobal(channels_t channelIndex, nframes_t frame) @nogc nothrow {
        return frame >= offset ?
            (frame < offset + nframes ? _audioSlice[(frame - offset) * nChannels + channelIndex] : 0) : 0;
    }

    /// Returns: A slice of the internal audio sequence, using local indexes as input
    AudioSequence.AudioPieceTable getSliceLocal(nframes_t localFrameStart, nframes_t localFrameEnd) {
        return _audioSlice[localFrameStart * nChannels .. localFrameEnd * nChannels];
    }

    /// Insert a subregion at a given local offset.
    /// Does nothing if the offset is not within this region.
    void insertLocal(AudioSequence.AudioPieceTable insertSlice, nframes_t localFrameOffset) {
        if(localFrameOffset >= 0 && localFrameOffset < nframes) {
            immutable auto prevNFrames = _audioSeq.nframes;
            _audioSeq.insert(insertSlice, (_sliceStartFrame + localFrameOffset) * nChannels);
            immutable auto newNFrames = _audioSeq.nframes;
            _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
        }
    }

    /// Removes a subregion according to the given local offsets.
    /// Does nothing if the offsets are not within this region.
    void removeLocal(nframes_t localFrameStart, nframes_t localFrameEnd) {
        if(localFrameStart < localFrameEnd &&
           localFrameStart >= 0 && localFrameStart < nframes &&
           localFrameEnd >= 0 && localFrameEnd < nframes) {
            immutable auto prevNFrames = _audioSeq.nframes;
            _audioSeq.remove((_sliceStartFrame + localFrameStart) * nChannels,
                             (_sliceStartFrame + localFrameEnd) * nChannels);
            immutable auto newNFrames = _audioSeq.nframes;
            _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
        }
    }

    /// Undo the last edit operation
    void undoEdit() {
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.undo();
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
    }

    /// Redo the last edit operation
    void redoEdit() {
        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.redo();
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);
    }

    /// Structure for indicating the status of a shrink operation on a region
    static struct ShrinkResult {
        /// Indicates that the shrink operation was successful
        bool success;

        /// The change in number of frames in the region due to the shrink operation
        nframes_t delta;
    }

    /// Modifies (within limits) the start of the region, in terms of global frames.
    /// Returns: A `ShrinkResult` object indicating whether the shrink operation was successful
    ShrinkResult shrinkStart(nframes_t newStartFrameGlobal) {
        // by default, the result should indicate the operation was unsuccessful
        ShrinkResult result;

        if(newStartFrameGlobal < offset) {
            immutable auto delta = offset - newStartFrameGlobal;
            if(delta < _sliceStartFrame) {
                result = ShrinkResult(true, delta);
                _offset -= delta;
                _sliceStartFrame -= delta;
            }
            else if(offset >= _sliceStartFrame) {
                result = ShrinkResult(true, _sliceStartFrame);
                _offset -= _sliceStartFrame;
                _sliceStartFrame = 0;
            }
            else {
                return result;
            }
        }
        else if(newStartFrameGlobal > offset) {
            immutable auto delta = newStartFrameGlobal - offset;
            if(_sliceStartFrame + delta < _sliceEndFrame) {
                result = ShrinkResult(true, delta);
                _offset += delta;
                _sliceStartFrame += delta;
            }
            else if(_sliceStartFrame != _sliceEndFrame) {
                result = ShrinkResult(true, _sliceEndFrame - _sliceStartFrame);
                _offset += _sliceEndFrame - _sliceStartFrame;
                _sliceStartFrame = _sliceEndFrame;
            }
            else {
                return result;
            }
        }
        else {
            return result;
        }

        _updateSlice();
        return result;
    }

    /// Modifies (within limits) the end of the region, in terms of global frames
    /// Returns: A `ShrinkResult` object indicating whether the shrink operation was successful
    ShrinkResult shrinkEnd(nframes_t newEndFrameGlobal) {
        // by default, the result should indicate the operation was unsuccessful
        ShrinkResult result;

        immutable auto endFrameGlobal = _offset + cast(nframes_t)(_audioSlice.length / nChannels);
        if(newEndFrameGlobal < endFrameGlobal) {
            immutable auto delta = endFrameGlobal - newEndFrameGlobal;
            if(_sliceEndFrame > _sliceStartFrame + delta) {
                result = ShrinkResult(true, delta);
                _sliceEndFrame -= delta;
            }
            else if(_sliceEndFrame != _sliceStartFrame) {
                result = ShrinkResult(true, _sliceEndFrame - _sliceStartFrame);
                _sliceEndFrame = _sliceStartFrame;
            }
            else {
                return result;
            }
        }
        else if(newEndFrameGlobal > endFrameGlobal) {
            immutable auto delta = newEndFrameGlobal - endFrameGlobal;
            if(_sliceEndFrame + delta <= _audioSeq.nframes) {
                result = ShrinkResult(true, delta);
                _sliceEndFrame += delta;
                if(timeline !is null) {
                    timeline.resizeIfNecessary(offset + nframes);
                }
            }
            else if(_sliceEndFrame != _audioSeq.nframes) {
                result = ShrinkResult(true, _audioSeq.nframes - _sliceEndFrame);
                _sliceEndFrame = _audioSeq.nframes;
            }
            else {
                return result;
            }
        }
        else {
            return result;
        }

        _updateSlice();
        return result;
    }

    /// Slice start frame, relative to start of sequence
    @property nframes_t sliceStartFrame() const { return _sliceStartFrame; }
    /// ditto
    @property nframes_t sliceStartFrame(nframes_t newSliceStartFrame) {
        _sliceStartFrame = min(newSliceStartFrame, _sliceEndFrame);
        _updateSlice();
        return _sliceStartFrame;
    }

    /// Slice end frame, relative to the start of the sequence
    @property nframes_t sliceEndFrame() const { return _sliceEndFrame; }
    /// ditto
    @property nframes_t sliceEndFrame(nframes_t newSliceEndFrame) {
        _sliceEndFrame = min(newSliceEndFrame, _audioSeq.nframes);
        _updateSlice();
        if(timeline !is null) {
            timeline.resizeIfNecessary(offset + nframes);
        }        
        return _sliceEndFrame;
    }

    /// Reference to the `AudioSequence` object associated with this region.
    /// Note that this region is not guaranteed to be in the list of links of its source audio sequence.
    @property AudioSequence audioSequence() { return _audioSeq; }

    /// Number of frames in the audio data, where 1 frame contains 1 sample for each channel
    @property nframes_t nframes() const @nogc nothrow { return _sliceEndFrame - _sliceStartFrame; }

    /// Sampling rate, in samples per second, of the region
    @property nframes_t sampleRate() const @nogc nothrow { return _sampleRate; }

    /// Number of channels of the region, typically either one or two (mono or stereo)
    @property channels_t nChannels() const @nogc nothrow { return _nChannels; }

    /// The offset, in global frames, of this region from the beginning of the session
    @property nframes_t offset() const @nogc nothrow { return _offset; }
    /// ditto
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }

    /// Indicates whether this region should be silenced when playing
    @property bool mute() const @nogc nothrow { return _mute; }
    /// ditto
    @property bool mute(bool enable) { return (_mute = enable); }

    /// The name of this region. This is typically displayed in the UI.
    @property string name() const { return _name; }
    /// ditto
    @property string name(string newName) { return (_name = newName); }

package:
    /// The arguments are the total number of frames in the audio sequence before/after a modification.
    /// This function adjusts the ending frame of this region's slice accordingly.
    /// It also updates the internal audio slice cache for this region.
    void updateSliceEnd(nframes_t prevNFrames, nframes_t newNFrames) {
        // if more frames were added to the sequence, increase the slice length
        if(newNFrames > prevNFrames) {
            _sliceEndFrame += (newNFrames - prevNFrames);
            if(timeline !is null) {
                timeline.resizeIfNecessary(offset + nframes);
            }
        }
        // if frames were deleted from the sequence, decrease the slice length
        else if(newNFrames < prevNFrames) {
            _sliceEndFrame = (_sliceEndFrame > prevNFrames - newNFrames) ?
                _sliceEndFrame - (prevNFrames - newNFrames) : _sliceStartFrame;
        }

        // update the audio slice cache for this region
        _updateSlice();
    }

    /// Allows a region to resize the timeline
    Timeline timeline;

private:
    /// Adjust the gain of an audio buffer.
    /// Note that this does not send a progress completion message.
    static void _gainBuffer(sample_t[] audioBuffer,
                            sample_t gainDB,
                            GainState.Callback progressCallback = null) {
        sample_t sampleFactor = pow(10, gainDB / 20);
        foreach(i, ref s; audioBuffer) {
            s *= sampleFactor;

            if(progressCallback !is null && i % (audioBuffer.length / GainState.stepsPerStage) == 0) {
                progressCallback(GainState.gain, cast(double)(i) / cast(double)(audioBuffer.length));
            }
        }
    }

    /// Normalize an audio buffer.
    /// Note that this does not send a progress completion message.
    static void _normalizeBuffer(sample_t[] audioBuffer,
                                 sample_t maxGainDB = 0.1f,
                                 NormalizeState.Callback progressCallback = null) {
        // calculate the maximum sample
        sample_t minSample = 1;
        sample_t maxSample = -1;
        foreach(s; audioBuffer) {
            if(s > maxSample) maxSample = s;
            if(s < minSample) minSample = s;
        }
        maxSample = max(abs(minSample), abs(maxSample));

        // normalize the buffer
        sample_t sampleFactor = pow(10, (maxGainDB > 0 ? 0 : maxGainDB) / 20) / maxSample;
        foreach(i, ref s; audioBuffer) {
            s *= sampleFactor;

            if(progressCallback !is null && i % (audioBuffer.length / NormalizeState.stepsPerStage) == 0) {
                progressCallback(NormalizeState.normalize, cast(double)(i) / cast(double)(audioBuffer.length));
            }
        }
    }

    /// Linearly fade in an audio buffer, in-place
    static void _fadeInBuffer(sample_t[] audioBuffer) {
        immutable sample_t bufferLength = cast(sample_t)(audioBuffer.length);
        foreach(i, ref s; audioBuffer) {
            s *= cast(sample_t)(i) / bufferLength;
        }
    }

    /// Linearly fade out an audio buffer, in-place
    static void _fadeOutBuffer(sample_t[] audioBuffer) {
        immutable sample_t bufferLength = cast(sample_t)(audioBuffer.length);
        foreach(i, ref s; audioBuffer) {
            s *= 1 - cast(sample_t)(i) / bufferLength;
        }
    }

    /// Implementation of the onset detection functionality.
    /// Note that `ChannelIndex` is ignored when `linkChannels` is `true`.
    static Onset[] _getOnsets(ref const(OnsetParams) params,
                              AudioSequence.AudioPieceTable pieceTable,
                              nframes_t sampleRate,
                              channels_t nChannels,
                              channels_t channelIndex,
                              bool linkChannels,
                              ComputeOnsetsState.Callback progressCallback = null) {
        immutable nframes_t nframes = cast(nframes_t)(pieceTable.length / nChannels);
        immutable nframes_t framesPerProgressStep =
            (nframes / ComputeOnsetsState.stepsPerStage) * (linkChannels ? 1 : nChannels);
        nframes_t progressStep;

        immutable uint windowSize = 512;
        immutable uint hopSize = 256;
        string onsetMethod = "default";

        auto onsetThreshold = clamp(params.onsetThreshold,
                                    OnsetParams.onsetThresholdMin,
                                    OnsetParams.onsetThresholdMax);
        auto silenceThreshold = clamp(params.silenceThreshold,
                                      OnsetParams.silenceThresholdMin,
                                      OnsetParams.silenceThresholdMax);

        fvec_t* onsetBuffer = new_fvec(1);
        fvec_t* hopBuffer = new_fvec(hopSize);

        auto onsetsApp = appender!(Onset[]);
        aubio_onset_t* o = new_aubio_onset(cast(char*)(onsetMethod.toStringz()), windowSize, hopSize, sampleRate);
        aubio_onset_set_threshold(o, onsetThreshold);
        aubio_onset_set_silence(o, silenceThreshold);
        for(nframes_t samplesRead = 0; samplesRead < nframes; samplesRead += hopSize) {
            uint hopSizeLimit;
            if(((hopSize - 1 + samplesRead) * nChannels + channelIndex) > pieceTable.length) {
                hopSizeLimit = nframes - samplesRead;
                fvec_zeros(hopBuffer);
            }
            else {
                hopSizeLimit = hopSize;
            }

            if(linkChannels) {
                for(auto sample = 0; sample < hopSizeLimit; ++sample) {
                    hopBuffer.data[sample] = 0;
                    for(channels_t i = 0; i < nChannels; ++i) {
                        hopBuffer.data[sample] += pieceTable[(sample + samplesRead) * nChannels + i];
                    }
                }
            }
            else {
                for(auto sample = 0; sample < hopSizeLimit; ++sample) {
                    hopBuffer.data[sample] = pieceTable[(sample + samplesRead) * nChannels + channelIndex];
                }
            }

            aubio_onset_do(o, hopBuffer, onsetBuffer);
            if(onsetBuffer.data[0] != 0) {
                auto lastOnset = aubio_onset_get_last(o);
                if(lastOnset != 0) {
                    if(onsetsApp.data.length > 0) {
                        // compute the right source for the previous onset
                        onsetsApp.data[$ - 1].rightSource =
                            pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels .. lastOnset * nChannels];
                        // append the current onset and its left source
                        onsetsApp.put(Onset(lastOnset, pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels ..
                                                                  lastOnset * nChannels]));
                    }
                    else {
                        // append the leftmost onset
                        onsetsApp.put(Onset(lastOnset, pieceTable[0 .. lastOnset * nChannels]));
                    }
                }
            }
            // compute the right source for the last onset
            if(onsetsApp.data.length > 0) {
                onsetsApp.data[$ - 1].rightSource =
                    pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels .. pieceTable.length];
            }

            if((samplesRead > progressStep) && progressCallback) {
                progressStep = samplesRead + framesPerProgressStep;
                if(linkChannels) {
                    progressCallback(ComputeOnsetsState.computeOnsets,
                                     cast(double)(samplesRead) / cast(double)(nframes));
                }
                else {
                    progressCallback(ComputeOnsetsState.computeOnsets,
                                     cast(double)(samplesRead + nframes * channelIndex) /
                                     cast(double)(nframes * nChannels));
                }
            }
        }
        del_aubio_onset(o);

        del_fvec(onsetBuffer);
        del_fvec(hopBuffer);
        aubio_cleanup();

        return onsetsApp.data;
    }

    /// Recompute the current audio slice from the source audio sequence of this region
    void _updateSlice() {
        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
    }

    /// Wrap the piece table into a reference type.
    /// This is necessary so the region can atomically update its current slice.
    static final class AudioSlice {
        this(AudioSequence.AudioPieceTable pieceTable) {
            slice = pieceTable;
        }

        AudioSequence.AudioPieceTable slice;
    }

    /// Reference to the current audio slice for this region
    AudioSlice _currentAudioSlice;

    /// Get current slice of the audio sequence, based on `_sliceStartFrame` and `_sliceEndFrame`
    @property ref AudioSequence.AudioPieceTable _audioSlice() @nogc nothrow {
        return _currentAudioSlice.slice;
    }

    /// Set current slice of the audio sequence, based on `_sliceStartFrame` and `_sliceEndFrame`.
    /// This operation is guaranteed to be atomic, which should ensure reasonable behavior
    /// when edits occur while the mixer is playing.
    @property ref AudioSequence.AudioPieceTable _audioSlice(T)(T newAudioSlice) {
        atomicStore(*cast(shared)(&_currentAudioSlice), cast(shared)(new AudioSlice(newAudioSlice)));
        return _currentAudioSlice.slice;
    }

    /// Sampling rate, in samples per second, of the audio data for this region
    nframes_t _sampleRate;

    /// Number of channels in the audio data for this region
    channels_t _nChannels;

    /// Source sequence of interleaved audio data, for all channels in this region
    AudioSequence _audioSeq;

    /// Start frame for this region, relative to the start of the sequence
    nframes_t _sliceStartFrame;

    /// End frame for this region, relative to the start of the sequence
    nframes_t _sliceEndFrame;

    /// The offset, in terms of global frames, for the start of this region
    nframes_t _offset;

    /// Flag indicating whether to mute all audio in this region during playback
    bool _mute;

    /// Name for this region
    string _name;
}

/// Find the minimum audio sample value in a given slice
private auto sliceMin(T)(T sourceData) if(isIterable!T && isNumeric!(typeof(sourceData[size_t.init]))) {
    alias BaseSampleType = typeof(sourceData[size_t.init]);
    static if(is(BaseSampleType == const(U), U)) {
        alias SampleType = U;
    }
    else {
        alias SampleType = BaseSampleType;
    }

    SampleType minSample = 1;
    foreach(s; sourceData) {
        if(s < minSample) minSample = s;
    }
    return minSample;
}

/// Find the maximum audio sample value in a given slice
private auto sliceMax(T)(T sourceData) if(isIterable!T && isNumeric!(typeof(sourceData[size_t.init]))) {
    alias BaseSampleType = typeof(sourceData[size_t.init]);
    static if(is(BaseSampleType == const(U), U)) {
        alias SampleType = U;
    }
    else {
        alias SampleType = BaseSampleType;
    }

    SampleType maxSample = -1;
    foreach(s; sourceData) {
        if(s > maxSample) maxSample = s;
    }
    return maxSample;
}

/// Resample audio in the given buffer
sample_t[] convertSampleRate(sample_t[] audioBuffer,
                             channels_t nChannels,
                             nframes_t oldSampleRate,
                             nframes_t newSampleRate,
                             SampleRateConverter sampleRateConverter,
                             LoadState.Callback progressCallback = null) {
    if(newSampleRate != oldSampleRate && newSampleRate > 0) {
        if(progressCallback !is null) {
            progressCallback(LoadState.resample, 0);
        }

        // select the algorithm to use for sample rate conversion
        int converterType;
        final switch(sampleRateConverter) {
            case SampleRateConverter.best:
                converterType = SRC_SINC_BEST_QUALITY;
                break;

            case SampleRateConverter.medium:
                converterType = SRC_SINC_MEDIUM_QUALITY;
                break;

            case SampleRateConverter.fastest:
                converterType = SRC_SINC_FASTEST;
                break;
        }

        // libsamplerate requires floats
        static assert(is(sample_t == float));

        // allocate audio buffers for input/output
        ScopedArray!(float[]) dataIn = audioBuffer;
        float[] dataOut = new float[](audioBuffer.length);

        // compute the parameters for libsamplerate
        double srcRatio = (1.0 * newSampleRate) / oldSampleRate;
        if(!src_is_valid_ratio(srcRatio)) {
            throw new AudioError("Invalid sample rate requested: " ~ to!string(newSampleRate));
        }
        SRC_DATA srcData;
        srcData.data_in = dataIn.ptr;
        srcData.data_out = dataOut.ptr;
        immutable auto nframes = audioBuffer.length / nChannels;
        srcData.input_frames = cast(typeof(srcData.input_frames))(nframes);
        srcData.output_frames = cast(typeof(srcData.output_frames))(ceil(nframes * srcRatio));
        srcData.src_ratio = srcRatio;

        // compute the sample rate conversion
        int error = src_simple(&srcData, converterType, cast(int)(nChannels));
        if(error) {
            throw new AudioError("Sample rate conversion failed: " ~ to!string(src_strerror(error)));
        }
        dataOut.length = cast(size_t)(srcData.output_frames_gen);

        if(progressCallback !is null) {
            progressCallback(LoadState.resample, 1);
        }

        return dataOut;
    }

    return audioBuffer;
}
