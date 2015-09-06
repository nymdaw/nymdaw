/// Collection of classes implementing audio sequences and audio regions

module audio.region;

private import std.algorithm;
private import std.container.dlist;
private import std.conv;
private import std.math;
private import std.path;
private import std.range;
private import std.string;
private import std.traits;
private import std.typecons;

private import core.atomic;
private import core.sync.mutex;

private import aubio;
private import rubberband;
private import samplerate;
private import sndfile;

private import util.progress;
private import util.scopedarray;
private import util.sequence;

public import audio.types;

/// Progress state for importing audio files from disk
alias LoadState = ProgressState!(StageDesc("read", "Loading file"),
                                 StageDesc("resample", "Resampling"),
                                 StageDesc("computeOverview", "Computing overview"));

/// Progress state for computing audio onsets for a region
alias ComputeOnsetsState = ProgressState!(StageDesc("computeOnsets", "Computing onsets"));

/// Progress state for adjusting the gain of a region or slice of a region
alias GainState = ProgressState!(StageDesc("gain", "Adjusting gain"));

/// Progress state for normalizing a region or a slice of a region
alias NormalizeState = ProgressState!(StageDesc("normalize", "Normalizing"));

/// Progress state for exporting data to a file on disk
alias SaveState = ProgressState!(StageDesc("write", "Writing file"));

/// A wrapper structure around a buffer of raw, interleaved audio data.
/// Stores the audio data, the number of channels, and its corresponding waveform cache.
struct AudioSegment {
    /// Initialize this segment and compute the waveform cache
    this(sample_t[] audioBuffer, channels_t nChannels) {
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
    AudioSegment opSlice(size_t startIndex, size_t endIndex) {
        return AudioSegment(audioBuffer[startIndex .. endIndex],
                            nChannels,
                            waveformCache[startIndex / nChannels .. endIndex / nChannels]);
    }

    /// Raw, interleaved audio data
    sample_t[] audioBuffer;

    /// The number of channels in the audio buffer
    channels_t nChannels;

    /// The waveform cache corresponding to the audio buffer
    WaveformCache waveformCache;

private:
    /// This copy constructor should only be used by this structure's implementation.
    this(sample_t[] audioBuffer, channels_t nChannels, WaveformCache waveformCache) {
        this.audioBuffer = audioBuffer;
        this.nChannels = nChannels;
        this.waveformCache = waveformCache;
    }
}

/// A wrapper around a generic sequence, specific to audio regions.
/// Stores a list of registered region "links", which are typically referred to as "soft copies" in the UI.
/// This allows edits to a sequence to be immediatley reflected in all regions "linked" to the that sequence.
final class AudioSequence {
public:
    /// Polymorphic base class for implementing links
    static class Link {
        this(Region region) {
            this.region = region;
        }

        string name() {
            return region.name;
        }

        /// The region object associated with this link
        Region region;
    }

    /// Params:
    /// originalBuffer = Raw, interleaved audio data from which to initialize this sequence
    /// sampleRate = The sampling rate, in samples per second, of the audio data
    /// nChannels = The number of channels in the audio data
    /// name = The name of sequence. This is ypically the name of the file from which the audio data was read.
    this(AudioSegment originalBuffer, nframes_t sampleRate, channels_t nChannels, string name) {
        sequence = new Sequence!(AudioSegment)(originalBuffer);

        _mutex = new Mutex;

        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _name = name;
    }

    /// Copy constructor for creating a hard copy based on the current state of this sequence
    this(AudioSequence other) {
        this(AudioSegment(other.sequence[].toArray(), other.nChannels),
             other.sampleRate, other.nChannels, other.name ~ " (copy)");
    }

    /// Load an audio file and create a new sequence from its data
    /// Params:
    /// fileName = The file (including its path on disk) from which to load audio data
    /// sampleRate = The smapling rate of the current session
    /// resampleCallback = A delegate that will be called in the case that the
    ///                    audio file's sampling rate is not the same as that of the current session
    static AudioSequence fromFile(string fileName,
                                  nframes_t sampleRate,
                                  Nullable!SampleRateConverter
                                  delegate(nframes_t originalSampleRate, nframes_t newSampleRate)
                                  resampleCallback = null,
                                  LoadState.Callback progressCallback = null) {
        SNDFILE* infile;
        SF_INFO sfinfo;

        if(progressCallback !is null) {
            if(!progressCallback(LoadState.read, 0)) {
                return null;
            }
        }

        // attempt to open the given file
        infile = sf_open(fileName.toStringz(), SFM_READ, &sfinfo);
        if(!infile) {
            if(progressCallback !is null) {
                progressCallback(LoadState.complete, 0);
            }
            return null;
        }

        // close the file when leaving the current scope
        scope(exit) sf_close(infile);

        // get audio file parameters
        immutable nframes_t originalSampleRate = cast(nframes_t)(sfinfo.samplerate);
        immutable channels_t nChannels = cast(channels_t)(sfinfo.channels);

        // determine if the audio should be resampled
        Nullable!SampleRateConverter sampleRateConverter;
        if(sampleRate != originalSampleRate) {
            if(resampleCallback !is null) {
                sampleRateConverter = resampleCallback(originalSampleRate, sampleRate);
            }
            else {
                // resample by default
                sampleRateConverter = SampleRateConverter.init;
            }
        }

        // allocate contiguous audio buffer
        sample_t[] audioBuffer = new sample_t[](cast(size_t)(sfinfo.frames * sfinfo.channels));

        // read the file into the audio buffer
        sf_count_t readTotal;
        sf_count_t readCount;
        do {
            sf_count_t readRequest = cast(sf_count_t)(audioBuffer.length >= LoadState.stepsPerStage ?
                                                      audioBuffer.length / LoadState.stepsPerStage :
                                                      audioBuffer.length);
            readRequest -= readRequest % sfinfo.channels;

            static if(is(sample_t == float)) {
                readCount = sf_read_float(infile, audioBuffer.ptr + readTotal, readRequest);
            }
            else if(is(sample_t == double)) {
                readCount = sf_read_double(infile, audioBuffer.ptr + readTotal, readRequest);
            }
            else {
                static assert(0);
            }

            readTotal += readCount;

            if(progressCallback !is null) {
                if(!progressCallback(LoadState.read, cast(double)(readTotal) / cast(double)(audioBuffer.length))) {
                    return null;
                }
            }
        }
        while(readCount && readTotal < audioBuffer.length);

        // resample, if necessary
        if(!sampleRateConverter.isNull()) {
            audioBuffer = convertSampleRate(audioBuffer,
                                            nChannels,
                                            originalSampleRate,
                                            sampleRate,
                                            sampleRateConverter,
                                            progressCallback);
        }

        // construct the new sequence
        if(progressCallback !is null) {
            if(!progressCallback(LoadState.computeOverview, 0)) {
                return null;
            }
        }
        auto newSequence = new AudioSequence(AudioSegment(audioBuffer, nChannels),
                                             sampleRate,
                                             nChannels,
                                             baseName(fileName));

        if(progressCallback !is null) {
            if(!progressCallback(LoadState.complete, 1)) {
                newSequence.destroy();
                return null;
            }
        }

        return newSequence;
    }

    /// The sequence implementation
    Sequence!(AudioSegment) sequence;
    alias sequence this;

    /// The piece table type for the sequence implementation
    alias AudioPieceTable = Sequence!(AudioSegment).PieceTable;

    /// Registers a soft link with this sequence
    void addSoftLink(Link link) {
        synchronized(_mutex) {
            _softLinks.insertBack(link);
        }
    }

    /// Removes a soft link that was previoulsy registered with this sequence
    /// Params:
    /// link = The soft link object to remove
    /// equal = An equality predicate for comparing currently registered links with the link to be removed
    void removeSoftLink(T)(T link, bool function(T x, T y) equal = function bool(T x, T y) { return x is y; })
        if(is(T : Link)) {
            synchronized(_mutex) {
                auto softLinkRange = _softLinks[];
                for(; !softLinkRange.empty; softLinkRange.popFront()) {
                    auto front = cast(T)(softLinkRange.front);
                    if(front !is null && equal(front, link)) {
                        _softLinks.linearRemove(take(softLinkRange, 1));
                        break;
                    }
                }
            }
        }

    /// Call this function when a region is edited.
    /// This will reflect the edits to that region to all other regions linked to the
    /// sequence corresponding to the edited region.
    void updateSoftLinks() {
        synchronized(_mutex) {
            auto softLinkRange = _softLinks[];
            for(; !softLinkRange.empty; softLinkRange.popFront()) {
                softLinkRange.front.region.updateSlice();
            }
        }
    }

    /// Returns: A forward range of consisting of all links registered with this sequence.
    @property auto softLinks() { return _softLinks[]; }

    /// The total number of frames in the sequence
    @property nframes_t nframes() { return cast(nframes_t)(sequence.length / nChannels); }

    /// The sampling rate of the sequence, in samples per second
    @property nframes_t sampleRate() const { return _sampleRate; }

    /// The number of interleaved channels in the sequence's audio buffers
    @property channels_t nChannels() const { return _nChannels; }

    /// The name of the sequence. This is typically the name of the file from which the audio data was read.
    @property string name() const { return _name; }

private:
    Mutex _mutex;
    DList!Link _softLinks;

    nframes_t _sampleRate;
    channels_t _nChannels;
    string _name;
}

/// Structure representing an audio onset (i.e., a transient or attack)
struct Onset {
    /// Index representing the relative frame of the onset from the start of the sequence
    nframes_t onsetFrame;

    /// The slice of audio directly to the left of this onset.
    /// It extends from the previous onset (or the beginning of the sequence) to this onset.
    AudioSequence.AudioPieceTable leftSource;

    /// The slice of audio directly to the right of this onset
    /// It extends from this onset to the next onset (or the end of the sequence).
    AudioSequence.AudioPieceTable rightSource;
}

/// Structure containing the parameters for detecting the onsets in an audio sequence
struct OnsetParams {
    enum onsetThresholdMin = 0.0;
    enum onsetThresholdMax = 1.0;
    sample_t onsetThreshold = 0.3;

    enum silenceThresholdMin = -90;
    enum silenceThresholdMax = 0.0;
    sample_t silenceThreshold = -90;
}

/// Sequence class instantiation for representing a series of onsets detected in an audio sequence
alias OnsetSequence = Sequence!(Onset[]);

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
        updateSlice();
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
        newRegion.updateSlice();
        return newRegion;
    }

    /// Create a hard copy by cloning underlying audio sequence of this region
    Region hardCopy() {
        Region newRegion = new Region(new AudioSequence(_audioSeq));
        newRegion._sliceStartFrame = _sliceStartFrame;
        newRegion._sliceEndFrame = _sliceEndFrame;
        newRegion.updateSlice();
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

        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(subregionOutput, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);

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

        auto immutable removeStartIndex = clamp((_sliceStartFrame + localStartFrame) * nChannels,
                                                0,
                                                _audioSeq.length);
        auto immutable removeEndIndex = clamp((_sliceStartFrame + localEndFrame) * nChannels,
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

        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(outputBuffer, nChannels), removeStartIndex, removeEndIndex);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);
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
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);

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
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels), 0, _audioSeq.length);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);

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
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);

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
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels), 0, _audioSeq.length);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(NormalizeState.complete, 1);
        }
    }

    /// Reverse a subregion from `localStartFrame` to `localEndFrame`
    void reverse(nframes_t localStartFrame, nframes_t localEndFrame) {
        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        std.algorithm.reverse(audioBuffer);

        // write the reversed buffer to the audio sequence
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);
    }

    /// Linearly fade in a subregion from `localStartFrame` to `localEndFrame`
    void fadeIn(nframes_t localStartFrame, nframes_t localEndFrame) {
        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        _fadeInBuffer(audioBuffer);

        // write the faded buffer to the audio sequence
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);
    }

    /// Linearly fade out a subregion from `localStartFrame` to `localEndFrame`
    void fadeOut(nframes_t localStartFrame, nframes_t localEndFrame) {
        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray();
        _fadeOutBuffer(audioBuffer);

        // write the faded buffer to the audio sequence
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);
    }

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
        auto immutable cacheSize = WaveformCache.cacheBinSizes[cacheIndex];
        foreach(piece; _audioSlice.table) {
            auto immutable logicalStart = piece.logicalOffset / nChannels;
            auto immutable logicalEnd = (piece.logicalOffset + piece.length) / nChannels;
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
        auto immutable cacheSize = WaveformCache.cacheBinSizes[cacheIndex];
        foreach(piece; _audioSlice.table) {
            auto immutable logicalStart = piece.logicalOffset / nChannels;
            auto immutable logicalEnd = (piece.logicalOffset + piece.length) / nChannels;
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
            auto immutable prevNFrames = _audioSeq.nframes;
            _audioSeq.insert(insertSlice, (_sliceStartFrame + localFrameOffset) * nChannels);
            auto immutable newNFrames = _audioSeq.nframes;
            _sequenceChanged(prevNFrames, newNFrames);
        }
    }

    /// Removes a subregion according to the given local offsets.
    /// Does nothing if the offsets are not within this region.
    void removeLocal(nframes_t localFrameStart, nframes_t localFrameEnd) {
        if(localFrameStart < localFrameEnd &&
           localFrameStart >= 0 && localFrameStart < nframes &&
           localFrameEnd >= 0 && localFrameEnd < nframes) {
            auto immutable prevNFrames = _audioSeq.nframes;
            _audioSeq.remove((_sliceStartFrame + localFrameStart) * nChannels,
                             (_sliceStartFrame + localFrameEnd) * nChannels);
            auto immutable newNFrames = _audioSeq.nframes;
            _sequenceChanged(prevNFrames, newNFrames);
        }
    }

    /// Undo the last edit operation
    void undoEdit() {
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.undo();
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);
    }

    /// Redo the last edit operation
    void redoEdit() {
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.redo();
        auto immutable newNFrames = _audioSeq.nframes;
        _sequenceChanged(prevNFrames, newNFrames);
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
            auto immutable delta = offset - newStartFrameGlobal;
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
            auto immutable delta = newStartFrameGlobal - offset;
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

        updateSlice();
        return result;
    }

    /// Modifies (within limits) the end of the region, in terms of global frames
    /// Returns: A `ShrinkResult` object indicating whether the shrink operation was successful
    ShrinkResult shrinkEnd(nframes_t newEndFrameGlobal) {
        // by default, the result should indicate the operation was unsuccessful
        ShrinkResult result;

        auto immutable endFrameGlobal = _offset + cast(nframes_t)(_audioSlice.length / nChannels);
        if(newEndFrameGlobal < endFrameGlobal) {
            auto immutable delta = endFrameGlobal - newEndFrameGlobal;
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
            auto immutable delta = newEndFrameGlobal - endFrameGlobal;
            if(_sliceEndFrame + delta <= _audioSeq.nframes) {
                result = ShrinkResult(true, delta);
                _sliceEndFrame += delta;
                if(resizeDelegate !is null) {
                    resizeDelegate(offset + nframes);
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

        updateSlice();
        return result;
    }

    /// Slice start frame, relative to start of sequence
    @property nframes_t sliceStartFrame() const { return _sliceStartFrame; }
    /// ditto
    @property nframes_t sliceStartFrame(nframes_t newSliceStartFrame) {
        _sliceStartFrame = min(newSliceStartFrame, _sliceEndFrame);
        updateSlice();
        return _sliceStartFrame;
    }

    /// Slice end frame, relative to the start of the sequence
    @property nframes_t sliceEndFrame() const { return _sliceEndFrame; }
    /// ditto
    @property nframes_t sliceEndFrame(nframes_t newSliceEndFrame) {
        _sliceEndFrame = min(newSliceEndFrame, _audioSeq.nframes);
        updateSlice();
        if(resizeDelegate !is null) {
            resizeDelegate(offset + nframes);
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
    /// Recompute the current audio slice from the source audio sequence of this region
    void updateSlice() {
        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
    }

    /// Delegate for resizing the session, if necessary
    ResizeDelegate resizeDelegate;

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

    /// The arguments are the total number of frames in the audio sequence before/after a modification.
    /// This function adjusts the ending frame of the current slice accordingly.
    /// It also updates all other regions linked to this region's source audio sequence.
    void _sequenceChanged(nframes_t prevNFrames, nframes_t newNFrames) {
        if(newNFrames > prevNFrames) {
            _sliceEndFrame += (newNFrames - prevNFrames);
            if(resizeDelegate !is null) {
                resizeDelegate(offset + nframes);
            }
        }
        else if(newNFrames < prevNFrames) {
            _sliceEndFrame = (_sliceEndFrame > prevNFrames - newNFrames) ?
                _sliceEndFrame - (prevNFrames - newNFrames) : _sliceStartFrame;
        }

        // update all regions that are linked to the audio sequence for this region
        _audioSeq.updateSoftLinks();
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

    /// End frame for this region, relative to the end of the sequence
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

private sample_t[] convertSampleRate(sample_t[] audioBuffer,
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
        auto immutable nframes = audioBuffer.length / nChannels;
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

/// Stores the min/max sample values of a single-channel waveform at a specified binning size
private final class WaveformBinned {
public:
    /// Compute this cache via raw audio data. The cache is for a single channel only.
    /// Params:
    /// binSize = The number of consecutive samples to bin for this cache
    /// audioBuffer = The buffer of audio data to bin
    /// nChannels = The number of interleaved channels in the audio buffer
    /// channelIndex = The channel index to use for this cache
    this(nframes_t binSize, sample_t[] audioBuffer, channels_t nChannels, channels_t channelIndex) {
        assert(binSize > 0);

        _binSize = binSize;
        auto immutable cacheLength = (audioBuffer.length / nChannels) / binSize;
        _minValues = new sample_t[](cacheLength);
        _maxValues = new sample_t[](cacheLength);

        for(auto i = 0, j = 0; i < audioBuffer.length && j < cacheLength; i += binSize * nChannels, ++j) {
            auto audioSlice = audioBuffer[i .. i + binSize * nChannels];
            _minValues[j] = 1;
            _maxValues[j] = -1;

            for(auto k = channelIndex; k < audioSlice.length; k += nChannels) {
                if(audioSlice[k] > _maxValues[j]) _maxValues[j] = audioSlice[k];
                if(audioSlice[k] < _minValues[j]) _minValues[j] = audioSlice[k];
            }
        }
    }

    /// Compute this cache via another cache. The cache is for a single channel only.
    /// Params:
    /// binSize = The number of consecutive samples (with respect to the original audio buffer)
    ///           to bin for this cache.
    /// other = The source cache from which to compute this cache.
    this(nframes_t binSize, in WaveformBinned other) {
        assert(binSize > 0);

        auto immutable binScale = binSize / other.binSize;
        _binSize = binSize;

        immutable size_t srcCount = min(other.minValues.length, other.maxValues.length);
        immutable size_t destCount = srcCount / binScale;
        _minValues = new sample_t[](destCount);
        _maxValues = new sample_t[](destCount);

        for(auto i = 0, j = 0; i < srcCount && j < destCount; i += binScale, ++j) {
            for(auto k = 0; k < binScale; ++k) {
                _minValues[j] = 1;
                _maxValues[j] = -1;
                if(other.minValues[i + k] < _minValues[j]) {
                    _minValues[j] = other.minValues[i + k];
                }
                if(other.maxValues[i + k] > _maxValues[j]) {
                    _maxValues[j] = other.maxValues[i + k];
                }
            }
        }
    }

    /// This constructor is for initializing this cache from a slice of a previously computed cache.
    /// No binning occurs; the newly constructed cache will be identical to the source cache.
    this(nframes_t binSize, sample_t[] minValues, sample_t[] maxValues) {
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
    WaveformBinned opSlice(size_t startIndex, size_t endIndex) {
        return new WaveformBinned(_binSize, _minValues[startIndex .. endIndex], _maxValues[startIndex .. endIndex]);
    }

private:
    nframes_t _binSize;
    sample_t[] _minValues;
    sample_t[] _maxValues;
}

/// Waveform cache object for a region.
/// Stores caches for all channels at various binning sizes for a specific region.
private final class WaveformCache {
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
    this(sample_t[] audioBuffer, channels_t nChannels) {
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
    WaveformCache opSlice(size_t startIndex, size_t endIndex) {
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
