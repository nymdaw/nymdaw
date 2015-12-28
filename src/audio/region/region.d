module audio.region.region;

private import std.algorithm;
private import std.conv;
private import std.math;
private import std.path;
private import std.traits;
private import std.typecons;

private import core.atomic;

private import util.scopedarray;

public import audio.onset;
public import audio.progress;
public import audio.region.effects;
public import audio.region.samplerate;
public import audio.region.stretch;
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
    Onset[] computeOnsetsLinkedChannels(ref const(OnsetParams) params,
                                        ComputeOnsetsState.Callback progressCallback = null) {
        return computeOnsets(params,
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
    Onset[] computeOnsetsSingleChannel(ref const(OnsetParams) params,
                                       channels_t channelIndex,
                                       ComputeOnsetsState.Callback progressCallback = null) {
        return computeOnsets(params,
                             _audioSlice,
                             sampleRate,
                             nChannels,
                             channelIndex,
                             false,
                             progressCallback);
    }

    /// Stretches the subregion between the given local indices according to stretchRatio
    /// Returns: The local end frame of the stretch
    nframes_t stretchSubregion(nframes_t localStartFrame, nframes_t localEndFrame, double stretchRatio) {
        sample_t[] subregionOutputBuffer = stretchSubregionBuffer(_audioSlice[localStartFrame * nChannels ..
                                                                              localEndFrame * nChannels],
                                                                  nChannels,
                                                                  sampleRate,
                                                                  stretchRatio);

        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(subregionOutputBuffer), nChannels)),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        immutable auto newNFrames = _audioSeq.nframes;
        _audioSeq.updateSoftLinks(prevNFrames, newNFrames);

        return cast(nframes_t)(localStartFrame + subregionOutputBuffer.length / nChannels);
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
        immutable auto removeStartIndex = clamp((_sliceStartFrame + localStartFrame) * nChannels,
                                                0,
                                                _audioSeq.length);
        immutable auto removeEndIndex = clamp((_sliceStartFrame + localEndFrame) * nChannels,
                                              removeStartIndex,
                                              _audioSeq.length);

        sample_t[] subregionOutputBuffer = stretchThreePointBuffer(_audioSeq,
                                                                   _audioSlice,
                                                                   removeStartIndex,
                                                                   nChannels,
                                                                   sampleRate,
                                                                   localStartFrame,
                                                                   localSrcFrame,
                                                                   localDestFrame,
                                                                   localEndFrame,
                                                                   linkChannels,
                                                                   singleChannelIndex,
                                                                   leftSource,
                                                                   rightSource);

        immutable auto prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(cast(immutable)(AudioSegment(cast(immutable)(subregionOutputBuffer), nChannels)),
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
        gainBuffer(audioBuffer, gainDB);

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
        gainBuffer(audioBuffer, gainDB);

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
        normalizeBuffer(audioBuffer, maxGainDB);

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
        normalizeBuffer(audioBuffer, maxGainDB);

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
        fadeInBuffer(audioBuffer);

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
        fadeOutBuffer(audioBuffer);

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

    /// Returns: A slice of the internal audio sequence, using local indices as input
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
