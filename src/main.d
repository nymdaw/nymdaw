module dseq;

import std.stdio;
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

version(HAVE_JACK) {
    import jack.client;
}

import sndfile;
import samplerate;
import aubio;
import rubberband;

import gtk.MainWindow;
import gtk.Main;
import gtk.Widget;
import gtk.VBox;
import gtk.DrawingArea;
import gtk.Adjustment;
import gtk.Scrollbar;
import gtk.Menu;
import gtk.MenuItem;
import gtk.CheckMenuItem;

import gtkc.gtktypes;

import gdk.Cursor;
import gdk.Display;
import gdk.Event;
import gdk.Keymap;
import gdk.Keysyms;
import gdk.Window;

import glib.Timeout;

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

class FileError: Exception {
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

alias pixels_t = int;

class Region {
public:
    this(nframes_t sampleRate, channels_t nChannels, sample_t[] audioBuffer, string name = "") {
        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _audioBuffer = audioBuffer;
        _nframes = cast(typeof(_nframes))(audioBuffer.length / nChannels);
        _name = name;

        _initCache();
    }

    // create a region from a file, leaving the sample rate unaltered
    static Region fromFile(string fileName) {
        SNDFILE* infile;
        SF_INFO sfinfo;

        // attempt to open the given file
        infile = sf_open(fileName.toStringz(), SFM_READ, &sfinfo);
        if(!infile) {
            throw new FileError("Could not open file: " ~ fileName);
        }

        // close the file when leaving this scope
        scope(exit) sf_close(infile);

        // allocate contiguous audio buffer
        sample_t[] audioBuffer = new sample_t[](cast(size_t)(sfinfo.frames * sfinfo.channels));

        // read the file into the audio buffer
        sf_count_t readcount;
        static if(is(sample_t == float)) {
            readcount = sf_read_float(infile, audioBuffer.ptr, cast(sf_count_t)(audioBuffer.length));
        }
        else if(is(sample_t == double)) {
            readcount = sf_read_double(infile, audioBuffer.ptr, cast(sf_count_t)(audioBuffer.length));
        }
        else {
            static assert(0);
        }

        // throw exception if file failed to read
        if(!readcount) {
            throw new FileError("Could not read file: " ~ fileName);
        }

        return new Region(cast(nframes_t)(sfinfo.samplerate),
                          cast(channels_t)(sfinfo.channels),
                          audioBuffer,
                          baseName(stripExtension(fileName)));
    }

    // create a region from a file, converting to the given sample rate if necessary
    static Region fromFile(string fileName, nframes_t sampleRate) {
        Region region = fromFile(fileName);
        region.convertSampleRate(sampleRate);
        return region;
    }

    // normalize region to the given maximum gain, in dBFS
    void normalize(sample_t maxGain = -0.1) {
        sample_t minSample, maxSample;
        _minMax(minSample, maxSample);
        maxSample = max(abs(minSample), abs(maxSample));

        sample_t sampleFactor =  pow(10, (maxGain > 0 ? 0 : maxGain) / 20) / maxSample;
        foreach(ref s; _audioBuffer) {
            s *= sampleFactor;
        }
    }

    void convertSampleRate(nframes_t newSampleRate, bool normalize = true) {
        if(newSampleRate != _sampleRate && newSampleRate > 0) {
            // constant indicating the algorithm to use for sample rate conversion
            enum converter = SRC_SINC_MEDIUM_QUALITY;

            // allocate audio buffers for input/output
            float[] dataIn = new float[](_audioBuffer.length);
            float[] dataOut;

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

            // convert the float buffer back to sample_t if necessary
            static if(is(sample_t == double)) {
                _audioBuffer.length = dataOut.length;
                foreach(i, sample; dataOut) {
                    _audioBuffer[i] = sample;
                }
            }

            // normalize, if requested
            if(normalize) {
                this.normalize();
            }
        }
    }

    // returns an array of frames at which an onset occurs, with frames given locally for this region
    // all channels are summed before computing onsets
    nframes_t[] getOnsetsLinkedChannels() const {
        return _getOnsets(true);
    }

    // returns an array of frames at which an onset occurs, with frames given locally for this region
    nframes_t[] getOnsetsSingleChannel(channels_t channelIndex) const {
        return _getOnsets(false, channelIndex);
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
                    [min(sampleOffset * (binSize / cacheSize), $ - 1) ..
                     min((sampleOffset + 1) * (binSize / cacheSize), $)]);
    }
    sample_t getMax(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) const {
        auto cacheSize = _cacheBinSizes[cacheIndex];
        return _max(_waveformCacheList[channelIndex][cacheIndex].maxValues
                    [min(sampleOffset * (binSize / cacheSize), $ - 1) ..
                     min((sampleOffset + 1) * (binSize / cacheSize), $)]);
    }

    // returns the sample value at a given channel and frame, globally indexed
    sample_t getSampleGlobal(channels_t channelIndex, nframes_t frame) const {
        return frame >= offset ?
            (frame < _offset + _nframes ? _audioBuffer[(frame - _offset) * _nChannels + channelIndex] : 0) : 0;
    }

    // modifies the sample for a given channel and frame, locallyIndexed
    void setSampleLocal(channels_t channelIndex, nframes_t frame, sample_t newSample) {
        _audioBuffer[frame * _nChannels + channelIndex] = newSample;
    }

    @property const(sample_t[]) audioBuffer() const { return _audioBuffer; }
    @property nframes_t sampleRate() const { return _sampleRate; }
    @property channels_t nChannels() const { return _nChannels; }
    @property nframes_t nframes() const { return _nframes; }
    @property nframes_t offset() const { return _offset; }
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }
    @property bool mute() const { return _mute; }
    @property bool mute(bool enable) { return (_mute = enable); }
    @property string name() const { return _name; }
    @property string name(string newName) { return (_name = newName); }

private:
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

    void _initCache() {
        _waveformCacheList = null;

        for(auto c = 0; c < _nChannels; ++c) {
            WaveformCache[] channelCache;
            channelCache ~= new WaveformCache(_cacheBinSizes[0], c);
            foreach(binSize; _cacheBinSizes[1 .. $]) {
                channelCache ~= new WaveformCache(binSize, channelCache[$ - 1]);
            }
            _waveformCacheList ~= channelCache;
        }
    }

    nframes_t[] _getOnsets(bool linkChannels, channels_t channelIndex = 0) const {
        immutable(uint) windowSize = 512;
        immutable(uint) hopSize = 256;
        string onsetMethod = "default";
        immutable(smpl_t) onsetThreshold = 0.1;
        immutable(smpl_t) silenceThreshold = -90.0;

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
        _regions ~= region;
        _resizeIfNecessary(region.offset + region.nframes);
    }

    const(Region[]) regions() const { return _regions; }

package:
    this(bool delegate(nframes_t) resizeIfNecessary) {
        _resizeIfNecessary = resizeIfNecessary;
    }

    void mixStereoInterleaved(nframes_t offset,
                              nframes_t bufNFrames,
                              channels_t nChannels,
                              sample_t* mixBuf) const {
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
                                 sample_t* mixBuf2) const {
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

private:
    Region[] _regions;
    bool delegate(nframes_t) _resizeIfNecessary;
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
        Track track = new Track(&resizeIfNecessary);
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

    @property final string appName() const { return _appName; }
    @property final nframes_t nframes() const { return _nframes; }
    @property final nframes_t nframes(nframes_t newNFrames) { return (_nframes = newNFrames); }
    @property final nframes_t transportOffset() const { return _transportOffset; }
    @property final nframes_t transportOffset(nframes_t newOffset) {
        return (_transportOffset = min(newOffset, nframes));
    }
    @property final bool playing() const { return _playing; }
    final void play() { _playing = true; }
    final void pause() { _playing = false; }

    final void mixStereoInterleaved(nframes_t bufNFrames, channels_t nChannels, sample_t* mixBuf) {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(!_transportFinished() && _playing) {
            foreach(t; _tracks) {
                t.mixStereoInterleaved(_transportOffset, bufNFrames, nChannels, mixBuf);
            }
            _transportOffset += bufNFrames / nChannels;
        }
    }

    final void mixStereoNonInterleaved(nframes_t bufNFrames, sample_t* mixBuf1, sample_t* mixBuf2) {
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
        }
    }

protected:
    void initializeMixer();
    void cleanupMixer();

private:
    // stop playing if the transport is at the end of the project
    bool _transportFinished() {
        if(_playing && _transportOffset + 1 >= _nframes) {
            _playing = false;
            _transportOffset = _nframes > 0 ? _nframes - 1 : 0;
            return true;
        }
        return false;
    }

    string _appName;

    Track[] _tracks;
    nframes_t _nframes;
    nframes_t _transportOffset;
    bool _playing;
}

version(HAVE_JACK) {

final class JackMixer : Mixer {
public:
    this(string appName) {
        super(appName);
    }

    @property override nframes_t sampleRate() { return _client.get_sample_rate(); }

protected:
    override void initializeMixer() {
        try {
            _openJack(appName);
        }
        catch(JackError e) {
            throw new AudioError(e.msg);
        }
    }

    override void cleanupMixer() {
        _closeJack();
    }

private:
    void _openJack(string appName) {
        _client = new JackClient;
        _client.open(appName, JackOptions.JackNoStartServer, null);

        JackPort mixOut1 = _client.register_port("Mix1", JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);
        JackPort mixOut2 = _client.register_port("Mix2", JACK_DEFAULT_AUDIO_TYPE, JackPortFlags.JackPortIsOutput, 0);

        // callback to process a single period of audio data
        _client.process_callback = delegate int(jack_nframes_t bufNFrames) {
            float* mixBuf1 = mixOut1.get_audio_buffer(bufNFrames);
            float* mixBuf2 = mixOut2.get_audio_buffer(bufNFrames);

            mixStereoNonInterleaved(bufNFrames, mixBuf1, mixBuf2);

            return 0;
        };

        _client.activate();

        // attempt to connect to physical playback ports
        string[] playbackPorts =
            _client.get_ports("", "", JackPortFlags.JackPortIsInput | JackPortFlags.JackPortIsPhysical);
        if(playbackPorts.length >= 2) {
            _client.connect(mixOut1.get_name(), playbackPorts[0]);
            _client.connect(mixOut2.get_name(), playbackPorts[1]);
        }
    }

    void _closeJack() {
        if(_client) {
            _client.close();
        }
    }

    JackClient _client;
}

}

version(HAVE_COREAUDIO) {

private extern(C) @nogc nothrow {
    char* coreAudioErrorString();
    bool coreAudioInit(nframes_t sampleRate, channels_t nChannels, AudioCallback callback);
    void coreAudioCleanup();
}

private extern(C) alias AudioCallback = void function(nframes_t, channels_t, sample_t*);

final class CoreAudioMixer : Mixer {
public:
    enum outputChannels = 2; // default to stereo

    this(string appName, nframes_t sampleRate = 44100) {
        if(!(_instance is null)) {
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
        if(!coreAudioInit(sampleRate, outputChannels, &_coreAudioCallback)) {
            throw new AudioError(to!string(coreAudioErrorString()));
        }
    }

    override void cleanupMixer() {
        coreAudioCleanup();
    }

private:
    extern(C) static void _coreAudioCallback(nframes_t bufNFrames,
                                             channels_t nChannels,
                                             sample_t* mixBuffer) {
        _instance.mixStereoInterleaved(bufNFrames, nChannels, mixBuffer);
    }

    __gshared static CoreAudioMixer _instance; // there should only be one instance for this process

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

class ArrangeView : VBox {
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
        selectBox,
        moveOnset,
        moveRegion,
        moveTransport,
        createMarker,
        jumpToMarker,
        centerView,
        centerViewStart,
        centerViewEnd
    }

    this(string appName, Mixer mixer) {
        _mixer = mixer;
        _samplesPerPixel = defaultSamplesPerPixel;

        super(false, 0);
        _canvas = new Canvas();
        _hAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
        _configureHScroll();
        _hAdjust.addOnValueChanged(&_onHScrollChanged);
        _hScroll = new Scrollbar(Orientation.HORIZONTAL, _hAdjust);

        _createEditRegionMenu();

        packStart(_canvas, true, true, 0);
        packEnd(_hScroll, false, false, 0);

        showAll();
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

        void computeOnsets() {
            // compute onsets for each channel
            _onsets = new nframes_t[][](region.nChannels);
            for(channels_t c = 0; c < region.nChannels; ++c) {
                _onsets[c] = region.getOnsetsSingleChannel(c);
            }

            // compute onsets for summed channels
            _onsetsLinked = region.getOnsetsLinkedChannels();
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

        bool editMode;
        bool linkChannels;

    private:
        this(Region region, Color* color) {
            this.region = region;
            _regionColor = color;
            computeOnsets();
        }

        void _drawRegion(ref Scoped!Context cr,
                         pixels_t yOffset,
                         pixels_t heightPixels,
                         nframes_t regionOffset,
                         double alpha) {
            enum degrees = PI / 180.0;

            // save the existing cairo context state
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
                enum gradientScale1 = 0.80;
                enum gradientScale2 = 0.65;
                Pattern gradient = Pattern.createLinear(0, yOffset, 0, yOffset + height);
                gradient.addColorStopRgba(0,
                                          _regionColor.r * gradientScale1,
                                          _regionColor.g * gradientScale1,
                                          _regionColor.b * gradientScale1,
                                          alpha);
                gradient.addColorStopRgba(1,
                                          _regionColor.r - gradientScale2,
                                          _regionColor.g - gradientScale2,
                                          _regionColor.b - gradientScale2,
                                          alpha);

                cr.setSource(gradient);
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
                    cr.moveTo(xOffset, channelYOffset +
                              region.getMax(channelIndex,
                                            cacheIndex,
                                            samplesPerPixel,
                                            pixelsOffset + startPixel) * (channelHeight / 2));
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
                        cr.lineTo(xOffset + scaledI, channelYOffset -
                                  clamp(region.getMax(channelIndex,
                                                      cacheIndex,
                                                      samplesPerPixel,
                                                      pixelsOffset + i), 0, 1) * (channelHeight / 2));
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
                        cr.lineTo(xOffset + scaledI, channelYOffset -
                                  clamp(region.getMin(channelIndex,
                                                      cacheIndex,
                                                      samplesPerPixel,
                                                      pixelsOffset + width - i), -1, 0) * (channelHeight / 2));
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
                                              yOffset + (channelIndex * channelHeight));
                                    cr.lineTo(xOffset + onset / samplesPerPixel - pixelsOffset,
                                              yOffset + ((channelIndex + 1) * channelHeight));
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

            // restore the cairo context state
            cr.restore();
        }

        nframes_t[][] _onsets; // indexed as [channel][onset]
        nframes_t[] _onsetsLinked; // indexed as [onset]

        Color* _regionColor;
    }

    class TrackView {
    public:
        void addRegion(Region region, nframes_t sampleRate) {
            _track.addRegion(region);

            RegionView regionView = new RegionView(region, &_trackColor);
            _regionViews ~= regionView;
            this.outer._regionViews ~= regionView;

            _configureHScroll();
        }
        void addRegion(Region region) {
            addRegion(region, _mixer.sampleRate);
        }

        void draw(ref Scoped!Context cr, pixels_t yOffset) {
            foreach(regionView; _regionViews) {
                Region r = regionView.region;
                if(_action == Action.moveRegion && regionView.selected) {
                    regionView.drawRegionMoving(cr, yOffset, _heightPixels);
                }
                else {
                    regionView.drawRegion(cr, yOffset, _heightPixels);
                }
            }
        }

        @property pixels_t heightPixels() const { return _heightPixels; }

    private:
        this(Track track, pixels_t heightPixels) {
            _track = track;
            _heightPixels = heightPixels;
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
        pixels_t _heightPixels;
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

    @property nframes_t samplesPerPixel() const { return _samplesPerPixel; }
    @property nframes_t viewOffset() const { return _viewOffset; }
    @property nframes_t viewWidthSamples() { return _canvas.viewWidthPixels * _samplesPerPixel; }

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

    @property nframes_t _viewMinSamples() { return 0; }
    @property nframes_t _viewMaxSamples() { return _mixer.nframes + viewWidthSamples; }

    void _configureHScroll() {
        _hAdjust.configure(_viewOffset,
                           _viewMinSamples,
                           _viewMaxSamples,
                           _samplesPerPixel * 50,
                           _samplesPerPixel * 100,
                           viewWidthSamples);
    }

    void _onHScrollChanged(Adjustment adjustment) {
        _viewOffset = cast(typeof(_viewOffset))(adjustment.getValue());
        _canvas.redraw();
    }

    void _createEditRegionMenu() {
        _editRegionMenu = new Menu();
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
        _configureHScroll();
    }
    void _zoomOut() {
        auto zoomCount = _zoomMultiplier;
        for(auto i = 0; i < zoomCount; ++i) {
            auto step = _zoomStep;
            _samplesPerPixel += step;
        }
        _canvas.redraw();
        _configureHScroll();
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
                foreach(regionView; _regionViews) {
                    if(regionView.selected) {
                        regionView.editMode = true;
                        _editRegion = regionView;
                        break;
                    }
                }
                break;

            default:
                // if the last mode was editRegion, unset the edit mode flag for the edited region
                if(_mode == Mode.editRegion) {
                    _editRegion.editMode = false;
                    _editRegion = null;
                }
                break;
        }

        _mode = mode;
        _canvas.redraw();
    }

    class Canvas : DrawingArea {
        enum timeMarkerFont = "Arial 10";

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

        @property pixels_t viewWidthPixels() {
            GtkAllocation size;
            getAllocation(size);
            return cast(pixels_t)(size.width);
        }
        @property pixels_t viewHeightPixels() {
            GtkAllocation size;
            getAllocation(size);
            return cast(pixels_t)(size.height);
        }

        @property pixels_t timestripHeightPixels() {
            enum timeStripHeight = 40;
            return timeStripHeight;
        }

        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(_refreshTimeout is null) {
                _refreshTimeout = new Timeout(cast(uint)(1.0 / refreshRate * 1000), &onRefresh, false);
            }

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.paint();

            drawTimestrip(cr);
            drawTracks(cr);
            drawMarkers(cr);
            drawTransport(cr);
            drawSelectBox(cr);

            return true;
        }

        void drawTimestrip(ref Scoped!Context cr) {
            enum primaryTickHeightFactor = 0.5;
            enum secondaryTickHeightFactor = 0.35;
            enum tertiaryTickHeightFactor = 0.2;

            // save the existing cairo context state
            cr.save();

            // draw the timestrip background
            cr.rectangle(0, 0, viewWidthPixels, timestripHeightPixels);
            Pattern gradient = Pattern.createLinear(0, 0, 0, timestripHeightPixels);
            gradient.addColorStopRgb(0, 0.2, 0.2, 0.2);
            gradient.addColorStopRgb(1, 0.0, 0.0, 0.0);
            cr.setSource(gradient);
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
                _timestripScaleFactor = 5.0;
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

                // draw primary tick
                cr.moveTo(xOffset, 0);
                cr.lineTo(xOffset, timestripHeightPixels * primaryTickHeightFactor);

                // draw one secondary tick
                cr.moveTo(xOffset + tickDistancePixels / 2, 0);
                cr.lineTo(xOffset + tickDistancePixels / 2, timestripHeightPixels * secondaryTickHeightFactor);

                // draw two tertiary ticks
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

                _timestripMarkerLayout.setText(timeString.data);

                cr.moveTo(timeMarkerXOffset, timestripHeightPixels * 0.5);
                PgCairo.updateLayout(cr, _timestripMarkerLayout);
                PgCairo.showLayout(cr, _timestripMarkerLayout);
            }
            cr.stroke();

            // restore the cairo context state
            cr.restore();
        }

        void drawTracks(ref Scoped!Context cr) {
            pixels_t yOffset = timestripHeightPixels;
            foreach(t; _trackViews) {
                t.draw(cr, yOffset);
                yOffset += t.heightPixels;
            }
        }

        void drawTransport(ref Scoped!Context cr) {
            enum transportHeadWidth = 16;
            enum transportHeadHeight = 10;

            // save the existing cairo context state
            cr.save();

            if(_action == Action.moveTransport) {
                _transportPixelsOffset = clamp(_mouseX, 0, (viewOffset + viewWidthSamples > _mixer.nframes) ?
                                               ((_mixer.nframes - viewOffset) / samplesPerPixel) : viewWidthPixels);
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

            // restore the cairo context state
            cr.restore();
        }

        void drawSelectBox(ref Scoped!Context cr) {
            if(_action == Action.selectBox) {
                // save the existing cairo context state
                cr.save();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.NONE);

                cr.setLineWidth(1.0);
                cr.rectangle(_selectMouseX, _selectMouseY, _mouseX - _selectMouseX, _mouseY - _selectMouseY);
                cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                cr.fillPreserve();
                cr.setSourceRgb(0.0, 1.0, 0.0);
                cr.stroke();

                // restore the cairo context state
                cr.restore();
            }
        }

        void drawMarkers(ref Scoped!Context cr) {
            // save the existing cairo context state
            cr.save();

            cr.setSourceRgb(1.0, 0.65, 0.0);
            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);

            pixels_t yOffset = timestripHeightPixels;
            foreach(marker; _markers) {
                if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples) {
                    pixels_t xOffset = (marker.offset - viewOffset) / samplesPerPixel;
                    cr.moveTo(xOffset, yOffset);
                    cr.lineTo(xOffset, viewHeightPixels);
                }
            }
            cr.stroke();

            // restore the cairo context state
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
            _configureHScroll();
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

            if(event.type == EventType.BUTTON_PRESS && event.button.button == leftButton) {
                // if the mouse is over the timestrip, move the transport
                if(_mouseY >= 0 && _mouseY < timestripHeightPixels) {
                    _setAction(Action.moveTransport);
                }
                else {
                    bool newAction;
                    switch(_mode) {
                        // implement different behaviors for button presses depending on the current mode
                        case Mode.arrange:
                            GdkModifierType state;
                            event.getState(state);
                            auto shiftPressed = state & GdkModifierType.SHIFT_MASK;

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
                                    if(_mouseX >= regionView.boundingBox.x0 && _mouseX < regionView.boundingBox.x1 &&
                                       _mouseY >= regionView.boundingBox.y0 && _mouseY < regionView.boundingBox.y1) {
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
                            // detect if the mouse is over an onset
                            if(_editRegion) {
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
                            break;

                        default:
                            break;
                    }
                    if(!newAction) {
                        _selectMouseX = _mouseX;
                        _selectMouseY = _mouseY;
                        _setAction(Action.selectBox);
                    }
                }
                redraw();
            }
            else if(event.type == EventType.BUTTON_PRESS && event.button.button == rightButton) {
                switch(_mode) {
                    case Mode.editRegion:
                        auto buttonEvent = event.button;
                        _linkChannelsMenuItem.setActive(_editRegion.linkChannels);
                        _editRegionMenu.showAll();
                        _editRegionMenu.popup(buttonEvent.button, buttonEvent.time);
                        return true;

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

                    // stretch the audio inside a region
                    case Action.moveOnset:
                        immutable(channels_t) singleChannelIndex = _moveOnsetChannel;
                        immutable(channels_t) nChannels =
                            _editRegion.linkChannels ? _editRegion.region.nChannels : 1;

                        immutable(nframes_t) onsetFrameStart =
                            _editRegion.getPrevOnset(_moveOnsetIndex, singleChannelIndex);
                        immutable(nframes_t) onsetFrameEnd =
                            _editRegion.getNextOnset(_moveOnsetIndex, singleChannelIndex);

                        immutable(double) firstScaleFactor = (_moveOnsetFrameSrc > onsetFrameStart) ?
                            (cast(double)(_moveOnsetFrameDest - onsetFrameStart) /
                             cast(double)(_moveOnsetFrameSrc - onsetFrameStart)) : 0;
                        immutable(double) secondScaleFactor = (onsetFrameEnd > _moveOnsetFrameSrc) ?
                            (cast(double)(onsetFrameEnd - _moveOnsetFrameDest) /
                             cast(double)(onsetFrameEnd - _moveOnsetFrameSrc)) : 0;

                        immutable(nframes_t) stretchStart =
                            _editRegion.getPrevOnset(_moveOnsetIndex, singleChannelIndex);
                        immutable(nframes_t) stretchEnd =
                            _editRegion.getNextOnset(_moveOnsetIndex, singleChannelIndex);

                        uint firstHalfLength = cast(uint)(_moveOnsetFrameSrc - onsetFrameStart);
                        uint secondHalfLength = cast(uint)(onsetFrameEnd - _moveOnsetFrameSrc);
                        float[][] firstHalfChannels = new float[][](nChannels);
                        float[][] secondHalfChannels = new float[][](nChannels);
                        float*[] firstHalfPtr = new float*[](nChannels);
                        float*[] secondHalfPtr = new float*[](nChannels);
                        for(auto i = 0; i < nChannels; ++i) {
                            float[] firstHalf = new float[](firstHalfLength);
                            float[] secondHalf = new float[](secondHalfLength);
                            firstHalfChannels[i] = firstHalf;
                            secondHalfChannels[i] = secondHalf;
                            firstHalfPtr[i] = firstHalf.ptr;
                            secondHalfPtr[i] = secondHalf.ptr;
                        }

                        if(_editRegion.linkChannels) {
                            foreach(channels_t channelIndex, channel; firstHalfChannels) {
                                foreach(i, ref sample; channel) {
                                    sample = _editRegion.region._audioBuffer
                                        [(onsetFrameStart + i) * _editRegion.region.nChannels + channelIndex];
                                }
                            }
                            foreach(channels_t channelIndex, channel; secondHalfChannels) {
                                foreach(i, ref sample; channel) {
                                    sample = _editRegion.region._audioBuffer
                                        [(_moveOnsetFrameSrc + i) * _editRegion.region.nChannels + channelIndex];
                                }
                            }
                        }
                        else {
                            foreach(i, ref sample; firstHalfChannels[0]) {
                                sample = _editRegion.region._audioBuffer
                                    [(onsetFrameStart + i) * _editRegion.region.nChannels + singleChannelIndex];
                            }
                            foreach(i, ref sample; secondHalfChannels[0]) {
                                sample = _editRegion.region._audioBuffer
                                    [(_moveOnsetFrameSrc + i) * _editRegion.region.nChannels + singleChannelIndex];
                            }
                        }

                        uint firstHalfOutputLength = cast(uint)(firstHalfLength * firstScaleFactor);
                        uint secondHalfOutputLength = cast(uint)(secondHalfLength * secondScaleFactor);
                        float[][] firstHalfOutputChannels = new float[][](nChannels);
                        float[][] secondHalfOutputChannels = new float[][](nChannels);
                        float*[] firstHalfOutputPtr = new float*[](nChannels);
                        float*[] secondHalfOutputPtr = new float*[](nChannels);
                        for(auto i = 0; i < nChannels; ++i) {
                            float[] firstHalfOutput = new float[](firstHalfOutputLength);
                            float[] secondHalfOutput = new float[](secondHalfOutputLength);
                            firstHalfOutputChannels[i] = firstHalfOutput;
                            secondHalfOutputChannels[i] = secondHalfOutput;
                            firstHalfOutputPtr[i] = firstHalfOutput.ptr;
                            secondHalfOutputPtr[i] = secondHalfOutput.ptr;
                        }

                        RubberBandState rState = rubberband_new(_mixer.sampleRate,
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

                        rState = rubberband_new(_mixer.sampleRate,
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

                        if(_editRegion.linkChannels) {
                            foreach(channels_t channelIndex, channel; firstHalfOutputChannels) {
                                foreach(i, sample; channel) {
                                    _editRegion.region.setSampleLocal(channelIndex,
                                                                      cast(nframes_t)(onsetFrameStart + i),
                                                                      sample);
                                }
                            }
                            foreach(channels_t channelIndex, channel; secondHalfOutputChannels) {
                                foreach(i, sample; channel) {
                                    _editRegion.region.setSampleLocal(channelIndex,
                                                                      cast(nframes_t)(_moveOnsetFrameDest + i),
                                                                      sample);
                                }
                            }
                        }
                        else {
                            foreach(i, sample; firstHalfOutputChannels[0]) {
                                _editRegion.region.setSampleLocal(singleChannelIndex,
                                                                  cast(nframes_t)(onsetFrameStart + i),
                                                                  sample);
                            }
                            foreach(i, sample; secondHalfOutputChannels[0]) {
                                _editRegion.region.setSampleLocal(singleChannelIndex,
                                                                  cast(nframes_t)(_moveOnsetFrameDest + i),
                                                                  sample);
                            }
                        }

                        _editRegion.region._initCache();
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
                ScrollDirection direction;
                event.getScrollDirection(direction);
                switch(direction) {
                    case ScrollDirection.LEFT:
                        if(_hAdjust.getStepIncrement() <= viewOffset) {
                            _viewOffset -= _hAdjust.getStepIncrement();
                        }
                        else {
                            _viewOffset = _viewMinSamples;
                        }
                        _hAdjust.setValue(viewOffset);
                        redraw();
                        break;

                    case ScrollDirection.RIGHT:
                        if(_hAdjust.getStepIncrement() + viewOffset <= _mixer.nframes) {
                            _viewOffset += _hAdjust.getStepIncrement();
                        }
                        else {
                            _viewOffset = _viewMaxSamples;
                        }
                        _hAdjust.setValue(viewOffset);
                        redraw();
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
                            _markers[event.key.keyval] = Marker(_mixer.transportOffset, ""); // TODO implement name
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
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;
                auto metaPressed = state & GdkModifierType.MOD1_MASK;

                switch(event.key.keyval) {
                    case GdkKeysyms.GDK_space:
                        // toggle play/pause for the mixer
                        if(_mixer.playing) {
                            _mixer.pause();
                        }
                        else {
                            _mixer.play();
                        }
                        break;

                    case GdkKeysyms.GDK_equal:
                        _zoomIn();
                        break;

                    case GdkKeysyms.GDK_minus:
                        _zoomOut();
                        break;

                    case GdkKeysyms.GDK_Aring:
                        if(metaPressed) {
                            // move the transport and view to the beginning of the project
                            _mixer.transportOffset = 0;
                            _viewOffset = _viewMinSamples;
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_acute:
                        if(metaPressed) {
                            // move the transport to end of the project and center the view on the transport
                            _mixer.transportOffset = _mixer.nframes > 0 ? _mixer.nframes - 1 : 0;
                            if(_viewMaxSamples >= (viewWidthSamples / 2) * 3) {
                                _viewOffset = _viewMaxSamples - (viewWidthSamples / 2) * 3;
                            }
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_a:
                        if(controlPressed) {
                            // move the transport to the minimum offset of all selected regions
                            if(!(_earliestSelectedRegion is null)) {
                                _mixer.transportOffset = _earliestSelectedRegion.region.offset;
                                redraw();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_e:
                        if(controlPressed) {
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
                                _viewOffset = _viewMinSamples;
                            }
                            _setAction(Action.centerView);
                        }
                        else {
                            if(_mixer.transportOffset < viewWidthSamples / 2) {
                                _viewOffset = _viewMinSamples;
                            }
                            else if(_mixer.transportOffset > _viewMaxSamples - viewWidthSamples / 2) {
                                _viewOffset = _viewMaxSamples;
                            }
                            else {
                                _viewOffset = _mixer.transportOffset - viewWidthSamples / 2;
                            }
                            _setAction(Action.centerViewStart);
                        }
                        redraw();
                        _configureHScroll();
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

    Mixer _mixer;
    TrackView[] _trackViews;
    RegionView[] _regionViews;
    RegionView _editRegion;
    RegionView _earliestSelectedRegion;
    Marker[uint] _markers;

    PgLayout _headerLabelLayout;
    PgLayout _timestripMarkerLayout;
    float _timestripScaleFactor = 1;

    nframes_t _samplesPerPixel;
    nframes_t _viewOffset;

    Canvas _canvas;
    Adjustment _hAdjust;
    Scrollbar _hScroll;
    Timeout _refreshTimeout;

    Menu _editRegionMenu;
    CheckMenuItem _linkChannelsMenuItem;

    pixels_t _transportPixelsOffset;

    Mode _mode;
    Action _action;
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

    auto opts = getopt(args,
                       "driver|d", "Available audio drivers: " ~ reduce!((string x, y) => x ~ ", " ~ y)
                       (availableAudioDrivers[0], availableAudioDrivers[1 .. $]), &audioDriver);

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
                    mixer = new CoreAudioMixer(appName);
                }
                else {
                    mixer = new JackMixer(appName);
                }
        }

        Main.init(args);
        AppMainWindow win = new AppMainWindow(appName, mixer);
        win.setDefaultSize(960, 600);

        ArrangeView arrangeView = new ArrangeView(appName, mixer);
        win.add(arrangeView);

        try {
            for(auto i = 1; i < args.length; ++i) {
                Region testRegion = Region.fromFile(args[i]);
                ArrangeView.TrackView trackView = arrangeView.createTrackView();
                trackView.addRegion(testRegion);
            }
        }
        catch(FileError e) {
            writeln("Fatal file error: ", e.msg);
            return;
        }

        win.showAll();
        Main.run();
    }
    catch(AudioError e) {
        writeln("Fatal audio error: ", e.msg);
        return;
    }
}
