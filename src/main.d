module dseq;

import std.stdio;
import std.conv;
import std.algorithm;
import std.array;
import std.path;
import std.math;
import std.getopt;
import std.string;
import std.format;
import std.random;
import std.container;
import std.uni;
import std.concurrency;
import std.parallelism;
import std.typecons;
import std.traits;
import std.typetuple;

import core.memory;
import core.time;

version(HAVE_JACK) {
    import jack.jack;
}

import sndfile;
import samplerate;
import aubio;
import rubberband;

import gtk.Window;
import gtk.MainWindow;
import gtk.Main;
import gtk.Widget;
import gtk.Box;
import gtk.DrawingArea;
import gtk.Adjustment;
import gtk.Scrollbar;
import gtk.Menu;
import gtk.MenuItem;
import gtk.CheckMenuItem;
import gtk.Dialog;
import gtk.Label;
import gtk.ButtonBox;
import gtk.Button;
import gtk.Scale;
import gtk.FileChooserDialog;
import gtk.MessageDialog;
import gtk.ProgressBar;
import gtk.RadioButton;

import gtkc.gtktypes;

import gdk.Cursor;
import gdk.Display;
import gdk.Event;
import gdk.Keymap;
import gdk.Keysyms;
import gdk.Screen;

import glib.Timeout;
import glib.ListSG;
import glib.Str;
import glib.URI;

import cairo.Context;
import cairo.Pattern;
import cairo.Surface;

import pango.PgCairo;
import pango.PgLayout;
import pango.PgFontDescription;

class AudioError: Exception {
    this(string msg) {
        super(msg);
    }
}

version(HAVE_JACK) {
    alias nframes_t = jack_nframes_t;
    alias sample_t = jack_default_audio_sample_t;
}
else {
    alias nframes_t = uint;
    alias sample_t = float;
}
alias channels_t = uint;
alias ResizeDelegate = bool delegate(nframes_t);

alias pixels_t = int;

struct ScopedArray(T) if (is(T t == U[], U)) {
public:
    alias ArrayType = T;
    ArrayType data;
    alias data this;

    this(ArrayType rhs) {
        data = rhs;
    }

    void opAssign(ArrayType rhs) {
        _destroyData();
        data = rhs;
    }

    ~this() {
        _destroyData();
    }

private:
     template rank(T) {
        static if(is(T t == U[], U)) {
            enum size_t rank = 1 + rank!U;
        }
        else {
            enum size_t rank = 0;
        }
    }

    template destroySubArrays(string S, T) {
        enum element = "element" ~ to!string(rank!T);

        static if(rank!T > 1 && is(T t == U[], U)) {
            enum rec = destroySubArrays!(element, U);
        }
        else {
            enum rec = "";
        }

        enum destroySubArrays = "foreach(" ~ element ~ "; " ~ S ~ ") {" ~ rec ~ element ~ ".destroy(); }";
    }

    void _destroyData() {
        static if(rank!ArrayType > 1) {
            mixin(destroySubArrays!("data", ArrayType));
        }
        data.destroy();
    }
}

class Region {
public:
    struct StageDesc {
        string name;
        string description;
    }

    template isStageDesc(alias T) {
        enum isStageDesc = __traits(isSame, StageDesc, typeof(T));
    }

    struct ProgressState(Stages...) if(allSatisfy!(isStageDesc, Stages)) {
    public:
        mixin("enum Stage : int { " ~ _enumString(Stages) ~ " complete }");
        alias Stage this;
        enum nStages = (EnumMembers!Stage).length - 1;
        static immutable(string[nStages]) stageDescriptions = mixin(_createStageDescList(Stages));

        enum stepsPerStage = 5;

        alias Callback = void delegate(Stage stage, double stageFraction);

        this(Stage stage, double stageFraction) {
            this.stage = stage;
            completionFraction = (stage == complete) ? 1.0 : (stage + stageFraction) / nStages;
        }

        Stage stage;
        double completionFraction;

    private:
        static string _enumString(T...)(T stageDescList) {
            string result;
            foreach(stageDesc; stageDescList) {
                result ~= stageDesc.name ~ ", ";
            }
            return result;
        }
        static string _createStageDescList(T...)(T stageDescList) {
            string result = "[ ";
            foreach(stageDesc; stageDescList) {
                result ~= "\"" ~ stageDesc.description ~ "\", ";
            }
            result ~= " ]";
            return result;
        }
    }

    alias LoadState = ProgressState!(StageDesc("read", "Loading file"),
                                     StageDesc("resample", "Resampling"),
                                     StageDesc("computeOverview", "Computing overview"));
    alias ComputeOnsetsState = ProgressState!(StageDesc("computeOnsets", "Computing onsets"));
    alias NormalizeState = ProgressState!(StageDesc("normalize", "Normalizing"));

    // create a region from a file, leaving the sample rate unaltered
    static Region fromFile(string fileName, nframes_t sampleRate, LoadState.Callback progressCallback = null) {
        SNDFILE* infile;
        SF_INFO sfinfo;

        if(progressCallback) {
            progressCallback(LoadState.read, 0);
        }

        // attempt to open the given file
        infile = sf_open(fileName.toStringz(), SFM_READ, &sfinfo);
        if(!infile) {
            progressCallback(LoadState.complete, 0);
            return null;
        }

        // close the file when leaving this scope
        scope(exit) sf_close(infile);

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

            if(progressCallback) {
                progressCallback(LoadState.read, cast(double)(readTotal) / cast(double)(audioBuffer.length));
            }
        }
        while(readCount && readTotal < audioBuffer.length);

        // construct the region
        auto newRegion = new Region(cast(nframes_t)(sfinfo.samplerate),
                                    cast(channels_t)(sfinfo.channels),
                                    audioBuffer,
                                    baseName(stripExtension(fileName)));

        // resample, if necessary
        newRegion.convertSampleRate(sampleRate, progressCallback);
        newRegion.computeOverview(progressCallback);
        if(progressCallback) {
            progressCallback(LoadState.complete, 1.0);
        }
        return newRegion;
    }

    // reanalyze the entire audio data for this region, in the case of edits
    void computeOverview(LoadState.Callback progressCallback = null) {
        if(progressCallback) {
            progressCallback(LoadState.computeOverview, 0);
        }

        // initialize the cache
        _waveformCacheList = null;
        for(auto c = 0; c < _nChannels; ++c) {
            WaveformCache[] channelCache;
            channelCache ~= new WaveformCache(_cacheBinSizes[0], c);
            foreach(binSize; _cacheBinSizes[1 .. $]) {
                channelCache ~= new WaveformCache(binSize, channelCache[$ - 1]);
            }
            _waveformCacheList ~= channelCache;
        }

        if(progressCallback) {
            progressCallback(LoadState.computeOverview, 1);
        }
    }

    void convertSampleRate(nframes_t newSampleRate, LoadState.Callback progressCallback = null) {
        if(newSampleRate != _sampleRate && newSampleRate > 0) {
            if(progressCallback) {
                progressCallback(LoadState.resample, 0);
            }

            // constant indicating the algorithm to use for sample rate conversion
            enum converter = SRC_SINC_BEST_QUALITY;

            // allocate audio buffers for input/output
            ScopedArray!(float[]) dataIn = new float[](_audioBuffer.length);
            ScopedArray!(float[]) dataOut;

            // libsamplerate requires floats
            static if(is(sample_t == float)) {
                dataIn = _audioBuffer.dup;
                dataOut = _audioBuffer;
            }
            else if(is(sample_t == double)) {
                foreach(i, sample; dataIn) {
                    sample = _audioBuffer[i];
                }
                dataOut = new float[](_audioBuffer.length);
            }
            else {
                static assert(0);
            }

            // compute the parameters for libsamplerate
            double srcRatio = (1.0 * newSampleRate) / _sampleRate;
            if(!src_is_valid_ratio(srcRatio)) {
                throw new AudioError("Invalid sample rate requested: " ~ to!string(newSampleRate));
            }
            SRC_DATA srcData;
            srcData.data_in = dataIn.ptr;
            srcData.data_out = dataOut.ptr;
            srcData.input_frames = cast(typeof(srcData.input_frames))(_nframes);
            srcData.output_frames = cast(typeof(srcData.output_frames))(ceil(nframes * srcRatio));
            srcData.src_ratio = srcRatio;

            // compute the sample rate conversion
            int error = src_simple(&srcData, converter, cast(int)(_nChannels));
            if(error) {
                throw new AudioError("Sample rate conversion failed: " ~ to!string(src_strerror(error)));
            }
            dataOut.length = cast(size_t)(srcData.output_frames_gen);

            // convert the float buffer back to sample_t, if necessary
            static if(is(sample_t == double)) {
                _audioBuffer.length = dataOut.length;
                foreach(i, sample; dataOut) {
                    _audioBuffer[i] = sample;
                }
            }

            if(progressCallback) {
                progressCallback(LoadState.resample, 1);
            }
        }
    }

    struct OnsetParams {
        enum onsetThresholdMin = 0.0;
        enum onsetThresholdMax = 1.0;
        sample_t onsetThreshold = 0.3;

        enum silenceThresholdMin = -90;
        enum silenceThresholdMax = 0.0;
        sample_t silenceThreshold = -90;
    }

    // returns an array of frames at which an onset occurs, with frames given locally for this region
    // all channels are summed before computing onsets
    nframes_t[] getOnsetsLinkedChannels(ref const(OnsetParams) params,
                                        ComputeOnsetsState.Callback progressCallback = null) const {
        return _getOnsets(params, true, 0, progressCallback);
    }

    // returns an array of frames at which an onset occurs, with frames given locally for this region
    nframes_t[] getOnsetsSingleChannel(ref const(OnsetParams) params,
                                       channels_t channelIndex,
                                       ComputeOnsetsState.Callback progressCallback = null) const {
        return _getOnsets(params, false, channelIndex, progressCallback);
    }

    // stretches the subregion between the given global indices according to stretchRatio
    // note that this function does not recompute the overview
    void stretchSubregion(nframes_t globalStartFrame, ref nframes_t globalEndFrame, double stretchRatio) {
        immutable(channels_t) nChannels = this.nChannels;
        immutable(nframes_t) localStartFrame = globalStartFrame - offset;

        uint subregionLength = cast(uint)(globalEndFrame - globalStartFrame);
        ScopedArray!(float[][]) subregionChannels = new float[][](nChannels);
        ScopedArray!(float*[]) subregionPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] subregion = new float[](subregionLength);
            subregionChannels[i] = subregion;
            subregionPtr[i] = subregion.ptr;
        }

        foreach(channels_t channelIndex, channel; subregionChannels) {
            foreach(i, ref sample; channel) {
                sample = _audioBuffer[(localStartFrame + i) * this.nChannels + channelIndex];
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

        nframes_t newSubregionEndFrame = globalStartFrame + subregionOutputLength;
        long sizeDelta =
            (cast(long)(subregionOutputLength) - cast(long)(subregionLength)) * cast(long)(nChannels);
        sample_t[] oldAudioBuffer = _audioBuffer;
        sample_t[] newAudioBuffer = new sample_t[](oldAudioBuffer.length + sizeDelta);
        newAudioBuffer[0 .. localStartFrame * nChannels] = oldAudioBuffer[0 .. localStartFrame * nChannels];
        foreach(channels_t channelIndex, channel; subregionOutputChannels) {
            foreach(i, sample; channel) {
                newAudioBuffer[(localStartFrame + i) * this.nChannels + channelIndex] = sample;
            }
        }
        newAudioBuffer[(newSubregionEndFrame - offset) * nChannels .. $] =
            oldAudioBuffer[(globalEndFrame - offset) * nChannels .. $];
        _audioBuffer = newAudioBuffer;
        oldAudioBuffer.destroy();
        _nframes = cast(nframes_t)(newAudioBuffer.length / nChannels);

        globalEndFrame = newSubregionEndFrame;
        if(resizeDelegate !is null) {
            resizeDelegate(offset + nframes);
        }
    }

    // stretch the audio such that the frame at globalSrcFrame becomes the frame at globalDestFrame
    // if linkChannels is true, perform the stretch for all channels simultaneously, ignoring channelIndex
    void stretchThreePoint(nframes_t globalStartFrame,
                           nframes_t globalSrcFrame,
                           nframes_t globalDestFrame,
                           nframes_t globalEndFrame,
                           bool linkChannels,
                           channels_t singleChannelIndex = 0) {
        immutable(channels_t) nChannels = linkChannels ? this.nChannels : 1;

        immutable(double) firstScaleFactor = (globalSrcFrame > globalStartFrame) ?
            (cast(double)(globalDestFrame - globalStartFrame) /
             cast(double)(globalSrcFrame - globalStartFrame)) : 0;
        immutable(double) secondScaleFactor = (globalEndFrame > globalSrcFrame) ?
            (cast(double)(globalEndFrame - globalDestFrame) /
             cast(double)(globalEndFrame - globalSrcFrame)) : 0;

        uint firstHalfLength = cast(uint)(globalSrcFrame - globalStartFrame);
        uint secondHalfLength = cast(uint)(globalEndFrame - globalSrcFrame);
        ScopedArray!(float[][]) firstHalfChannels = new float[][](nChannels);
        ScopedArray!(float[][]) secondHalfChannels = new float[][](nChannels);
        ScopedArray!(float*[]) firstHalfPtr = new float*[](nChannels);
        ScopedArray!(float*[]) secondHalfPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] firstHalf = new float[](firstHalfLength);
            float[] secondHalf = new float[](secondHalfLength);
            firstHalfChannels[i] = firstHalf;
            secondHalfChannels[i] = secondHalf;
            firstHalfPtr[i] = firstHalf.ptr;
            secondHalfPtr[i] = secondHalf.ptr;
        }

        if(linkChannels) {
            foreach(channels_t channelIndex, channel; firstHalfChannels) {
                foreach(i, ref sample; channel) {
                    sample = _audioBuffer[(globalStartFrame + i) * this.nChannels + channelIndex];
                }
            }
            foreach(channels_t channelIndex, channel; secondHalfChannels) {
                foreach(i, ref sample; channel) {
                    sample = _audioBuffer[(globalSrcFrame + i) * this.nChannels + channelIndex];
                }
            }
        }
        else {
            foreach(i, ref sample; firstHalfChannels[0]) {
                sample = _audioBuffer[(globalStartFrame + i) * this.nChannels + singleChannelIndex];
            }
            foreach(i, ref sample; secondHalfChannels[0]) {
                sample = _audioBuffer[(globalSrcFrame + i) * this.nChannels + singleChannelIndex];
            }
        }

        uint firstHalfOutputLength = cast(uint)(firstHalfLength * firstScaleFactor);
        uint secondHalfOutputLength = cast(uint)(secondHalfLength * secondScaleFactor);
        ScopedArray!(float[][]) firstHalfOutputChannels = new float[][](nChannels);
        ScopedArray!(float[][]) secondHalfOutputChannels = new float[][](nChannels);
        ScopedArray!(float*[]) firstHalfOutputPtr = new float*[](nChannels);
        ScopedArray!(float*[]) secondHalfOutputPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] firstHalfOutput = new float[](firstHalfOutputLength);
            float[] secondHalfOutput = new float[](secondHalfOutputLength);
            firstHalfOutputChannels[i] = firstHalfOutput;
            secondHalfOutputChannels[i] = secondHalfOutput;
            firstHalfOutputPtr[i] = firstHalfOutput.ptr;
            secondHalfOutputPtr[i] = secondHalfOutput.ptr;
        }

        RubberBandState rState = rubberband_new(sampleRate,
                                                nChannels,
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

        rState = rubberband_new(sampleRate,
                                nChannels,
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

        if(linkChannels) {
            foreach(channels_t channelIndex, channel; firstHalfOutputChannels) {
                foreach(i, sample; channel) {
                    setSampleLocal(channelIndex, cast(nframes_t)(globalStartFrame + i), sample);
                }
            }
            foreach(channels_t channelIndex, channel; secondHalfOutputChannels) {
                foreach(i, sample; channel) {
                    setSampleLocal(channelIndex, cast(nframes_t)(globalDestFrame + i), sample);
                }
            }
        }
        else {
            foreach(i, sample; firstHalfOutputChannels[0]) {
                setSampleLocal(singleChannelIndex, cast(nframes_t)(globalStartFrame + i), sample);
            }
            foreach(i, sample; secondHalfOutputChannels[0]) {
                setSampleLocal(singleChannelIndex, cast(nframes_t)(globalDestFrame + i), sample);
            }
        }
    }

    // normalize subregion from startFrame to endFrame to the given maximum gain, in dBFS
    void normalize(nframes_t localStartFrame,
                   nframes_t localEndFrame,
                   sample_t maxGain = 0.1f,
                   NormalizeState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(NormalizeState.normalize, 0);
        }

        auto audioSlice = _audioBuffer[localStartFrame * nChannels .. localEndFrame * nChannels];

        sample_t minSample, maxSample;
        _minMax(minSample, maxSample, audioSlice);
        maxSample = max(abs(minSample), abs(maxSample));

        sample_t sampleFactor =  pow(10, (maxGain > 0 ? 0 : maxGain) / 20) / maxSample;
        foreach(i, ref s; audioSlice) {
            s *= sampleFactor;

            if(progressCallback !is null && i % (audioSlice.length / NormalizeState.stepsPerStage) == 0) {
                progressCallback(NormalizeState.normalize, cast(double)(i) / cast(double)(audioSlice.length));
            }
        }

        if(progressCallback !is null) {
            progressCallback(NormalizeState.complete, 1);
        }
    }

    // normalize region to the given maximum gain, in dBFS
    void normalize(sample_t maxGain = -0.1f, NormalizeState.Callback progressCallback = null) {
        normalize(0, nframes, maxGain, progressCallback);
    }

    class WaveformCache {
    public:
        @property nframes_t binSize() const { return _binSize; }
        @property size_t length() const { return _length; }
        @property const(sample_t[]) minValues() const { return _minValues; }
        @property const(sample_t[]) maxValues() const { return _maxValues; }

    private:
        // compute this cache via raw audio data
        this(nframes_t binSize, channels_t channelIndex) {
            assert(binSize > 0);

            _binSize = binSize;
            _length = (_audioBuffer.length / _nChannels) / binSize;
            _minValues = new sample_t[](_length);
            _maxValues = new sample_t[](_length);

            for(auto i = 0, j = 0; i < _audioBuffer.length && j < _length; i += binSize * _nChannels, ++j) {
                _minMaxChannel(channelIndex,
                               _nChannels,
                               _minValues[j],
                               _maxValues[j],
                               _audioBuffer[i .. i + binSize * _nChannels]);
            }
        }

        // compute this cache via another cache
        this(nframes_t binSize, const(WaveformCache) cache) {
            assert(binSize > 0);

            auto binScale = binSize / cache.binSize;
            _binSize = binSize;
            _minValues = new sample_t[](cache.minValues.length / binScale);
            _maxValues = new sample_t[](cache.maxValues.length / binScale);

            immutable(size_t) srcCount = min(cache.minValues.length, cache.maxValues.length);
            immutable(size_t) destCount = srcCount / binScale;
            for(auto i = 0, j = 0; i < srcCount && j < destCount; i += binScale, ++j) {
                for(auto k = 0; k < binScale; ++k) {
                    _minValues[j] = 1;
                    _maxValues[j] = -1;
                    if(cache.minValues[i + k] < _minValues[j]) {
                        _minValues[j] = cache.minValues[i + k];
                    }
                    if(cache.maxValues[i + k] > _maxValues[j]) {
                        _maxValues[j] = cache.maxValues[i + k];
                    }
                }
            }
        }

        nframes_t _binSize;
        size_t _length;
        sample_t[] _minValues;
        sample_t[] _maxValues;
    }

    size_t getCacheIndex(nframes_t binSize) const {
        nframes_t binSizeMatch;
        size_t cacheIndex;
        bool foundIndex;
        foreach(i, s; _cacheBinSizes) {
            if(s <= binSize && binSize % s == 0) {
                foundIndex = true;
                cacheIndex = i;
                binSizeMatch = s;
            }
            else {
                break;
            }
        }
        assert(foundIndex); // TODO, fix this when implementing extremely fine zoom levels
        return cacheIndex;
    }

    sample_t getMin(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) const {
        auto cacheSize = _cacheBinSizes[cacheIndex];
        return _min(_waveformCacheList[channelIndex][cacheIndex].minValues
                    [sampleOffset * (binSize / cacheSize) .. (sampleOffset + 1) * (binSize / cacheSize)]);
    }
    sample_t getMax(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) const {
        auto cacheSize = _cacheBinSizes[cacheIndex];
        return _max(_waveformCacheList[channelIndex][cacheIndex].maxValues
                    [sampleOffset * (binSize / cacheSize) .. (sampleOffset + 1) * (binSize / cacheSize)]);
    }

    // returns the sample value at a given channel and frame, globally indexed
    sample_t getSampleGlobal(channels_t channelIndex, nframes_t frame) const @nogc nothrow {
        return frame >= _offset ?
            (frame < _offset + _nframes ? _audioBuffer[(frame - _offset) * _nChannels + channelIndex] : 0) : 0;
    }

    // modifies the sample for a given channel and frame, locallyIndexed
    void setSampleLocal(channels_t channelIndex, nframes_t frame, sample_t newSample) {
        _audioBuffer[frame * _nChannels + channelIndex] = newSample;
    }

    @property const(sample_t[]) audioBuffer() const { return _audioBuffer; }
    @property nframes_t sampleRate() const @nogc nothrow { return _sampleRate; }
    @property channels_t nChannels() const @nogc nothrow { return _nChannels; }
    @property nframes_t nframes() const @nogc nothrow { return _nframes; }
    @property nframes_t offset() const @nogc nothrow { return _offset; }
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }
    @property bool mute() const @nogc nothrow { return _mute; }
    @property bool mute(bool enable) { return (_mute = enable); }

    @property string name() const { return _name; }
    @property string name(string newName) { return (_name = newName); }

package:
    ResizeDelegate resizeDelegate;

private:
    // this constructor only initializes data members; it does not construct the overview
    this(nframes_t sampleRate,
         channels_t nChannels,
         sample_t[] audioBuffer,
         string name) {
        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _audioBuffer = audioBuffer;
        _nframes = cast(nframes_t)(audioBuffer.length / nChannels);
        _name = name;
    }

    static sample_t _min(const(sample_t[]) sourceData) {
        sample_t minSample = 1;
        foreach(s; sourceData) {
            if(s < minSample) minSample = s;
        }
        return minSample;
    }
    static sample_t _max(const(sample_t[]) sourceData) {
        sample_t maxSample = -1;
        foreach(s; sourceData) {
            if(s > maxSample) maxSample = s;
        }
        return maxSample;
    }

    static void _minMax(out sample_t minSample, out sample_t maxSample, const(sample_t[]) sourceData) {
        minSample = 1;
        maxSample = -1;
        foreach(s; sourceData) {
            if(s > maxSample) maxSample = s;
            if(s < minSample) minSample = s;
        }
    }
    void _minMax(out sample_t minSample, out sample_t maxSample) const {
        _minMax(minSample, maxSample, _audioBuffer);
    }

    static void _minMaxChannel(channels_t channelIndex,
                               channels_t nChannels,
                               out sample_t minSample,
                               out sample_t maxSample,
                               const(sample_t[]) sourceData) {
        minSample = 1;
        maxSample = -1;
        for(auto i = channelIndex; i < sourceData.length; i += nChannels) {
            if(sourceData[i] > maxSample) maxSample = sourceData[i];
            if(sourceData[i] < minSample) minSample = sourceData[i];
        }
    }
    void _minMaxChannel(channels_t channelIndex,
                        out sample_t minSample,
                        out sample_t maxSample) const {
        _minMaxChannel(channelIndex, _nChannels, minSample, maxSample, _audioBuffer);
    }

    // channelIndex is ignored when linkChannels == true
    nframes_t[] _getOnsets(ref const(OnsetParams) params,
                           bool linkChannels,
                           channels_t channelIndex,
                           ComputeOnsetsState.Callback progressCallback = null) const {
        immutable(nframes_t) framesPerProgressStep =
            (nframes / ComputeOnsetsState.stepsPerStage) * (linkChannels ? 1 : nChannels);
        nframes_t progressStep;

        immutable(uint) windowSize = 512;
        immutable(uint) hopSize = 256;
        string onsetMethod = "default";

        auto onsetThreshold = clamp(params.onsetThreshold,
                                    OnsetParams.onsetThresholdMin,
                                    OnsetParams.onsetThresholdMax);
        auto silenceThreshold = clamp(params.silenceThreshold,
                                      OnsetParams.silenceThresholdMin,
                                      OnsetParams.silenceThresholdMax);

        fvec_t* onsetBuffer = new_fvec(1);
        fvec_t* hopBuffer = new_fvec(hopSize);

        nframes_t[] onsets;
        auto app = appender(onsets);
        aubio_onset_t* o = new_aubio_onset(cast(char*)(onsetMethod.toStringz()), windowSize, hopSize, sampleRate);
        aubio_onset_set_threshold(o, onsetThreshold);
        aubio_onset_set_silence(o, silenceThreshold);
        for(nframes_t samplesRead = 0; samplesRead < nframes; samplesRead += hopSize) {
            uint hopSizeLimit;
            if(((hopSize - 1 + samplesRead) * nChannels + channelIndex) > _audioBuffer.length) {
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
                        hopBuffer.data[sample] += _audioBuffer[(sample + samplesRead) * nChannels + i];
                    }
                }
            }
            else {
                for(auto sample = 0; sample < hopSizeLimit; ++sample) {
                    hopBuffer.data[sample] = _audioBuffer[(sample + samplesRead) * nChannels + channelIndex];
                }
            }

            aubio_onset_do(o, hopBuffer, onsetBuffer);
            if(onsetBuffer.data[0] != 0) {
                auto lastOnset = aubio_onset_get_last(o);
                if(lastOnset != 0) {
                    app.put(lastOnset);
                }
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

        return app.data;
    }

    static immutable(nframes_t[]) _cacheBinSizes = [10, 100];
    static assert(_cacheBinSizes.length > 0);

    WaveformCache[][] _waveformCacheList; // indexed as [channel][waveform]

    nframes_t _sampleRate; // sample rate of the audio data
    channels_t _nChannels; // number of channels in the audio data
    sample_t[] _audioBuffer; // raw audio data for all channels
    nframes_t _nframes; // number of frames in the audio data, where 1 frame contains 1 sample for each channel

    nframes_t _offset; // the offset, in frames, for the start of this region
    bool _mute; // flag indicating whether to mute all audio in this region during playback
    string _name; // name for this region
}

class Track {
public:
    void addRegion(Region region) {
        region.resizeDelegate = resizeDelegate;
        _regions ~= region;
        if(resizeDelegate !is null) {
            resizeDelegate(region.offset + region.nframes);
        }
    }

    const(Region[]) regions() const { return _regions; }

package:
    void mixStereoInterleaved(nframes_t offset,
                              nframes_t bufNFrames,
                              channels_t nChannels,
                              sample_t* mixBuf) const @nogc nothrow {
        for(auto i = 0, j = 0; i < bufNFrames; i += nChannels, ++j) {
            foreach(r; _regions) {
                if(!r.mute()) {
                    mixBuf[i] += r.getSampleGlobal(0, offset + j);
                    if(r.nChannels > 1) {
                        mixBuf[i + 1] += r.getSampleGlobal(1, offset + j);
                    }
                }
            }
        }
    }

    void mixStereoNonInterleaved(nframes_t offset,
                                 nframes_t bufNFrames,
                                 sample_t* mixBuf1,
                                 sample_t* mixBuf2) const @nogc nothrow {
        for(auto i = 0; i < bufNFrames; ++i) {
            foreach(r; _regions) {
                if(!r.mute()) {
                    mixBuf1[i] += r.getSampleGlobal(0, offset + i);
                    if(r.nChannels > 1) {
                        mixBuf2[i] += r.getSampleGlobal(1, offset + i);
                    }
                }
            }
        }
    }

    ResizeDelegate resizeDelegate;

private:
    Region[] _regions;
}

abstract class Mixer {
public:
    this(string appName) {
        _appName = appName;

        initializeMixer();
    }

    ~this() {
        cleanupMixer();
    }

    final Track createTrack() {
        Track track = new Track();
        track.resizeDelegate = &resizeIfNecessary;
        _tracks ~= track;
        return track;
    }

    final bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    @property nframes_t sampleRate();

    @property final string appName() const @nogc nothrow {
        return _appName;
    }
    @property final nframes_t nframes() const @nogc nothrow {
        return _nframes;
    }
    @property final nframes_t nframes(nframes_t newNFrames) @nogc nothrow {
        return (_nframes = newNFrames);
    }
    @property final nframes_t lastFrame() const @nogc nothrow {
        return (_nframes > 0 ? nframes - 1 : 0);
    }
    @property final nframes_t transportOffset() const @nogc nothrow {
        return _transportOffset;
    }
    @property final nframes_t transportOffset(nframes_t newOffset) @nogc nothrow {
        disableLoop();
        return (_transportOffset = min(newOffset, nframes));
    }

    @property final bool playing() const @nogc nothrow {
        return _playing;
    }
    final void play() nothrow {
        GC.disable(); // disable garbage collection while playing
        _playing = true;
    }
    final void pause() nothrow {
        GC.enable(); // enable garbage collection while paused
        _playing = false;
    }

    @property final bool looping() const @nogc nothrow {
        return _looping;
    }
    final void enableLoop(nframes_t loopStart, nframes_t loopEnd) @nogc nothrow {
        _looping = true;
        _loopStart = loopStart;
        _loopEnd = loopEnd;
    }
    final void disableLoop() @nogc nothrow {
        _looping = false;
    }

    final void mixStereoInterleaved(nframes_t bufNFrames, channels_t nChannels, sample_t* mixBuf) @nogc nothrow {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(!_transportFinished() && _playing) {
            foreach(t; _tracks) {
                t.mixStereoInterleaved(_transportOffset, bufNFrames, nChannels, mixBuf);
            }

            _transportOffset += bufNFrames / nChannels;

            if(_looping && _transportOffset >= _loopEnd) {
                _transportOffset = _loopStart;
            }
        }
    }

    final void mixStereoNonInterleaved(nframes_t bufNFrames, sample_t* mixBuf1, sample_t* mixBuf2) @nogc nothrow {
        // initialize the buffers to silence
        import core.stdc.string: memset;
        memset(mixBuf1, 0, sample_t.sizeof * bufNFrames);
        memset(mixBuf2, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(!_transportFinished() && _playing) {
            foreach(t; _tracks) {
                t.mixStereoNonInterleaved(_transportOffset, bufNFrames, mixBuf1, mixBuf2);
            }

            _transportOffset += bufNFrames;

            if(_looping && _transportOffset >= _loopEnd) {
                _transportOffset = _loopStart;
            }
        }
    }

protected:
    void initializeMixer();
    void cleanupMixer();

private:
    // stop playing if the transport is at the end of the project
    bool _transportFinished() @nogc nothrow {
        if(_playing && _transportOffset >= lastFrame) {
            _playing = _looping; // don't stop playing if currently looping
            _transportOffset = lastFrame;
            return true;
        }
        return false;
    }

    string _appName;

    Track[] _tracks;
    nframes_t _nframes;
    nframes_t _transportOffset;
    bool _playing;
    bool _looping;
    nframes_t _loopStart;
    nframes_t _loopEnd;
}

version(HAVE_JACK) {

final class JackMixer : Mixer {
public:
    this(string appName) {
        if(_instance !is null) {
            throw new AudioError("Only one JackMixer instance may be constructed per process");
        }
        _instance = this;
        super(appName);
    }

    @property override nframes_t sampleRate() { return jack_get_sample_rate(_client); }

protected:
    override void initializeMixer() {
        _client = jack_client_open(appName.toStringz, JackOptions.JackNoStartServer, null);
        if(!_client) {
            throw new AudioError("jack_client_open failed");
        }

        immutable(char*) mixPort1Name = "StereoMix1";
        immutable(char*) mixPort2Name = "StereoMix2";
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
            jack_get_ports(_client, null, null, JackPortFlags.JackPortIsInput | JackPortFlags.JackPortIsPhysical);
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

    override void cleanupMixer() {
        jack_client_close(_client);
    }

private:
    extern(C) static int _jackProcessCallback(jack_nframes_t bufNFrames, void* arg) @nogc nothrow {
        sample_t* mixBuf1 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort1, bufNFrames));
        sample_t* mixBuf2 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort2, bufNFrames));

        _instance.mixStereoNonInterleaved(bufNFrames, mixBuf1, mixBuf2);

        return 0;
    };

    __gshared static JackMixer _instance; // there should be only one instance per process

    jack_client_t* _client;
    jack_port_t* _mixPort1;
    jack_port_t* _mixPort2;
}

}

version(HAVE_COREAUDIO) {

private extern(C) @nogc nothrow {
    char* coreAudioErrorString();
    bool coreAudioInit(nframes_t sampleRate, channels_t nChannels, AudioCallback callback);
    void coreAudioCleanup();
    alias AudioCallback = void function(nframes_t, channels_t, sample_t*);
}

final class CoreAudioMixer : Mixer {
public:
    enum outputChannels = 2; // default to stereo

    this(string appName, nframes_t sampleRate = 44100) {
        if(_instance !is null) {
            throw new AudioError("Only one CoreAudioMixer instance may be constructed per process");
        }
        _instance = this;
        _sampleRate = sampleRate;
        super(appName);
    }

    ~this() {
        _instance = null;
    }

    @property override nframes_t sampleRate() { return _sampleRate; }

protected:
    override void initializeMixer() {
        if(!coreAudioInit(sampleRate, outputChannels, &_coreAudioProcessCallback)) {
            throw new AudioError(to!string(coreAudioErrorString()));
        }
    }

    override void cleanupMixer() {
        coreAudioCleanup();
    }

private:
    extern(C) static void _coreAudioProcessCallback(nframes_t bufNFrames,
                                                    channels_t nChannels,
                                                    sample_t* mixBuffer) @nogc nothrow {
        _instance.mixStereoInterleaved(bufNFrames, nChannels, mixBuffer);
    }

    __gshared static CoreAudioMixer _instance; // there should be only one instance per process

    nframes_t _sampleRate;
}

}

enum Direction {
    left,
    right
}

struct BoundingBox {
    pixels_t x0, y0, x1, y1;

    // constructor will automatically adjust coordinates such that x0 <= x1 and y0 <= y1
    this(pixels_t x0, pixels_t y0, pixels_t x1, pixels_t y1) {
        if(x0 > x1) swap(x0, x1);
        if(y0 > y1) swap(y0, y1);

        this.x0 = x0;
        this.y0 = y0;
        this.x1 = x1;
        this.y1 = y1;
    }

    bool intersect(ref const(BoundingBox) other) const {
        return !(other.x0 > x1 || other.x1 < x0 || other.y0 > y1 || other.y1 < y0);
    }
}

struct Color {
    double r = 0;
    double g = 0;
    double b = 0;
}

class ErrorDialog : MessageDialog {
public:
    this(Window parentWindow, string errorMessage) {
        super(parentWindow,
              DialogFlags.MODAL,
              MessageType.ERROR,
              ButtonsType.OK,
              "Error: " ~ errorMessage);
    }

    static display(Window parentWindow, string errorMessage) {
        auto dialog = new ErrorDialog(parentWindow, errorMessage);
        dialog.run();
        dialog.destroy();
    }
}

class ArrangeView : Box {
public:
    enum defaultSamplesPerPixel = 500; // default zoom level, in samples per pixel
    enum defaultTrackHeightPixels = 200; // default height in pixels of new tracks in the arrange view
    enum refreshRate = 50; // rate in hertz at which to redraw the view when the transport is playing
    enum mouseOverThreshold = 2; // threshold number of pixels in one direction for mouse over events

    enum Mode {
        arrange,
        editRegion
    }

    enum Action {
        none,
        selectRegion,
        selectSubregion,        
        selectBox,
        moveOnset,
        moveRegion,
        moveTransport,
        createMarker,
        jumpToMarker,
        centerView,
        centerViewStart,
        centerViewEnd,
        moveMarker
    }

    this(string appName, Window parentWindow, Mixer mixer) {
        _parentWindow = parentWindow;
        _mixer = mixer;
        _samplesPerPixel = defaultSamplesPerPixel;

        _canvas = new Canvas();
        _hScroll = new ArrangeHScroll();
        _vScroll = new ArrangeVScroll();

        super(Orientation.HORIZONTAL, 0);
        auto vBox = new Box(Orientation.VERTICAL, 0);
        vBox.packStart(_canvas, true, true, 0);
        vBox.packEnd(_hScroll, false, false, 0);
        packStart(vBox, true, true, 0);
        packEnd(_vScroll, false, false, 0);

        showAll();
    }

    final class ArrangeHScroll : Scrollbar {
    public:
        this() {
            _hAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
            reconfigure();
            _hAdjust.addOnValueChanged(&onHScrollChanged);
            super(Orientation.HORIZONTAL, _hAdjust);
        }

        void onHScrollChanged(Adjustment adjustment) {
            if(_centeredView) {
                _centeredView = false;
            }
            else if(_action == Action.centerView ||
                    _action == Action.centerViewStart ||
                    _action == Action.centerViewEnd) {
                _setAction(Action.none);
            }
            _viewOffset = cast(nframes_t)(adjustment.getValue());
            _canvas.redraw();
        }

        void reconfigure() {
            if(viewMaxSamples > 0) {
                _hAdjust.configure(_viewOffset, // scroll bar position
                                   viewMinSamples, // min position
                                   viewMaxSamples, // max position
                                   stepSamples,
                                   stepSamples * 5,
                                   viewWidthSamples); // scroll bar size
            }
        }
        void update() {
            _hAdjust.setValue(_viewOffset);
        }

        @property nframes_t stepSamples() {
            enum stepDivisor = 20;

            return cast(nframes_t)(viewWidthSamples / stepDivisor);
        }

    private:
        Adjustment _hAdjust;
    }

    final class ArrangeVScroll : Scrollbar {
    public:
        this() {
            _vAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
            reconfigure();
            _vAdjust.addOnValueChanged(&onVScrollChanged);
            super(Orientation.VERTICAL, _vAdjust);
        }

        void onVScrollChanged(Adjustment adjustment) {
            _verticalPixelsOffset = cast(pixels_t)(_vAdjust.getValue());
            _canvas.redraw();
        }

        void reconfigure() {
            // add some padding to the bottom of the visible canvas
            pixels_t totalHeightPixels = _canvas.firstTrackYOffset + (defaultTrackHeightPixels / 2);

            // determine the total height of all tracks in pixels
            foreach(track; _trackViews) {
                totalHeightPixels += track.heightPixels;
            }

            _vAdjust.configure(_verticalPixelsOffset,
                               0,
                               totalHeightPixels,
                               totalHeightPixels / 20,
                               totalHeightPixels / 10,
                               _canvas.viewHeightPixels);
        }

        @property void pixelsOffset(pixels_t newValue) {
            _vAdjust.setValue(cast(pixels_t)(newValue));
        }

        @property pixels_t pixelsOffset() {
            return cast(pixels_t)(_vAdjust.getValue());
        }

        @property pixels_t stepIncrement() {
            return cast(pixels_t)(_vAdjust.getStepIncrement());
        }

    private:
        Adjustment _vAdjust;
    }

    abstract class ArrangeDialog {
    public:
        this(bool okButton = true) {
            _dialog = new Dialog();
            _dialog.setDefaultSize(250, 150);
            _dialog.setTransientFor(_parentWindow);
            auto content = _dialog.getContentArea();
            populate(content);

            if(okButton) {
                content.packEnd(createOKCancelButtons(&onOK, &onCancel), false, false, 10);
            }
            else {
                content.packEnd(createCancelButton(&onCancel), false, false, 10);
            }
            _dialog.showAll();
        }

        static ButtonBox createCancelButton(void delegate(Button) onCancel) {
            auto buttonBox = new ButtonBox(Orientation.HORIZONTAL);
            buttonBox.setLayout(ButtonBoxStyle.END);
            buttonBox.setBorderWidth(5);
            buttonBox.setSpacing(7);
            buttonBox.add(new Button("Cancel", onCancel));
            return buttonBox;
        }
        static ButtonBox createOKCancelButtons(void delegate(Button) onOK, void delegate(Button) onCancel) {
            auto buttonBox = new ButtonBox(Orientation.HORIZONTAL);
            buttonBox.setLayout(ButtonBoxStyle.END);
            buttonBox.setBorderWidth(5);
            buttonBox.setSpacing(7);
            buttonBox.add(new Button("OK", onOK));
            buttonBox.add(new Button("Cancel", onCancel));
            return buttonBox;
        }

    protected:
        final void destroyDialog() {
            _dialog.destroy();
        }

        void populate(Box content);

        void onOK(Button button) {
            destroyDialog();
        }
        void onCancel(Button button) {
            destroyDialog();
        }

    private:

        Dialog _dialog;
    }

    final class OnsetDetectionDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            auto box1 = new Box(Orientation.VERTICAL, 5);
            box1.packStart(new Label("Onset Threshold"), false, false, 0);
            _onsetThresholdAdjustment = new Adjustment(_region.onsetParams.onsetThreshold,
                                                       Region.OnsetParams.onsetThresholdMin,
                                                       Region.OnsetParams.onsetThresholdMax,
                                                       0.01,
                                                       0.1,
                                                       0);
            auto onsetThresholdScale = new Scale(Orientation.HORIZONTAL, _onsetThresholdAdjustment);
            onsetThresholdScale.setDigits(3);
            box1.packStart(onsetThresholdScale, false, false, 0);
            content.packStart(box1, false, false, 10);

            auto box2 = new Box(Orientation.VERTICAL, 5);
            box2.packStart(new Label("Silence Threshold (dbFS)"), false, false, 0);
            _silenceThresholdAdjustment = new Adjustment(_region.onsetParams.silenceThreshold,
                                                         Region.OnsetParams.silenceThresholdMin,
                                                         Region.OnsetParams.silenceThresholdMax,
                                                         0.1,
                                                         1,
                                                         0);
            auto silenceThresholdScale = new Scale(Orientation.HORIZONTAL, _silenceThresholdAdjustment);
            silenceThresholdScale.setDigits(3);
            box2.packStart(silenceThresholdScale, false, false, 0);
            content.packStart(box2, false, false, 10);
        }

        override void onOK(Button button) {
            if(_region !is null) {
                _region.onsetParams.onsetThreshold = _onsetThresholdAdjustment.getValue();
                _region.onsetParams.silenceThreshold = _silenceThresholdAdjustment.getValue();
                destroyDialog();

                _region.computeOnsets();
                _canvas.redraw();
            }
            else {
                destroyDialog();
            }
        }

    private:
        RegionView _region;
        Adjustment _onsetThresholdAdjustment;
        Adjustment _silenceThresholdAdjustment;
    }

    final class StretchSelectionDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            content.packStart(new Label("Stretch factor"), false, false, 0);
            _stretchSelectionFactorAdjustment = new Adjustment(0,
                                                               -10,
                                                               10,
                                                               0.1,
                                                               0.5,
                                                               0);
            auto stretchSelectionRatioScale = new Scale(Orientation.HORIZONTAL, _stretchSelectionFactorAdjustment);
            stretchSelectionRatioScale.setDigits(2);
            content.packStart(stretchSelectionRatioScale, false, false, 10);
        }

        override void onOK(Button button) {
            if(_region !is null) {
                auto stretchRatio = _stretchSelectionFactorAdjustment.getValue();
                if(stretchRatio < 0) {
                    stretchRatio = 1.0 / (-stretchRatio);
                }
                else if(stretchRatio == 0) {
                    stretchRatio = 1;
                }
                destroyDialog();

                _region.region.stretchSubregion(_subregionStartFrame, _subregionEndFrame, stretchRatio);

                _region.region.computeOverview();
                _region.computeOnsets();
                _canvas.redraw();
            }
            else {
                destroyDialog();
            }
        }

    private:
        RegionView _region;
        Adjustment _stretchSelectionFactorAdjustment;
    }

    final class NormalizeDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            _normalizeEntireRegion = new RadioButton(cast(ListSG)(null), "Entire Region");
            _normalizeSelectionOnly = new RadioButton(_normalizeEntireRegion, "Selection Only");
            _normalizeSelectionOnly.setSensitive(_subregionSelected);
            if(_subregionSelected) {
                _normalizeSelectionOnly.setActive(true);
            }
            else {
                _normalizeEntireRegion.setActive(true);
            }

            auto hBox = new Box(Orientation.HORIZONTAL, 10);
            hBox.add(_normalizeEntireRegion);
            hBox.add(_normalizeSelectionOnly);
            content.packStart(hBox, false, false, 10);

            content.packStart(new Label("Normalize gain (dbFS)"), false, false, 0);
            _normalizeGainAdjustment = new Adjustment(-0.1, -20, 0, 0.01, 0.5, 0);
            auto normalizeGainScale = new Scale(Orientation.HORIZONTAL, _normalizeGainAdjustment);
            normalizeGainScale.setDigits(3);
            content.packStart(normalizeGainScale, false, false, 10);
        }

        override void onOK(Button button) {
            bool selectionOnly = _normalizeSelectionOnly.getActive();
            bool entireRegion = _normalizeEntireRegion.getActive();
            destroyDialog();

            if(_region !is null) {
                auto progressCallback = progressTaskCallback!(Region.NormalizeState);
                auto progressTask = progressTask(
                    _region.region.name,
                    delegate void() {
                        if(_subregionSelected && selectionOnly) {
                            _region.region.normalize(_subregionStartFrame - _region.region.offset,
                                                     _subregionEndFrame - _region.region.offset,
                                                     cast(sample_t)(_normalizeGainAdjustment.getValue()),
                                                     progressCallback);
                        }
                        else if(entireRegion) {
                            _region.region.normalize(cast(sample_t)(_normalizeGainAdjustment.getValue()),
                                                     progressCallback);
                        }
                    });
                beginProgressTask!(Region.NormalizeState, DefaultProgressTask)(progressTask);
                _region.region.computeOverview();
                _canvas.redraw();
            }
        }

    private:
        RegionView _region;
        RadioButton _normalizeEntireRegion;
        RadioButton _normalizeSelectionOnly;
        Adjustment _normalizeGainAdjustment;
    }

    class RegionView {
    public:
        enum cornerRadius = 4; // radius of the rounded corners of the region, in pixels
        enum borderWidth = 1; // width of the edges of the region, in pixels
        enum headerHeight = 15; // height of the region's label, in pixels
        enum headerFont = "Arial 10"; // font family and size to use for the region's label

        void drawRegion(ref Scoped!Context cr,
                        pixels_t yOffset,
                        pixels_t heightPixels) {
            _drawRegion(cr, yOffset, heightPixels, region.offset, 1.0);
        }

        void drawRegionMoving(ref Scoped!Context cr,
                              pixels_t yOffset,
                              pixels_t heightPixels) {
            _drawRegion(cr, yOffset, heightPixels, selectedOffset, 0.5);
        }

        void computeOnsetsIndependentChannels() {
            auto progressCallback = progressTaskCallback!(Region.ComputeOnsetsState);
            auto progressTask = progressTask(
                region.name,
                delegate void() {
                    progressCallback(Region.ComputeOnsetsState.computeOnsets, 0);

                    // compute onsets independently for each channel
                    if(_onsets !is null) {
                        _onsets.destroy();
                    }
                    _onsets = new nframes_t[][](region.nChannels);
                    for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                        _onsets[channelIndex] =
                            region.getOnsetsSingleChannel(onsetParams, channelIndex, progressCallback);
                    }

                    progressCallback(Region.ComputeOnsetsState.complete, 1);
                });
            beginProgressTask!(Region.ComputeOnsetsState, DefaultProgressTask)(progressTask);
            _canvas.redraw();
        }

        void computeOnsetsLinkedChannels() {
            auto progressCallback = progressTaskCallback!(Region.ComputeOnsetsState);
            auto progressTask = progressTask(
                region.name,
                delegate void() {
                    progressCallback(Region.ComputeOnsetsState.computeOnsets, 0);
            
                    // compute onsets for summed channels
                    if(region.nChannels > 1) {
                        _onsetsLinked = region.getOnsetsLinkedChannels(onsetParams, progressCallback);
                    }

                    progressCallback(Region.ComputeOnsetsState.complete, 1);
                });
            beginProgressTask!(Region.ComputeOnsetsState, DefaultProgressTask)(progressTask);
            _canvas.redraw();
        }

        void computeOnsets() {
            if(linkChannels) {
                computeOnsetsLinkedChannels();
            }
            else {
                computeOnsetsIndependentChannels();
            }
        }

        // finds the index of any onset between (searchFrame - searchRadius) and (searchFrame + searchRadius)
        // if successful, returns true and stores the index in the searchIndex output argument
        bool getOnset(nframes_t searchFrame,
                      nframes_t searchRadius,
                      out nframes_t foundFrame,
                      out size_t foundIndex,
                      channels_t channelIndex = 0) {
            nframes_t[] onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];

            // recursive binary search helper function
            bool getOnsetRec(nframes_t searchFrame,
                             nframes_t searchRadius,
                             out nframes_t foundFrame,
                             out size_t foundIndex,
                             size_t leftIndex,
                             size_t rightIndex) {

                foundIndex = (leftIndex + rightIndex) / 2;
                if(foundIndex >= onsets.length) return false;

                foundFrame = onsets[foundIndex];
                if(foundFrame >= searchFrame - searchRadius && foundFrame <= searchFrame + searchRadius) {
                    return true;
                }
                else if(leftIndex >= rightIndex) {
                    return false;
                }

                if(foundFrame < searchFrame) {
                    return getOnsetRec(searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       foundIndex + 1,
                                       rightIndex);
                }
                else {
                    return getOnsetRec(searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       leftIndex,
                                       foundIndex - 1);
                }
            }

            return getOnsetRec(searchFrame,
                               searchRadius,
                               foundFrame,
                               foundIndex,
                               0,
                               onsets.length - 1);
        }

        // move a specific onset given by onsetIndex, returns the new onset value (locally indexed for this region)
        nframes_t moveOnset(size_t onsetIndex,
                            nframes_t relativeSamples,
                            Direction direction,
                            channels_t channelIndex = 0) {
            nframes_t[] onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            switch(direction) {
                case Direction.left:
                    nframes_t leftBound = (onsetIndex > 0) ? onsets[onsetIndex - 1] : 0;
                    if(onsets[onsetIndex] > relativeSamples &&
                       onsets[onsetIndex] - relativeSamples > leftBound) {
                        return (onsets[onsetIndex] -= relativeSamples);
                    }
                    else {
                        return (onsets[onsetIndex] = leftBound);
                    }

                case Direction.right:
                    nframes_t rightBound = (onsetIndex < onsets.length - 1) ?
                        onsets[onsetIndex + 1] : region.nframes - 1;
                    if(onsets[onsetIndex] + relativeSamples < rightBound) {
                        return (onsets[onsetIndex] += relativeSamples);
                    }
                    else {
                        return (onsets[onsetIndex] = rightBound);
                    }

                default:
                    break;
            }
            return 0;
        }

        // these functions return onset frames, locally indexed for this region
        nframes_t getPrevOnset(size_t onsetIndex, channels_t channelIndex = 0) const {
            auto onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            return (onsetIndex > 0) ? onsets[onsetIndex - 1] : 0;
        }
        nframes_t getNextOnset(size_t onsetIndex, channels_t channelIndex = 0) const {
            auto onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            return (onsetIndex < onsets.length - 1) ? onsets[onsetIndex + 1] : region.nframes - 1;
        }

        channels_t mouseOverChannel(pixels_t mouseY) const {
            immutable(pixels_t) trackHeight = (boundingBox.y1 - boundingBox.y0) - headerHeight;
            immutable(pixels_t) channelHeight = trackHeight / region.nChannels;
            return clamp((mouseY - (boundingBox.y0 + headerHeight)) / channelHeight, 0, region.nChannels - 1);
        }

        bool selected;
        nframes_t selectedOffset;
        BoundingBox boundingBox;
        Region region;
        Region.OnsetParams onsetParams;

        bool subregionSelected;
        nframes_t subregionStartFrame;
        nframes_t subregionEndFrame;

        @property bool editMode() const { return _editMode; }
        @property bool editMode(bool enable) {
            if(enable) {
                if(linkChannels && _onsetsLinked is null) {
                    computeOnsetsLinkedChannels();
                }
                else if(_onsets is null) {
                    computeOnsetsIndependentChannels();
                }
            }
            return (_editMode = enable);
        }

        @property bool linkChannels() const { return _linkChannels; }
        @property bool linkChannels(bool enable) {
            if(enable) {
                computeOnsetsLinkedChannels();
            }
            else {
                computeOnsetsIndependentChannels();
            }
            return (_linkChannels = enable);
        }

    private:
        this(Region region, Color* color) {
            this.region = region;
            _regionColor = color;
        }

        void _drawRegion(ref Scoped!Context cr,
                         pixels_t yOffset,
                         pixels_t heightPixels,
                         nframes_t regionOffset,
                         double alpha) {
            enum degrees = PI / 180.0;

            cr.save();

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setAntialias(cairo_antialias_t.GOOD);

            // check that this region is in the visible area of the arrange view
            if((regionOffset >= viewOffset && regionOffset < viewOffset + viewWidthSamples) ||
               (regionOffset < viewOffset &&
                (regionOffset + region.nframes >= viewOffset ||
                 regionOffset + region.nframes <= viewOffset + viewWidthSamples))) {
                immutable(pixels_t) xOffset =
                    (viewOffset < regionOffset) ? (regionOffset - viewOffset) / samplesPerPixel : 0;
                pixels_t height = heightPixels;

                // calculate the width, in pixels, of the visible area of the given region
                pixels_t width;
                if(regionOffset >= viewOffset) {
                    // the region begins after the view offset, and ends within the view
                    if(regionOffset + region.nframes <= viewOffset + viewWidthSamples) {
                        width = max(region.nframes / samplesPerPixel, 2 * cornerRadius);
                    }
                    // the region begins after the view offset, and ends past the end of the view
                    else {
                        width = (viewWidthSamples - (regionOffset - viewOffset)) / samplesPerPixel;
                    }
                }
                else if(regionOffset + region.nframes >= viewOffset) {
                    // the region begins before the view offset, and ends within the view
                    if(regionOffset + region.nframes < viewOffset + viewWidthSamples) {
                        width = (regionOffset + region.nframes - viewOffset) / samplesPerPixel;
                    }
                    // the region begins before the view offset, and ends past the end of the view
                    else {
                        width = viewWidthSamples / samplesPerPixel;
                    }
                }
                else {
                    // the region is not visible
                    return;
                }

                // get the bounding box for this region
                boundingBox.x0 = xOffset;
                boundingBox.y0 = yOffset;
                boundingBox.x1 = xOffset + width;
                boundingBox.y1 = yOffset + height;

                // these variables designate whether the left and right endpoints of the given region are visible
                bool lCorners = regionOffset + (cornerRadius * samplesPerPixel) >= viewOffset;
                bool rCorners = (regionOffset + region.nframes) - (cornerRadius * samplesPerPixel) <=
                    viewOffset + viewWidthSamples;

                cr.newSubPath();
                // top left corner
                if(lCorners) {
                    cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                           cornerRadius, 180 * degrees, 270 * degrees);
                }
                else {
                    cr.moveTo(xOffset - borderWidth, yOffset);
                    cr.lineTo(xOffset + width + (rCorners ? -cornerRadius : borderWidth), yOffset);
                }

                // right corners
                if(rCorners) {
                    cr.arc(xOffset + width - cornerRadius, yOffset + cornerRadius,
                           cornerRadius, -90 * degrees, 0 * degrees);
                    cr.arc(xOffset + width - cornerRadius, yOffset + height - cornerRadius, cornerRadius,
                           0 * degrees, 90 * degrees);
                }
                else {
                    cr.lineTo(xOffset + width + borderWidth, yOffset);
                    cr.lineTo(xOffset + width + borderWidth, yOffset + height);
                }

                // bottom left corner
                if(lCorners) {
                    cr.arc(xOffset + cornerRadius, yOffset + height - cornerRadius,
                           cornerRadius, 90 * degrees, 180 * degrees);
                }
                else {
                    cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + height);
                }
                cr.closePath();

                // if the region is muted, save the border path for later rendering operations
                cairo_path_t* borderPath;
                if(region.mute) {
                    borderPath = cr.copyPath();
                }

                // fill the region background with a gradient
                if(yOffset != _prevYOffset) {
                    enum gradientScale1 = 0.80;
                    enum gradientScale2 = 0.65;

                    if(_regionGradient) {
                        _regionGradient.destroy();
                    }
                    _regionGradient = Pattern.createLinear(0, yOffset, 0, yOffset + height);
                    _regionGradient.addColorStopRgba(0,
                                                     _regionColor.r * gradientScale1,
                                                     _regionColor.g * gradientScale1,
                                                     _regionColor.b * gradientScale1,
                                                     alpha);
                    _regionGradient.addColorStopRgba(1,
                                                     _regionColor.r - gradientScale2,
                                                     _regionColor.g - gradientScale2,
                                                     _regionColor.b - gradientScale2,
                                                     alpha);
                }
                _prevYOffset = yOffset;
                cr.setSource(_regionGradient);
                cr.fillPreserve();

                // if this region is in edit mode or selected, highlight the borders and region header
                cr.setLineWidth(borderWidth);
                if(editMode) {
                    cr.setSourceRgba(1.0, 1.0, 0.0, alpha);
                }
                else if(selected) {
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                }
                else {
                    cr.setSourceRgba(0.5, 0.5, 0.5, alpha);
                }
                cr.stroke();
                if(selected) {
                    cr.newSubPath();
                    // left corner
                    if(lCorners) {
                        cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                               cornerRadius, 180 * degrees, 270 * degrees);
                    }
                    else {
                        cr.moveTo(xOffset - borderWidth, yOffset);
                        cr.lineTo(xOffset + width + (rCorners ? -cornerRadius : borderWidth), yOffset);
                    }

                    // right corner
                    if(rCorners) {
                        cr.arc(xOffset + width - cornerRadius, yOffset + cornerRadius,
                               cornerRadius, -90 * degrees, 0 * degrees);
                    }
                    else {
                        cr.lineTo(xOffset + width + borderWidth, yOffset);
                    }

                    // bottom
                    cr.lineTo(xOffset + width + (rCorners ? 0 : borderWidth), yOffset + headerHeight);
                    cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + headerHeight);
                    cr.closePath();
                    cr.fill();
                }

                // draw the region's label
                if(!_headerLabelLayout) {
                    PgFontDescription desc;
                    _headerLabelLayout = PgCairo.createLayout(cr);
                    desc = PgFontDescription.fromString(headerFont);
                    _headerLabelLayout.setFontDescription(desc);
                    desc.free();
                }

                void drawRegionLabel() {
                    if(selected) {
                        enum labelColorScale = 0.5;
                        cr.setSourceRgba(_regionColor.r * labelColorScale,
                                         _regionColor.g * labelColorScale,
                                         _regionColor.b * labelColorScale, alpha);
                    }
                    else {
                        cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    }
                    PgCairo.updateLayout(cr, _headerLabelLayout);
                    PgCairo.showLayout(cr, _headerLabelLayout);
                }

                cr.save();
                enum labelPadding = borderWidth + 1;
                int labelWidth, labelHeight;
                labelWidth += labelPadding;
                _headerLabelLayout.setText(region.mute ? region.name ~ " (muted)" : region.name);
                _headerLabelLayout.getPixelSize(labelWidth, labelHeight);
                if(xOffset == 0 && regionOffset < viewOffset && labelWidth + labelPadding > width) {
                    cr.translate(xOffset - (labelWidth - width), yOffset);
                    drawRegionLabel();
                }
                else if(labelWidth <= width || regionOffset + region.nframes > viewOffset + viewWidthSamples) {
                    cr.translate(xOffset + labelPadding, yOffset);
                    drawRegionLabel();
                }
                cr.restore();

                // compute audio rendering parameters
                height = heightPixels - headerHeight; // height of the area containing the waveform, in pixels
                yOffset += headerHeight; // y-coordinate in pixels where the waveform rendering begins
                // pixelsOffset is the screen-space x-coordinate at which to begin rendering the waveform
                pixels_t pixelsOffset =
                    (viewOffset > regionOffset) ? (viewOffset - regionOffset) / samplesPerPixel : 0;
                pixels_t channelHeight = height / region.nChannels; // height of each channel in pixels

                bool moveOnset;                
                pixels_t onsetPixelsStart,
                    onsetPixelsCenterSrc,
                    onsetPixelsCenterDest,
                    onsetPixelsEnd;
                double firstScaleFactor, secondScaleFactor;
                if(editMode && _editRegion == this && _action == Action.moveOnset) {
                    moveOnset = true;
                    long onsetViewOffset = (viewOffset > regionOffset) ? cast(long)(viewOffset) : 0;
                    long onsetRegionOffset = (viewOffset > regionOffset) ? cast(long)(regionOffset) : 0;
                    long onsetFrameStart, onsetFrameEnd, onsetFrameSrc, onsetFrameDest;

                    onsetFrameStart = onsetRegionOffset + getPrevOnset(_moveOnsetIndex, _moveOnsetChannel);
                    onsetFrameEnd = onsetRegionOffset + getNextOnset(_moveOnsetIndex, _moveOnsetChannel);
                    onsetFrameSrc = onsetRegionOffset + _moveOnsetFrameSrc;
                    onsetFrameDest = onsetRegionOffset + _moveOnsetFrameDest;
                    onsetPixelsStart =
                        cast(pixels_t)((onsetFrameStart - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsCenterSrc =
                        cast(pixels_t)((onsetFrameSrc - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsCenterDest =
                        cast(pixels_t)((onsetFrameDest - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsEnd =
                        cast(pixels_t)((onsetFrameEnd - onsetViewOffset) / samplesPerPixel);
                    firstScaleFactor = (onsetFrameSrc > onsetFrameStart) ?
                        (cast(double)(onsetFrameDest - onsetFrameStart) /
                         cast(double)(onsetFrameSrc - onsetFrameStart)) : 0;
                    secondScaleFactor = (onsetFrameEnd > onsetFrameSrc) ?
                        (cast(double)(onsetFrameEnd - onsetFrameDest) /
                         cast(double)(onsetFrameEnd - onsetFrameSrc)) : 0;
                }

                enum OnsetDrawState { init, firstHalf, secondHalf, complete }
                OnsetDrawState onsetDrawState;

                // draw the region's waveform
                auto cacheIndex = region.getCacheIndex(_zoomStep);
                auto channelYOffset = yOffset + (channelHeight / 2);
                for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                    pixels_t startPixel = (moveOnset && onsetPixelsStart < 0 && firstScaleFactor != 0) ?
                        max(cast(pixels_t)(onsetPixelsStart / firstScaleFactor), onsetPixelsStart) : 0;
                    pixels_t endPixel = (moveOnset && onsetPixelsEnd > width && secondScaleFactor != 0) ?
                        min(cast(pixels_t)((onsetPixelsEnd - width) / secondScaleFactor),
                            onsetPixelsEnd - width) : 0;

                    cr.newSubPath();
                    try {
                        cr.moveTo(xOffset, channelYOffset +
                                  region.getMax(channelIndex,
                                                cacheIndex,
                                                samplesPerPixel,
                                                pixelsOffset + startPixel) * (channelHeight / 2));
                    }
                    catch(RangeError) {
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1 + startPixel; i < width + endPixel; ++i) {                        
                        pixels_t scaledI = i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || linkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(i >= onsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                        goto case;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(i >= onsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                        goto case;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(onsetPixelsStart +
                                                                 (i - onsetPixelsStart) * firstScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(i >= onsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(onsetPixelsCenterDest +
                                                                 (i - onsetPixelsCenterSrc) * secondScaleFactor);

                                    }
                                    break;

                                default:
                                    break;
                            }
                        }
                        try {
                            cr.lineTo(xOffset + scaledI, channelYOffset -
                                      clamp(region.getMax(channelIndex,
                                                          cacheIndex,
                                                          samplesPerPixel,
                                                          pixelsOffset + i), 0, 1) * (channelHeight / 2));
                        }
                        catch(RangeError) {
                        }
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1 - endPixel; i <= width - startPixel; ++i) {
                        pixels_t scaledI = width - i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || linkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(width - i <= onsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                        goto case;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(width - i <= onsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                        goto case;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (onsetPixelsCenterDest +
                                             ((width - i) - onsetPixelsCenterSrc) * secondScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(width - i <= onsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (onsetPixelsStart +
                                             ((width - i) - onsetPixelsStart) * firstScaleFactor);
                                    }
                                    break;

                                default:
                                    break;
                            }
                        }
                        try {
                            cr.lineTo(xOffset + scaledI, channelYOffset -
                                      clamp(region.getMin(channelIndex,
                                                          cacheIndex,
                                                          samplesPerPixel,
                                                          pixelsOffset + width - i), -1, 0) * (channelHeight / 2));
                        }
                        catch(RangeError) {
                        }
                    }
                    cr.closePath();
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    cr.fill();
                    channelYOffset += channelHeight;
                }

                // if the edit mode flag is set, draw the onsets
                if(editMode) {
                    if(linkChannels) {
                        foreach(onset; _onsetsLinked) {
                            if(onset + regionOffset >= viewOffset &&
                               onset + regionOffset < viewOffset + viewWidthSamples) {
                                cr.moveTo(xOffset + onset / samplesPerPixel - pixelsOffset, yOffset);
                                cr.lineTo(xOffset + onset / samplesPerPixel - pixelsOffset, yOffset + height);
                            }
                        }
                    }
                    else {
                        foreach(channelIndex, channel; _onsets) {
                            foreach(onset; channel) {
                                if(onset + regionOffset >= viewOffset &&
                                   onset + regionOffset < viewOffset + viewWidthSamples) {
                                    cr.moveTo(xOffset + onset / samplesPerPixel - pixelsOffset,
                                              yOffset + cast(pixels_t)((channelIndex * channelHeight)));
                                    cr.lineTo(xOffset + onset / samplesPerPixel - pixelsOffset,
                                              yOffset + cast(pixels_t)(((channelIndex + 1) * channelHeight)));
                                }
                            }
                        }
                    }
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.setLineWidth(1.0);
                    cr.stroke();
                }

                // if the region is muted, gray it out
                if(region.mute) {
                    cr.setOperator(cairo_operator_t.OVER);
                    cr.appendPath(borderPath);
                    cr.setSourceRgba(0.5, 0.5, 0.5, 0.6);
                    cr.fill();
                }
            }

            cr.restore();
        }

        bool _editMode;
        bool _linkChannels;

        nframes_t[][] _onsets; // indexed as [channel][onset]
        nframes_t[] _onsetsLinked; // indexed as [onset]

        Color* _regionColor;

        Pattern _regionGradient;
        pixels_t _prevYOffset;
    }

    class TrackView {
    public:
        void addRegion(Region region, nframes_t sampleRate) {
            _track.addRegion(region);

            RegionView regionView = new RegionView(region, &_trackColor);
            _regionViews ~= regionView;
            this.outer._regionViews ~= regionView;

            _hScroll.reconfigure();
            _vScroll.reconfigure();
        }
        void addRegion(Region region) {
            addRegion(region, _mixer.sampleRate);
        }

        void draw(ref Scoped!Context cr, pixels_t yOffset) {
            foreach(regionView; _regionViews) {
                Region r = regionView.region;
                if(_action == Action.moveRegion && regionView.selected) {
                    regionView.drawRegionMoving(cr, yOffset, heightPixels);
                }
                else {
                    regionView.drawRegion(cr, yOffset, heightPixels);
                }
            }
        }

        @property pixels_t heightPixels() const {
            return cast(pixels_t)(max(_baseHeightPixels * _verticalScaleFactor, RegionView.headerHeight));
        }

    private:
        this(Track track, pixels_t heightPixels) {
            _track = track;
            _baseHeightPixels = heightPixels;
            _trackColor = _newTrackColor();
        }

        static Color _newTrackColor() {
            Color color;
            Random gen;
            auto i = uniform(0, 2);
            auto j = uniform(0, 2);
            auto k = uniform(0, 5);

            color.r = (i == 0) ? 1 : 0;
            color.g = (j == 0) ? 1 : 0;
            color.b = (j == 1) ? 1 : 0;
            color.g = (color.g == 0 && k == 0) ? 1 : color.g;
            color.b = (color.b == 0 && k == 1) ? 1 : color.b;

            if(uniform(0, 2)) color.r *= uniform(0.8, 1.0);
            if(uniform(0, 2)) color.g *= uniform(0.8, 1.0);
            if(uniform(0, 2)) color.b *= uniform(0.8, 1.0);

            return color;
        }

        Track _track;
        pixels_t _baseHeightPixels;
        RegionView[] _regionViews;
        Color _trackColor;
    }

    struct Marker {
        nframes_t offset;
        string name;
    }

    TrackView createTrackView() {
        TrackView trackView = new TrackView(_mixer.createTrack(), defaultTrackHeightPixels);
        _trackViews ~= trackView;
        _canvas.redraw();
        return trackView;
    }

    enum progressMessageTimeout = 10.msecs; // TODO delete
    void loadRegionsFromFiles(const(string[]) fileNames) {
        auto progressCallback = progressTaskCallback!(Region.LoadState);
        auto regionTaskList = appender!(DefaultProgressTask[]);
        foreach(fileName; fileNames) {
            auto regionTask = delegate() {
                Region newRegion = Region.fromFile(fileName, _mixer.sampleRate, progressCallback);
                if(newRegion is null) {
                    ErrorDialog.display(_parentWindow, "Could not load file " ~ baseName(fileName));
                }
                else {
                    auto newTrack = createTrackView();
                    newTrack.addRegion(newRegion);
                }
            };
            regionTaskList.put(progressTask(baseName(fileName), regionTask));
        }

        if(regionTaskList.data.length > 0) {
            beginProgressTask!(Region.LoadState, DefaultProgressTask)(regionTaskList.data);
            _canvas.redraw();
        }
    }

    @property nframes_t samplesPerPixel() const { return _samplesPerPixel; }
    @property nframes_t viewOffset() const { return _viewOffset; }
    @property nframes_t viewWidthSamples() { return _canvas.viewWidthPixels * _samplesPerPixel; }

    @property nframes_t viewMinSamples() { return 0; }
    @property nframes_t viewMaxSamples() { return _mixer.lastFrame + viewWidthSamples; }

private:
    enum _zoomStep = 10;
    @property size_t _zoomMultiplier() const {
        if(_samplesPerPixel > 2000) {
            return 20;
        }
        if(_samplesPerPixel > 1000) {
            return 10;
        }
        if(_samplesPerPixel > 700) {
            return 5;
        }
        if(_samplesPerPixel > 400) {
            return 4;
        }
        else if(_samplesPerPixel > 200) {
            return 3;
        }
        else if(_samplesPerPixel > 100) {
            return 2;
        }
        else {
            return 1;
        }
    }

    enum _verticalZoomFactor = 1.2f;
    enum _verticalZoomFactorMax = _verticalZoomFactor * 3;
    enum _verticalZoomFactorMin = _verticalZoomFactor / 10;

    void _createArrangeMenu() {
        _arrangeMenu = new Menu();

        _arrangeMenu.append(new MenuItem(&onImportFile, "Import file..."));

        _arrangeMenu.attachToWidget(this, null);
    }

    void onImportFile(MenuItem menuItem) {
        if(_importFileChooser is null) {
            _importFileChooser = new FileChooserDialog("Import Audio file",
                                                       _parentWindow,
                                                       FileChooserAction.OPEN,
                                                       null,
                                                       null);
            _importFileChooser.setSelectMultiple(true);
        }

        auto fileNames = appender!(string[])();
        auto response = _importFileChooser.run();
        if(response == ResponseType.OK) {
            ListSG fileList = _importFileChooser.getUris();
            for(auto i = 0; i < fileList.length(); ++i) {
                string hostname;
                fileNames.put(URI.filenameFromUri(Str.toString(cast(char*)(fileList.nthData(i))), hostname));
            }
            _importFileChooser.hide();
        }
        else if(response == ResponseType.CANCEL) {
            _importFileChooser.hide();
        }
        else {
            _importFileChooser.destroy();
            _importFileChooser = null;
        }

        loadRegionsFromFiles(fileNames.data);
    }

    // TODO remove this
    Tuple!(Dialog, ProgressBar, Label) _createProgressDialog(bool cancelButton = true) {
        auto progressDialog = new Dialog();
        progressDialog.setDefaultSize(350, 75);
        progressDialog.setTransientFor(_parentWindow);

        auto dialogBox = progressDialog.getContentArea();
        auto progressBar = new ProgressBar();
        progressBar.setFraction(0);
        dialogBox.packStart(progressBar, false, false, 20);

        auto progressLabel = new Label(string.init);
        dialogBox.packStart(progressLabel, false, false, 10);

        if(cancelButton) {
            void onProgressCancel(Button button) {
                progressDialog.response(ResponseType.CANCEL);
            }
            dialogBox.packEnd(ArrangeDialog.createCancelButton(&onProgressCancel), false, false, 10);
        }

        return tuple(progressDialog, progressBar, progressLabel);
    }

    template ProgressTask(Task)
        if(is(Task == void delegate()) ||
           (isPointer!Task && __traits(isSame, TemplateOf!(PointerTarget!Task), std.parallelism.Task)) ||
           __traits(isSame, TemplateOf!Task, std.parallelism.Task)) {
        struct ProgressTask {
            string name;

            static if(is(Task == void delegate())) {
                this(string name, Task task) {
                    this.name = name;
                    this.task = std.parallelism.task!Task(task);
                }

                typeof(std.parallelism.task!Task(delegate void() {})) task;
            }
            else {
                Task task;
            }
        }
    }

    alias DefaultProgressTask = ProgressTask!(void delegate());

    auto progressTask(Task)(string name, Task task) {
        return ProgressTask!Task(name, task);
    }

    auto progressTaskCallback(ProgressState)() if(__traits(isSame, TemplateOf!ProgressState, Region.ProgressState)) {
        Tid callbackTid = thisTid;
        return delegate(ProgressState.Stage stage, double stageFraction) {
            send(callbackTid, ProgressState(stage, stageFraction));
        };
    }

    void beginProgressTask(ProgressState, ProgressTask, bool cancelButton = true)(ProgressTask[] taskList)
        if(__traits(isSame, TemplateOf!ProgressState, Region.ProgressState) &&
           __traits(isSame, TemplateOf!ProgressTask, this.ProgressTask)) {
            enum progressRefreshRate = 10; // in Hz
            enum progressMessageTimeout = 10.msecs;

            auto progressDialog = new Dialog();
            progressDialog.setDefaultSize(400, 75);
            progressDialog.setTransientFor(_parentWindow);

            auto dialogBox = progressDialog.getContentArea();
            auto progressBar = new ProgressBar();
            progressBar.setFraction(0);
            dialogBox.packStart(progressBar, false, false, 20);

            auto progressLabel = new Label(string.init);
            dialogBox.packStart(progressLabel, false, false, 10);

            static if(cancelButton) {
                void onProgressCancel(Button button) {
                    progressDialog.response(ResponseType.CANCEL);
                }
                dialogBox.packEnd(ArrangeDialog.createCancelButton(&onProgressCancel), false, false, 10);
            }

            if(taskList.length > 0) {
                setMaxMailboxSize(thisTid,
                                  Region.LoadState.nStages * Region.LoadState.stepsPerStage,
                                  OnCrowding.ignore);

                size_t currentTaskIndex = 0;
                ProgressTask currentTask = taskList[currentTaskIndex];

                void beginTask(ProgressTask currentTask) {
                    progressDialog.setTitle(currentTask.name);
                    currentTask.task.executeInNewThread();
                }
                beginTask(currentTask);

                static string stageCases() {
                    string result;
                    foreach(stage; __traits(allMembers, ProgressState.Stage)[0 .. $ - 1]) {
                        result ~=
                            "case ProgressState.Stage." ~ cast(string)(stage) ~ ": " ~
                            "progressLabel.setText(ProgressState.stageDescriptions[ProgressState.Stage." ~
                            cast(string)(stage) ~ "] ~ \": \" ~ " ~ "currentTask.name); break;\n";
                    }
                    return result;
                }

                Timeout progressTimeout;
                bool onProgressRefresh() {
                    bool currentTaskComplete;
                    while(receiveTimeout(progressMessageTimeout,
                                         (ProgressState progressState) {
                                             progressBar.setFraction(progressState.completionFraction);

                                             if(currentTask.task.done) {
                                                 currentTaskComplete = true;
                                             }
                                             else {
                                                 final switch(progressState.stage) {
                                                     mixin(stageCases());

                                                     case ProgressState.complete:
                                                         currentTaskComplete = true;
                                                         break;
                                                 }
                                             }
                                         })) {}
                    if(currentTaskComplete) {
                        ++currentTaskIndex;
                        if(currentTaskIndex < taskList.length) {
                            currentTask = taskList[currentTaskIndex];
                            beginTask(currentTask);
                        }
                        else {
                            if(progressDialog.getWidgetStruct() !is null) {
                                progressDialog.response(ResponseType.ACCEPT);
                            }
                            progressTimeout.destroy();
                        }
                    }

                    return true;
                }
                progressTimeout = new Timeout(cast(uint)(1.0 / progressRefreshRate * 1000),
                                              &onProgressRefresh,
                                              false);

                progressDialog.showAll();
                progressDialog.run();
            }

            if(progressDialog.getWidgetStruct() !is null) {
                progressDialog.destroy();
            }
        }

    void beginProgressTask(ProgressState, ProgressTask, bool cancelButton = true)(ProgressTask task) {
        ProgressTask[] taskList = new ProgressTask[](1);
        taskList[0] = task;
        beginProgressTask!(ProgressState, ProgressTask, cancelButton)(taskList);
    }

    void _createEditRegionMenu() {
        _editRegionMenu = new Menu();

        _editRegionMenu.append(new MenuItem(delegate void(MenuItem) { new OnsetDetectionDialog(); },
                                            "Onset Detection..."));

        _stretchSelectionMenuItem = new MenuItem(delegate void(MenuItem) { new StretchSelectionDialog(); },
                                                 "Stretch Selection...");
        _editRegionMenu.append(_stretchSelectionMenuItem);

        _editRegionMenu.append(new MenuItem(delegate void (MenuItem) { new NormalizeDialog(); },
                                            "Normalize..."));

        _linkChannelsMenuItem = new CheckMenuItem("Link Channels");
        _linkChannelsMenuItem.setDrawAsRadio(true);
        _linkChannelsMenuItem.addOnToggled(&onLinkChannels);
        _editRegionMenu.append(_linkChannelsMenuItem);

        _editRegionMenu.attachToWidget(this, null);
    }

    void onLinkChannels(CheckMenuItem linkChannels) {
        _editRegion.linkChannels = linkChannels.getActive();
        _canvas.redraw();
    }

    void _zoomIn() {
        auto zoomCount = _zoomMultiplier;
        for(auto i = 0; i < zoomCount; ++i) {
            auto step = _zoomStep;
            _samplesPerPixel = max(_samplesPerPixel - step, 10);
        }
        _canvas.redraw();
        _hScroll.reconfigure();
    }
    void _zoomOut() {
        auto zoomCount = _zoomMultiplier;
        for(auto i = 0; i < zoomCount; ++i) {
            auto step = _zoomStep;
            _samplesPerPixel += step;
        }
        _canvas.redraw();
        _hScroll.reconfigure();
    }

    void _zoomInVertical() {
        _verticalScaleFactor = max(_verticalScaleFactor / _verticalZoomFactor, _verticalZoomFactorMin);
        _canvas.redraw();
        _vScroll.reconfigure();
    }
    void _zoomOutVertical() {
        _verticalScaleFactor = min(_verticalScaleFactor * _verticalZoomFactor, _verticalZoomFactorMax);
        _canvas.redraw();
        _vScroll.reconfigure();
    }

    void _setCursor() {
        static Cursor cursorMoving;
        static Cursor cursorMovingOnset;

        void setCursorByType(Cursor cursor, CursorType cursorType) {
            if(cursor is null) {
                cursor = new Cursor(Display.getDefault(), cursorType);
            }
            getWindow().setCursor(cursor);
        }
        void setCursorDefault() {
            getWindow().setCursor(null);
        }

        switch(_action) {
            case Action.moveMarker:
            case Action.moveRegion:
                setCursorByType(cursorMoving, CursorType.FLEUR);
                break;

            case Action.moveOnset:
                setCursorByType(cursorMovingOnset, CursorType.SB_H_DOUBLE_ARROW);
                break;

            default:
                setCursorDefault();
                break;
        }
    }

    void _setAction(Action action) {
        switch(action) {
            case Action.selectRegion:
            case Action.moveRegion:
                _earliestSelectedRegion = null;
                nframes_t minOffset = nframes_t.max;
                foreach(regionView; _regionViews) {
                    if(regionView.selected) {
                        regionView.selectedOffset = regionView.region.offset;
                        if(regionView.region.offset < minOffset) {
                            minOffset = regionView.region.offset;
                            _earliestSelectedRegion = regionView;
                        }
                    }
                }
                break;

            default:
                break;
        }
        _action = action;
        _setCursor();
    }

    void _setMode(Mode mode) {
        switch(mode) {
            case Mode.editRegion:
                // enable edit mode for the first selected region
                _editRegion = null;
                foreach(regionView; _regionViews) {
                    if(regionView.selected) {
                        regionView.editMode = true;
                        _editRegion = regionView;
                        if(_editRegion.subregionSelected) {
                            _subregionSelected = true;
                            _subregionStartFrame = _editRegion.subregionStartFrame + _editRegion.region.offset;
                            _subregionEndFrame = _editRegion.subregionEndFrame + _editRegion.region.offset;
                        }
                        break;
                    }
                }
                if(_editRegion is null) {
                    return;
                }
                break;

            default:
                // if the last mode was editRegion, unset the edit mode flag for the edited region
                if(_mode == Mode.editRegion) {
                    _editRegion.subregionSelected = _subregionSelected;
                    if(_subregionSelected) {
                        _editRegion.subregionStartFrame = _subregionStartFrame - _editRegion.region.offset;
                        _editRegion.subregionEndFrame = _subregionEndFrame - _editRegion.region.offset;
                    }
                    _editRegion.editMode = false;
                    _editRegion = null;
                    _subregionSelected = false;
                }
                break;
        }

        _mode = mode;
        _canvas.redraw();
    }

    class Canvas : DrawingArea {
        enum timestripHeightPixels = 40;

        enum markerHeightPixels = 20;
        enum markerHeadWidthPixels = 16;

        enum timeMarkerFont = "Arial 10";
        enum markerLabelFont = "Arial 10";

        this() {
            setCanFocus(true);

            addOnDraw(&drawCallback);
            addOnSizeAllocate(&onSizeAllocate);
            addOnMotionNotify(&onMotionNotify);
            addOnButtonPress(&onButtonPress);
            addOnButtonRelease(&onButtonRelease);
            addOnScroll(&onScroll);
            addOnKeyPress(&onKeyPress);
        }

        @property pixels_t viewWidthPixels() const {
            return _viewWidthPixels;
        }
        @property pixels_t viewHeightPixels() const {
            return _viewHeightPixels;
        }

        @property pixels_t markerYOffset() {
            return timestripHeightPixels;
        }

        @property pixels_t firstTrackYOffset() {
            return markerYOffset + markerHeightPixels;
        }

        @property nframes_t smallSeekIncrement() {
            return viewWidthSamples / 10;
        }

        @property nframes_t largeSeekIncrement() {
            return viewWidthSamples / 5;
        }

        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(_refreshTimeout is null) {
                _refreshTimeout = new Timeout(cast(uint)(1.0 / refreshRate * 1000), &onRefresh, false);
            }

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.paint();

            drawBackground(cr);
            drawTracks(cr);
            drawMarkers(cr);
            drawTimestrip(cr);
            drawTransport(cr);
            drawSelectBox(cr);

            return true;
        }

        void drawBackground(ref Scoped!Context cr) {
            cr.save();

            nframes_t secondsDistanceSamples = _mixer.sampleRate;
            nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timestripScaleFactor);
            pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;

            // draw all currently visible arrange ticks
            auto firstMarkerOffset = (viewOffset + tickDistanceSamples) % tickDistanceSamples;
            for(auto i = viewOffset - firstMarkerOffset;
                i < viewOffset + viewWidthSamples + tickDistanceSamples; i += tickDistanceSamples) {
                pixels_t xOffset =
                    cast(pixels_t)(((i >= viewOffset) ?
                                    cast(long)(i - viewOffset) : -cast(long)(viewOffset - i)) / samplesPerPixel);
                // draw primary arrange ticks
                cr.moveTo(xOffset, markerYOffset);
                cr.lineTo(xOffset, viewHeightPixels);
                cr.setSourceRgb(0.2, 0.2, 0.2);
                cr.stroke();

                // draw secondary arrange ticks
                cr.moveTo(xOffset + tickDistancePixels / 2, markerYOffset);
                cr.lineTo(xOffset + tickDistancePixels / 2, viewHeightPixels);
                cr.moveTo(xOffset + tickDistancePixels / 4, markerYOffset);
                cr.lineTo(xOffset + tickDistancePixels / 4, viewHeightPixels);
                cr.moveTo(xOffset + (tickDistancePixels / 4) * 3, markerYOffset);
                cr.lineTo(xOffset + (tickDistancePixels / 4) * 3, viewHeightPixels);
                cr.setSourceRgb(0.1, 0.1, 0.1);
                cr.stroke();
            }

            cr.restore();            
        }

        void drawTimestrip(ref Scoped!Context cr) {
            enum primaryTickHeightFactor = 0.5;
            enum secondaryTickHeightFactor = 0.35;
            enum tertiaryTickHeightFactor = 0.2;

            enum timestripBackgroundPadding = 2;

            cr.save();

            // draw a black background for the timestrip
            cr.rectangle(0, 0, viewWidthPixels, timestripHeightPixels - timestripBackgroundPadding);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.fill();

            if(!_timestripMarkerLayout) {
                PgFontDescription desc;
                _timestripMarkerLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(timeMarkerFont);
                _timestripMarkerLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setSourceRgb(1.0, 1.0, 1.0);
            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);
            nframes_t secondsDistanceSamples = _mixer.sampleRate;
            pixels_t secondsDistancePixels = secondsDistanceSamples / samplesPerPixel;

            void autoScale() {
                nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timestripScaleFactor);
                pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;
                if(tickDistancePixels > 200) {
                    _timestripScaleFactor *= 0.5f;
                }
                else if(tickDistancePixels < 100) {
                    _timestripScaleFactor *= 2.0f;
                }
            }

            if(secondsDistancePixels > 150) {
                autoScale();
            }
            else if(secondsDistancePixels > 60) {
                _timestripScaleFactor = 1;
            }
            else if(secondsDistancePixels > 25) {
                _timestripScaleFactor = 2;
            }
            else if(secondsDistancePixels > 15) {
                _timestripScaleFactor = 5;
            }
            else if(secondsDistancePixels > 10) {
                _timestripScaleFactor = 10;
            }
            else if(secondsDistancePixels > 3) {
                _timestripScaleFactor = 15;
            }
            else {
                autoScale();
            }

            nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timestripScaleFactor);
            pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;

            auto decDigits = 1;
            if(secondsDistancePixels <= 15) {
                decDigits = 0;
            }
            else if(secondsDistancePixels >= 750) {
                decDigits = clamp(cast(typeof(decDigits))(10 - log(tickDistanceSamples)), 1, 5);
            }

            auto minuteSpec = singleSpec("%.0f");
            auto decDigitsFormat = to!string(decDigits) ~ 'f';
            auto secondsSpec = singleSpec("%." ~ decDigitsFormat);
            auto secondsSpecTwoDigitsString = appender!string();
            secondsSpecTwoDigitsString.put("%0");
            secondsSpecTwoDigitsString.put(to!string(decDigits > 0 ? decDigits + 3 : 2));
            secondsSpecTwoDigitsString.put('.');
            secondsSpecTwoDigitsString.put(decDigitsFormat);
            auto secondsSpecTwoDigits = singleSpec(secondsSpecTwoDigitsString.data);

            // draw all currently visible time ticks and their time labels
            auto firstMarkerOffset = (viewOffset + tickDistanceSamples) % tickDistanceSamples;
            for(auto i = viewOffset - firstMarkerOffset;
                i < viewOffset + viewWidthSamples + tickDistanceSamples; i += tickDistanceSamples) {
                pixels_t xOffset =
                    cast(pixels_t)(((i >= viewOffset) ?
                                    cast(long)(i - viewOffset) : -cast(long)(viewOffset - i)) / samplesPerPixel);

                // draw primary timestrip tick
                cr.moveTo(xOffset, 0);
                cr.lineTo(xOffset, timestripHeightPixels * primaryTickHeightFactor);

                // draw one secondary timestrip tick
                cr.moveTo(xOffset + tickDistancePixels / 2, 0);
                cr.lineTo(xOffset + tickDistancePixels / 2, timestripHeightPixels * secondaryTickHeightFactor);

                // draw two tertiary timestrip ticks
                cr.moveTo(xOffset + tickDistancePixels / 4, 0);
                cr.lineTo(xOffset + tickDistancePixels / 4, timestripHeightPixels * tertiaryTickHeightFactor);
                cr.moveTo(xOffset + (tickDistancePixels / 4) * 3, 0);
                cr.lineTo(xOffset + (tickDistancePixels / 4) * 3, timestripHeightPixels * tertiaryTickHeightFactor);

                pixels_t timeMarkerXOffset;
                auto timeString = appender!string();
                auto minutes = (i / secondsDistanceSamples) / 60;
                if(i == 0) {
                    timeString.put('0');
                    timeMarkerXOffset = xOffset;
                }
                else {
                    if(minutes > 0) {
                        timeString.put(to!string(minutes));
                        timeString.put(':');
                        formatValue(timeString, float(i) / float(secondsDistanceSamples) - minutes * 60,
                                    secondsSpecTwoDigits);
                    }
                    else {
                        formatValue(timeString, float(i) / float(secondsDistanceSamples), secondsSpec);
                    }

                    int widthPixels, heightPixels;
                    _timestripMarkerLayout.getPixelSize(widthPixels, heightPixels);
                    timeMarkerXOffset = xOffset - widthPixels / 2;
                }

                cr.setSourceRgb(1.0, 1.0, 1.0);
                cr.stroke();

                _timestripMarkerLayout.setText(timeString.data);
                cr.moveTo(timeMarkerXOffset, timestripHeightPixels * 0.5);
                PgCairo.updateLayout(cr, _timestripMarkerLayout);
                PgCairo.showLayout(cr, _timestripMarkerLayout);
            }

            cr.restore();
        }

        void drawTracks(ref Scoped!Context cr) {
            pixels_t yOffset = firstTrackYOffset - _verticalPixelsOffset;
            foreach(t; _trackViews) {
                t.draw(cr, yOffset);
                yOffset += t.heightPixels;
            }
        }

        void drawTransport(ref Scoped!Context cr) {
            enum transportHeadWidth = 16;
            enum transportHeadHeight = 10;

            cr.save();

            if(_action == Action.moveTransport) {
                _transportPixelsOffset = clamp(_mouseX, 0, (viewOffset + viewWidthSamples > _mixer.lastFrame) ?
                                               ((_mixer.lastFrame - viewOffset) / samplesPerPixel) :
                                               viewWidthPixels);
            }
            else if(viewOffset <= _mixer.transportOffset + (transportHeadWidth / 2) &&
                    _mixer.transportOffset <= viewOffset + viewWidthSamples + (transportHeadWidth / 2)) {
                _transportPixelsOffset = (_mixer.transportOffset - viewOffset) / samplesPerPixel;
            }
            else {
                return;
            }

            GtkAllocation size;
            getAllocation(size);

            cr.setSourceRgb(1.0, 0.0, 0.0);
            cr.setLineWidth(1.0);
            cr.moveTo(_transportPixelsOffset, 0);
            cr.lineTo(_transportPixelsOffset, size.height);
            cr.stroke();

            cr.moveTo(_transportPixelsOffset - transportHeadWidth / 2, 0);
            cr.lineTo(_transportPixelsOffset + transportHeadWidth / 2, 0);
            cr.lineTo(_transportPixelsOffset, transportHeadHeight);
            cr.closePath();
            cr.fill();

            cr.restore();
        }

        void drawSelectBox(ref Scoped!Context cr) {
            if(_action == Action.selectBox) {
                cr.save();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.NONE);

                cr.setLineWidth(1.0);
                cr.rectangle(_selectMouseX, _selectMouseY, _mouseX - _selectMouseX, _mouseY - _selectMouseY);
                cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                cr.fillPreserve();
                cr.setSourceRgb(0.0, 1.0, 0.0);
                cr.stroke();

                cr.restore();
            }
            else if(_mode == Mode.editRegion && (_subregionSelected || _action == Action.selectSubregion)) {
                cr.save();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.NONE);

                pixels_t x0 = (_subregionStartFrame - viewOffset) / samplesPerPixel;
                pixels_t x1 = (_subregionEndFrame - viewOffset) / samplesPerPixel;
                cr.rectangle(x0, _editRegion.boundingBox.y0,
                             x1 - x0,  _editRegion.boundingBox.y1 - _editRegion.boundingBox.y0);
                cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                cr.fill();

                cr.restore();
            }
        }

        void drawMarkers(ref Scoped!Context cr) {
            enum taperFactor = 0.75;

            cr.save();

            if(!_markerLabelLayout) {
                PgFontDescription desc;
                _markerLabelLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(markerLabelFont);
                _markerLabelLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);

            // draw the visible user-defined markers
            pixels_t yOffset = markerYOffset - _verticalPixelsOffset;
            foreach(ref marker; _markers) {
                if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples) {
                    pixels_t xOffset = (marker.offset - viewOffset) / samplesPerPixel;

                    cr.setAntialias(cairo_antialias_t.GOOD);
                    cr.moveTo(xOffset, yOffset + markerHeightPixels);
                    cr.lineTo(xOffset - markerHeadWidthPixels / 2, yOffset + markerHeightPixels * taperFactor);
                    cr.lineTo(xOffset - markerHeadWidthPixels / 2, yOffset);
                    cr.lineTo(xOffset + markerHeadWidthPixels / 2, yOffset);
                    cr.lineTo(xOffset + markerHeadWidthPixels / 2, yOffset + markerHeightPixels * taperFactor);
                    cr.closePath();
                    cr.setSourceRgb(1.0, 0.90, 0.0);
                    cr.fillPreserve();
                    cr.setSourceRgb(1.0, 0.65, 0.0);
                    cr.stroke();

                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.moveTo(xOffset, yOffset + markerHeightPixels);
                    cr.lineTo(xOffset, viewHeightPixels);
                    cr.stroke();

                    cr.setSourceRgb(0.0, 0.0, 0.0);
                    _markerLabelLayout.setText(marker.name);
                    int widthPixels, heightPixels;
                    _markerLabelLayout.getPixelSize(widthPixels, heightPixels);
                    cr.moveTo(xOffset - widthPixels / 2, yOffset);
                    PgCairo.updateLayout(cr, _markerLabelLayout);
                    PgCairo.showLayout(cr, _markerLabelLayout);
                }
            }

            // draw a dotted line at the end of the project, if visible
            if(_mixer.lastFrame > viewOffset && _mixer.lastFrame <= viewOffset + viewWidthSamples) {
                enum dottedLinePixels = 15;
                pixels_t xOffset = (_mixer.lastFrame - viewOffset) / samplesPerPixel;

                for(auto y = markerYOffset; y < viewHeightPixels; y += dottedLinePixels * 2) {
                    cr.moveTo(xOffset, y);
                    cr.lineTo(xOffset, y + dottedLinePixels);
                }
                cr.setSourceRgb(1.0, 1.0, 1.0);
                cr.stroke();
            }

            cr.restore();
        }

        void redraw() {
            GtkAllocation area;
            getAllocation(area);
            queueDrawArea(area.x, area.y, area.width, area.height);
        }

        bool onRefresh() {
            if(_mixer.playing) {
                redraw();
            }
            return true;
        }

        void onSizeAllocate(GtkAllocation* allocation, Widget widget) {
            GtkAllocation size;
            getAllocation(size);
            _viewWidthPixels = cast(pixels_t)(size.width);
            _viewHeightPixels = cast(pixels_t)(size.height);

            _hScroll.reconfigure();
            _vScroll.reconfigure();
        }

        void onSelectSubregion() {
            if(_mouseX >= 0 && _mouseX <= viewWidthPixels) {
                nframes_t mouseFrame = _mouseX * samplesPerPixel + viewOffset;
                if(mouseFrame < _subregionStartFrame) {
                    _subregionStartFrame = mouseFrame;
                    _subregionDirection = Direction.left;
                }
                else if(mouseFrame > _subregionEndFrame) {
                    _subregionEndFrame = mouseFrame;
                    _subregionDirection = Direction.right;
                }
                else {
                    if(_subregionDirection == Direction.left) {
                        _subregionStartFrame = mouseFrame;
                    }
                    else {
                        _subregionEndFrame = mouseFrame;
                    }
                }

                if(_mixer.looping) {
                    _mixer.enableLoop(_subregionStartFrame, _subregionEndFrame);
                }

                redraw();
            }
        }

        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                pixels_t prevMouseX = _mouseX;
                pixels_t prevMouseY = _mouseY;
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                _mouseY = cast(typeof(_mouseX))(event.motion.y);

                switch(_action) {
                    case Action.selectRegion:
                        _setAction(Action.moveRegion);
                        redraw();
                        break;

                    case Action.selectSubregion:
                        onSelectSubregion();
                        break;

                    case Action.selectBox:
                        redraw();
                        break;

                    case Action.moveRegion:
                        foreach(regionView; _regionViews) {
                            if(regionView.selected) {
                                nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                                if(_mouseX > prevMouseX) {
                                    regionView.selectedOffset += deltaXSamples;
                                }
                                else if(_earliestSelectedRegion.selectedOffset > abs(deltaXSamples)) {
                                    regionView.selectedOffset -= deltaXSamples;
                                }
                                else {
                                    regionView.selectedOffset =
                                        regionView.region.offset > _earliestSelectedRegion.region.offset ?
                                        regionView.region.offset - _earliestSelectedRegion.region.offset : 0;
                                }
                            }
                        }
                        redraw();
                        break;

                    case Action.moveMarker:
                        nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                        if(_mouseX > prevMouseX) {
                            if(_moveMarker.offset + deltaXSamples >= _mixer.lastFrame) {
                                _moveMarker.offset = _mixer.lastFrame;
                            }
                            else {
                                _moveMarker.offset += deltaXSamples;
                            }
                        }
                        else if(_moveMarker.offset > abs(deltaXSamples)) {
                            _moveMarker.offset -= deltaXSamples;
                        }
                        else {
                            _moveMarker.offset = 0;
                        }
                        redraw();
                        break;

                    case Action.moveOnset:
                        foreach(regionView; _regionViews) {
                            if(regionView.selected) {
                                nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                                Direction direction = (_mouseX > prevMouseX) ? Direction.right : Direction.left;
                                _moveOnsetFrameDest = regionView.moveOnset(_moveOnsetIndex,
                                                                           deltaXSamples,
                                                                           direction,
                                                                           _moveOnsetChannel);
                            }
                        }
                        redraw();
                        break;

                    case Action.moveTransport:
                        redraw();
                        break;

                    case Action.none:
                    default:
                        break;
                }
            }
            return true;
        }

        bool onButtonPress(Event event, Widget widget) {
            enum leftButton = 1;
            enum rightButton = 3;

            GdkModifierType state;
            event.getState(state);
            auto shiftPressed = state & GdkModifierType.SHIFT_MASK;
            auto controlPressed = state & GdkModifierType.CONTROL_MASK;

            if(event.type == EventType.BUTTON_PRESS && event.button.button == leftButton) {
                // if the mouse is over a marker, move that marker
                if(_mouseY >= markerYOffset && _mouseY < markerYOffset + markerHeightPixels) {
                    foreach(ref marker; _markers) {
                        if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples &&
                           (cast(pixels_t)((marker.offset - viewOffset) / samplesPerPixel) -
                            markerHeadWidthPixels / 2 <= _mouseX) &&
                           (cast(pixels_t)((marker.offset - viewOffset) / samplesPerPixel) +
                            markerHeadWidthPixels / 2 >= _mouseX)) {
                            _moveMarker = &marker;
                            _setAction(Action.moveMarker);
                            break;
                        }
                    }
                }

                // if the mouse was not over a marker
                if(_action != Action.moveMarker) {
                    // if the mouse is over the timestrip, move the transport
                    if(_mouseY >= 0 && _mouseY < timestripHeightPixels + markerHeightPixels) {
                        _setAction(Action.moveTransport);
                    }
                    else {
                        bool newAction;
                        switch(_mode) {
                            // implement different behaviors for button presses depending on the current mode
                            case Mode.arrange:
                                // detect if the mouse is over an audio region; if so, select that region
                                bool mouseOverSelectedRegion;
                                foreach(regionView; _regionViews) {
                                    if(_mouseX >= regionView.boundingBox.x0 && _mouseX < regionView.boundingBox.x1 &&
                                       _mouseY >= regionView.boundingBox.y0 && _mouseY < regionView.boundingBox.y1 &&
                                       regionView.selected) {
                                        mouseOverSelectedRegion = true;
                                        break;
                                    }
                                }

                                if(mouseOverSelectedRegion && !shiftPressed) {
                                    _setAction(Action.moveRegion);
                                    newAction = true;
                                }
                                else {
                                    // if shift is not currently pressed, deselect all regions
                                    if(!shiftPressed) {
                                        foreach(regionView; _regionViews) {
                                            regionView.selected = false;
                                        }
                                        _earliestSelectedRegion = null;
                                    }

                                    bool mouseOverRegion;
                                    foreach(regionView; _regionViews) {
                                        if(_mouseX >= regionView.boundingBox.x0 &&
                                           _mouseX < regionView.boundingBox.x1 &&
                                           _mouseY >= regionView.boundingBox.y0 &&
                                           _mouseY < regionView.boundingBox.y1) {
                                            // if the region is already selected and shift is pressed, deselect it
                                            regionView.selected = !(regionView.selected && shiftPressed);
                                            mouseOverRegion = true;
                                            _setAction(Action.selectRegion);
                                            newAction = true;
                                            break;
                                        }
                                    }
                                }
                                break;

                            case Mode.editRegion:
                                if(_editRegion) {
                                    // select a subregion
                                    if(controlPressed) {
                                        _subregionStartFrame = _subregionEndFrame =
                                            cast(nframes_t)(_mouseX * samplesPerPixel) + viewOffset;
                                        _setAction(Action.selectSubregion);
                                        newAction = true;
                                    }
                                    else if(_subregionSelected && shiftPressed) {
                                        onSelectSubregion();
                                        _setAction(Action.selectSubregion);
                                        newAction = true;
                                    }
                                    else {
                                        // detect if the mouse is over an onset
                                        _moveOnsetChannel = _editRegion.mouseOverChannel(_mouseY);
                                        if(_editRegion.getOnset(viewOffset + _mouseX * samplesPerPixel -
                                                                _editRegion.region.offset,
                                                                mouseOverThreshold * samplesPerPixel,
                                                                _moveOnsetFrameSrc,
                                                                _moveOnsetIndex,
                                                                _moveOnsetChannel)) {
                                            _moveOnsetFrameDest = _moveOnsetFrameSrc;
                                            _setAction(Action.moveOnset);
                                            newAction = true;
                                        }
                                    }
                                }
                                break;

                            default:
                                break;
                        }

                        if(!newAction && _mode == Mode.arrange) {
                            _selectMouseX = _mouseX;
                            _selectMouseY = _mouseY;
                            _setAction(Action.selectBox);
                        }
                    }

                    redraw();
                }
            }
            else if(event.type == EventType.BUTTON_PRESS && event.button.button == rightButton) {
                auto buttonEvent = event.button;

                switch(_mode) {
                    case Mode.arrange:
                        if(_arrangeMenu is null) {
                            _createArrangeMenu();
                        }
                        _arrangeMenu.popup(buttonEvent.button, buttonEvent.time);
                        _arrangeMenu.showAll();
                        break;

                    case Mode.editRegion:
                        if(_editRegionMenu is null) {
                            _createEditRegionMenu();
                        }
                        _linkChannelsMenuItem.setSensitive(_editRegion.region.nChannels > 1);
                        _linkChannelsMenuItem.setActive(_editRegion.linkChannels);

                        _stretchSelectionMenuItem.setSensitive(_subregionSelected);

                        _editRegionMenu.popup(buttonEvent.button, buttonEvent.time);
                        _editRegionMenu.showAll();
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == 1) {
                switch(_action) {
                    // reset the cursor if necessary
                    case Action.selectRegion:
                        _setAction(Action.none);
                        redraw();
                        break;

                    // select a subregion
                    case Action.selectSubregion:
                        if(_subregionStartFrame == _subregionEndFrame) {
                            _subregionSelected = false;
                            _editRegion.subregionSelected = false;
                        }
                        else {
                            _subregionSelected = true;
                            _editRegion.subregionSelected = true;
                            _editRegion.subregionStartFrame = _subregionStartFrame;
                            _editRegion.subregionEndFrame = _subregionEndFrame;
                        }
                        _setAction(Action.none);
                        redraw();
                        break;

                    // select all regions within the selection box drawn with the mouse
                    case Action.selectBox:
                        if(_mode == Mode.arrange) {
                            BoundingBox selectBox = BoundingBox(_selectMouseX, _selectMouseY, _mouseX, _mouseY);
                            foreach(regionView; _regionViews) {
                                if(selectBox.intersect(regionView.boundingBox)) {
                                    regionView.selected = true;
                                }
                            }
                        }
                        _setAction(Action.none);
                        redraw();
                        break;

                    // move a region
                    case Action.moveRegion:
                        _setAction(Action.none);
                        foreach(regionView; _regionViews) {
                            if(regionView.selected) {
                                regionView.region.offset = regionView.selectedOffset;
                                _mixer.resizeIfNecessary(regionView.region.offset + regionView.region.nframes);
                            }
                        }
                        redraw();
                        break;

                    // stop moving a marker
                    case Action.moveMarker:
                        _setAction(Action.none);
                        break;

                    // stretch the audio inside a region
                    case Action.moveOnset:
                        immutable(nframes_t) onsetFrameStart =
                            _editRegion.getPrevOnset(_moveOnsetIndex, _moveOnsetChannel);
                        immutable(nframes_t) onsetFrameEnd =
                            _editRegion.getNextOnset(_moveOnsetIndex, _moveOnsetChannel);

                        _editRegion.region.stretchThreePoint(onsetFrameStart,
                                                             _moveOnsetFrameSrc,
                                                             _moveOnsetFrameDest,
                                                             onsetFrameEnd,
                                                             _editRegion.linkChannels,
                                                             _moveOnsetChannel);
                        _editRegion.region.computeOverview();

                        redraw();
                        _setAction(Action.none);
                        break;

                    case Action.moveTransport:
                        _setAction(Action.none);
                        _mixer.transportOffset = viewOffset + (clamp(_mouseX, 0, viewWidthPixels) * samplesPerPixel);
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        bool onScroll(Event event, Widget widget) {
            if(event.type == EventType.SCROLL) {
                GdkModifierType state;
                event.getState(state);
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;

                ScrollDirection direction;
                event.getScrollDirection(direction);
                switch(direction) {
                    case ScrollDirection.LEFT:
                        if(controlPressed) {
                            _zoomOut();
                        }
                        else {
                            if(_hScroll.stepSamples <= viewOffset) {
                                _viewOffset -= _hScroll.stepSamples;
                            }
                            else {
                                _viewOffset = viewMinSamples;
                            }
                            _hScroll.update();
                            if(_action == Action.centerView ||
                               _action == Action.centerViewStart ||
                               _action == Action.centerViewEnd) {
                                _setAction(Action.none);
                            }
                            redraw();
                        }
                        break;

                    case ScrollDirection.RIGHT:
                        if(controlPressed) {
                            _zoomIn();
                        }
                        else {
                            if(_hScroll.stepSamples + viewOffset <= _mixer.lastFrame) {
                                _viewOffset += _hScroll.stepSamples;
                            }
                            else {
                                _viewOffset = _mixer.lastFrame;
                            }
                            _hScroll.update();
                            if(_action == Action.centerView ||
                               _action == Action.centerViewStart ||
                               _action == Action.centerViewEnd) {
                                _setAction(Action.none);
                            }
                            redraw();
                        }
                        break;

                    case ScrollDirection.UP:
                        if(controlPressed) {
                            _zoomOutVertical();
                        }
                        else {
                            _vScroll.pixelsOffset = _vScroll.pixelsOffset - _vScroll.stepIncrement;
                            _verticalPixelsOffset = _vScroll.pixelsOffset;
                            redraw();
                        }
                        break;

                    case ScrollDirection.DOWN:
                        if(controlPressed) {
                            _zoomInVertical();
                        }
                        else {
                            _vScroll.pixelsOffset = _vScroll.pixelsOffset + _vScroll.stepIncrement;
                            _verticalPixelsOffset = cast(pixels_t)(_vScroll.pixelsOffset);
                            redraw();
                        }
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        bool onKeyPress(Event event, Widget widget) {
            if(event.type == EventType.KEY_PRESS) {
                switch(_action) {
                // insert a new marker
                    case Action.createMarker:
                        _setAction(Action.none);
                        wchar keyval = cast(wchar)(Keymap.keyvalToUnicode(event.key.keyval));
                        if(isAlpha(keyval) || isNumber(keyval)) {
                            _markers[event.key.keyval] = Marker(_mixer.transportOffset, to!string(keyval));
                            redraw();
                        }
                        return false;

                    case Action.jumpToMarker:
                        _setAction(Action.none);
                        try {
                            _mixer.transportOffset = _markers[event.key.keyval].offset;
                            redraw();
                        }
                        catch(RangeError) {
                        }
                        return false;

                    default:
                        break;
                }

                GdkModifierType state;
                event.getState(state);
                auto shiftPressed = state & GdkModifierType.SHIFT_MASK;
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;

                switch(event.key.keyval) {
                    case GdkKeysyms.GDK_space:
                        if(shiftPressed) {
                            if(_subregionSelected) {
                                // loop the selected subregion
                                _mixer.transportOffset = _subregionStartFrame;
                                _mixer.enableLoop(_subregionStartFrame, _subregionEndFrame);
                                _mixer.play();
                            }
                        }
                        else {
                            // toggle play/pause for the mixer
                            if(_mixer.playing) {
                                _mixer.disableLoop();
                                _mixer.pause();
                            }
                            else {
                                _mixer.play();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_equal:
                        _zoomIn();
                        break;

                    case GdkKeysyms.GDK_minus:
                        _zoomOut();
                        break;

                    case GdkKeysyms.GDK_Return:
                        // move the transport to the last marker
                        Marker* lastMarker;
                        foreach(ref marker; _markers) {
                            if(!lastMarker ||
                               (marker.offset > lastMarker.offset && marker.offset < _mixer.transportOffset)) {
                                lastMarker = &marker;
                            }
                        }
                        _mixer.transportOffset = lastMarker ? lastMarker.offset : 0;
                        redraw();
                        break;

                    case GdkKeysyms.GDK_Aring:
                        // move the transport and view to the beginning of the project
                        _mixer.transportOffset = 0;
                        _viewOffset = viewMinSamples;
                        redraw();
                        break;

                    case GdkKeysyms.GDK_acute:
                        // move the transport to end of the project and center the view on the transport
                        _mixer.transportOffset = _mixer.lastFrame;
                        if(viewMaxSamples >= (viewWidthSamples / 2) * 3) {
                            _viewOffset = viewMaxSamples - (viewWidthSamples / 2) * 3;
                        }
                        redraw();
                        break;

                    case GdkKeysyms.GDK_function:
                        // seek the transport forward (large increment)
                        _mixer.transportOffset = min(_mixer.lastFrame,
                                                     _mixer.transportOffset + largeSeekIncrement);
                        redraw();
                        break;

                    case GdkKeysyms.GDK_integral:
                        // seek the transport backward (large increment)
                        _mixer.transportOffset = _mixer.transportOffset > largeSeekIncrement ?
                            _mixer.transportOffset - largeSeekIncrement : 0;
                        redraw();
                        break;

                    case GdkKeysyms.GDK_a:
                        if(controlPressed) {
                            // move the transport to the minimum offset of all selected regions
                            if(_earliestSelectedRegion !is null) {
                                _mixer.transportOffset = _earliestSelectedRegion.region.offset;
                                redraw();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_b:
                        if(controlPressed) {
                            // seek the transport backward (small increment)
                            _mixer.transportOffset = _mixer.transportOffset > smallSeekIncrement ?
                                _mixer.transportOffset - smallSeekIncrement : 0;
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_e:
                        if(controlPressed) {
                            // move the transport to the maximum length of all selected regions
                            nframes_t maxOffset = 0;
                            bool foundRegion;
                            foreach(regionView; _regionViews) {
                                if(regionView.selected &&
                                   regionView.region.offset + regionView.region.nframes > maxOffset) {
                                    maxOffset = regionView.region.offset + regionView.region.nframes;
                                    foundRegion = true;
                                }
                            }
                            if(foundRegion) {
                                _mixer.transportOffset = maxOffset;
                                redraw();
                            }
                        }
                        else {
                            // toggle edit mode
                            _setMode(_mode == Mode.editRegion ? Mode.arrange : Mode.editRegion);
                        }
                        break;

                    case GdkKeysyms.GDK_f:
                        if(controlPressed) {
                            // seek the transport forward (small increment)
                            _mixer.transportOffset = min(_mixer.lastFrame,
                                                         _mixer.transportOffset + smallSeekIncrement);
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_j:
                        // if control is pressed, jump to a marker that is about to be specified
                        if(controlPressed) {
                            _setAction(Action.jumpToMarker);
                        }
                        break;

                    case GdkKeysyms.GDK_l:
                        // center the view on the transport, emacs-style
                        if(_action == Action.centerViewStart) {
                            _viewOffset = _mixer.transportOffset;
                            _setAction(Action.centerViewEnd);
                        }
                        else if(_action == Action.centerViewEnd) {
                            if(_mixer.transportOffset > viewWidthSamples) {
                                _viewOffset = _mixer.transportOffset - viewWidthSamples;
                            }
                            else {
                                _viewOffset = viewMinSamples;
                            }
                            _setAction(Action.centerView);
                        }
                        else {
                            if(_mixer.transportOffset < viewWidthSamples / 2) {
                                _viewOffset = viewMinSamples;
                            }
                            else if(_mixer.transportOffset > viewMaxSamples - viewWidthSamples / 2) {
                                _viewOffset = viewMaxSamples;
                            }
                            else {
                                _viewOffset = _mixer.transportOffset - viewWidthSamples / 2;
                            }
                            _setAction(Action.centerViewStart);
                        }
                        _centeredView = true;
                        redraw();
                        _hScroll.update();
                        break;

                    case GdkKeysyms.GDK_m:
                        // if control is pressed, create a marker at the current transport position
                        if(controlPressed) {
                            _setAction(Action.createMarker);
                        }
                        // otherwise, mute selected regions
                        else if(_mode == Mode.arrange) {
                            foreach(regionView; _regionViews) {
                                if(regionView.selected) {
                                    regionView.region.mute = !regionView.region.mute;
                                }
                            }
                            redraw();
                        }
                        break;

                    default:
                        break;
                }
            }
            return false;
        }
    }

    Window _parentWindow;

    Mixer _mixer;
    TrackView[] _trackViews;
    RegionView[] _regionViews;
    RegionView _editRegion;
    RegionView _earliestSelectedRegion;

    Marker[uint] _markers;
    Marker* _moveMarker;

    bool _subregionSelected;
    nframes_t _subregionStartFrame;
    nframes_t _subregionEndFrame;
    Direction _subregionDirection;

    PgLayout _headerLabelLayout;
    PgLayout _markerLabelLayout;
    PgLayout _timestripMarkerLayout;
    float _timestripScaleFactor = 1;

    nframes_t _samplesPerPixel;
    nframes_t _viewOffset;

    Canvas _canvas;
    ArrangeHScroll _hScroll;
    ArrangeVScroll _vScroll;
    Timeout _refreshTimeout;

    Menu _arrangeMenu;
    FileChooserDialog _importFileChooser;

    Menu _editRegionMenu;
    MenuItem _stretchSelectionMenuItem;
    CheckMenuItem _linkChannelsMenuItem;

    pixels_t _viewWidthPixels;
    pixels_t _viewHeightPixels;
    pixels_t _transportPixelsOffset;
    pixels_t _verticalPixelsOffset;
    float _verticalScaleFactor = 1;

    Mode _mode;
    Action _action;
    bool _centeredView;
    pixels_t _mouseX;
    pixels_t _mouseY;
    pixels_t _selectMouseX;
    pixels_t _selectMouseY;

    size_t _moveOnsetIndex;
    channels_t _moveOnsetChannel;
    nframes_t _moveOnsetFrameSrc; // locally indexed for region
    nframes_t _moveOnsetFrameDest; // locally indexed for region
}

class AppMainWindow : MainWindow {
public:
    this(string title, Mixer mixer) {
        _mixer = mixer;
        super(title);
    }

protected:
    override bool windowDelete(Event event, Widget widget) {
        _cleanupMixer();
        return super.windowDelete(event, widget);
    }

    override bool exit(int code, bool force) {
        _cleanupMixer();
        return super.exit(code, force);
    }

private:
    void _cleanupMixer() {
        _mixer.destroy();
    }

    Mixer _mixer;
}

void main(string[] args) {
    string appName = "dseq";

    string[] availableAudioDrivers;
    version(HAVE_JACK) {
        availableAudioDrivers ~= "JACK";
    }
    version(HAVE_COREAUDIO) {
        availableAudioDrivers ~= "CoreAudio";
    }
    assert(availableAudioDrivers.length > 0);
    string audioDriver;

    GetoptResult opts;
    try {
        opts = getopt(args,
                      "driver|d", "Available audio drivers: " ~ reduce!((string x, y) => x ~ ", " ~ y)
                      (availableAudioDrivers[0], availableAudioDrivers[1 .. $]), &audioDriver);
    }
    catch(Exception e) {
        writeln("Error: " ~ e.msg);
        return;
    }

    if(opts.helpWanted) {
        defaultGetoptPrinter(appName ~ " command line options:", opts.options);
        return;
    }

    try {
        Mixer mixer;
        switch(audioDriver.toUpper()) {
            version(HAVE_JACK) {
                case "JACK":
                    mixer = new JackMixer(appName);
                    break;
            }

            version(HAVE_COREAUDIO) {
                case "COREAUDIO":
                    mixer = new CoreAudioMixer(appName);
                    break;
            }

            default:
                version(OSX) {
                    version(HAVE_COREAUDIO) {
                        mixer = new CoreAudioMixer(appName);
                    }
                    else {
                        mixer = new JackMixer(appName);
                    }
                }
                else {
                    mixer = new JackMixer(appName);
                }
        }
        assert(mixer !is null);

        Main.init(args);
        AppMainWindow mainWindow = new AppMainWindow(appName, mixer);
        mainWindow.setDefaultSize(960, 600);

        ArrangeView arrangeView = new ArrangeView(appName, mainWindow, mixer);
        mainWindow.add(arrangeView);
        mainWindow.showAll();

        arrangeView.loadRegionsFromFiles(args[1 .. $]);
        Main.run();
    }
    catch(AudioError e) {
        writeln("Fatal audio error: ", e.msg);
        return;
    }
}
