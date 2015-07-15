module dseq;

import std.stdio;
import std.algorithm;
import std.array;
import std.path;
import std.math;

import jack.client;
import sndfile;
import samplerate;
import aubio;

import gtk.MainWindow;
import gtk.Main;
import gtk.Widget;
import gtk.VBox;
import gtk.DrawingArea;
import gtk.Adjustment;
import gtk.Scrollbar;
import gdk.Cursor;
import gdk.Display;
import gdk.Event;
import gdk.Keysyms;
import gdk.Window;
import gtkc.gtktypes;

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

alias nframes_t = jack_nframes_t;
alias sample_t = jack_default_audio_sample_t;
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
    nframes_t[] getOnsets(channels_t channelIndex) const {
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
            for(auto sample = 0; sample < hopSize; ++sample) {
                hopBuffer.data[sample] = _audioBuffer[(sample + samplesRead) * nChannels + channelIndex];
            }
            aubio_onset_do(o, hopBuffer, onsetBuffer);
            if(onsetBuffer.data[0] != 0) {
                app.put(aubio_onset_get_last(o));
            }
        }
        del_aubio_onset(o);

        del_fvec(onsetBuffer);
        del_fvec(hopBuffer);
        aubio_cleanup();

        return app.data;
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

    // overload indexing to return the sample value at a given channel and frame, globally indexed
    sample_t opIndex(channels_t channelIndex, nframes_t frame) const {
        return frame >= offset ?
            (frame < _offset + _nframes ? _audioBuffer[(frame - _offset) * _nChannels + channelIndex] : 0) : 0;
    }

    @property const(sample_t[]) audioBuffer() const { return _audioBuffer; }
    @property nframes_t sampleRate() const { return _sampleRate; }
    @property channels_t nChannels() const { return _nChannels; }
    @property nframes_t nframes() const { return _nframes; }
    @property nframes_t offset() const { return _offset; }
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }
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

    static immutable(nframes_t[]) _cacheBinSizes = [10, 100];
    static assert(_cacheBinSizes.length > 0);

    WaveformCache[][] _waveformCacheList; // indexed as [channel][waveform]

    nframes_t _sampleRate; // sample rate of the audio data
    channels_t _nChannels; // number of channels in the audio data
    sample_t[] _audioBuffer; // raw audio data for all channels
    nframes_t _nframes; // number of frames in the audio data, where 1 frame contains 1 sample for each channel

    nframes_t _offset; // the offset, in frames, for the start of this region
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
    
    void mixStereo(nframes_t offset, nframes_t bufNFrames, sample_t* mixBuf1, sample_t* mixBuf2) const {
        for(auto i = 0; i < bufNFrames; ++i) {
            foreach(r; _regions) {
                mixBuf1[i] += r[0, offset + i];
                mixBuf2[i] += r[1, offset + i];
            }
        }
    }

private:
    Region[] _regions;
    bool delegate(nframes_t) _resizeIfNecessary;
}

class Mixer {
public:
    this(string appName) {
        try {
            _openJack(appName);
        }
        catch(JackError e) {
            throw new AudioError(e.msg);
        }
    }
    ~this() {
        _closeJack();
    }

    Track createTrack() {
        Track track = new Track(&resizeIfNecessary);
        _tracks ~= track;
        return track;
    }

    bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    @property nframes_t sampleRate() { return _client.get_sample_rate(); }

    @property nframes_t nframes() const { return _nframes; }
    @property nframes_t nframes(nframes_t newNFrames) { return (_nframes = newNFrames); }

    @property nframes_t transportOffset() const { return _transportOffset; }
    @property nframes_t transportOffset(nframes_t newOffset) { return (_transportOffset = min(newOffset, nframes)); }

    @property bool playing() const { return _playing; }
    void play() { _playing = true; }
    void pause() { _playing = false; }
    
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

            // initialize the buffers to silence
            import core.stdc.string: memset;
            memset(mixBuf1, 0, jack_nframes_t.sizeof * bufNFrames);
            memset(mixBuf2, 0, jack_nframes_t.sizeof * bufNFrames);

            if(_playing && _transportOffset >= _nframes) {
                _playing = false;
                _transportOffset = _nframes;
            }
            else if(_playing) {
                foreach(t; _tracks) {
                    t.mixStereo(_transportOffset, bufNFrames, mixBuf1, mixBuf2);
                }

                _transportOffset += bufNFrames;
            }

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
    Track[] _tracks;

    nframes_t _nframes;
    nframes_t _transportOffset;
    bool _playing;
}

enum Direction {
    left,
    right
}

struct BoundingBox {
    pixels_t x0, y0, x1, y1;
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
        moveOnset,
        moveRegion,
        moveTransport
    }

    this(string appName) {
        _mixer = new Mixer(appName);
        _samplesPerPixel = defaultSamplesPerPixel;

        super(false, 0);
        _canvas = new Canvas();
        _hAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
        _configureHScroll();
        _hAdjust.addOnValueChanged(&_onHScrollChanged);
        _hScroll = new Scrollbar(Orientation.HORIZONTAL, _hAdjust);

        packStart(_canvas, true, true, 0);
        packEnd(_hScroll, false, false, 0);
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
            _onsets = new nframes_t[][](region.nChannels);
            for(channels_t c = 0; c < region.nChannels; ++c) {
                _onsets[c] = region.getOnsets(c);
            }
        }

        // finds the index of any onset between (searchFrame - searchRadius) and (searchFrame + searchRadius)
        // if successful, returns true and stores the index in the searchIndex output argument
        bool getOnset(channels_t channelIndex,
                      nframes_t searchFrame,
                      nframes_t searchRadius,
                      out nframes_t foundFrame,
                      out size_t foundIndex) {
            // recursive binary search helper function
            bool getOnsetRec(channels_t channelIndex,
                             nframes_t searchFrame,
                             nframes_t searchRadius,
                             out nframes_t foundFrame,
                             out size_t foundIndex,
                             size_t leftIndex,
                             size_t rightIndex) {
                foundIndex = (leftIndex + rightIndex) / 2;
                foundFrame = _onsets[channelIndex][foundIndex];
                if(foundFrame >= searchFrame - searchRadius && foundFrame <= searchFrame + searchRadius) {
                    return true;
                }
                else if(leftIndex >= rightIndex) {
                    return false;
                }

                if(foundFrame < searchFrame) {
                    return getOnsetRec(channelIndex,
                                       searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       foundIndex + 1,
                                       rightIndex);
                }
                else {
                    return getOnsetRec(channelIndex,
                                       searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       leftIndex,
                                       foundIndex - 1);
                }
            }
            return getOnsetRec(channelIndex,
                               searchFrame,
                               searchRadius,
                               foundFrame,
                               foundIndex,
                               0,
                               _onsets[channelIndex].length - 1);
        }

        // move a specific onset given by onsetIndex, returns the new onset value
        nframes_t moveOnset(channels_t channelIndex,
                            size_t onsetIndex,
                            nframes_t relativeSamples,
                            Direction direction) {
            switch(direction) {
                case Direction.left:
                    nframes_t leftBound = (onsetIndex > 0) ? _onsets[channelIndex][onsetIndex - 1] : 0;
                    if(_onsets[channelIndex][onsetIndex] > relativeSamples &&
                        _onsets[channelIndex][onsetIndex] - relativeSamples > leftBound) {
                        return (_onsets[channelIndex][onsetIndex] -= relativeSamples);
                    }
                    else {
                        return (_onsets[channelIndex][onsetIndex] = leftBound);
                    }
                    break;

                case Direction.right:
                    nframes_t rightBound = (onsetIndex < _onsets[channelIndex].length - 1) ?
                        _onsets[channelIndex][onsetIndex + 1] : region.nframes - 1;
                    if(_onsets[channelIndex][onsetIndex] + relativeSamples < rightBound) {
                        return (_onsets[channelIndex][onsetIndex] += relativeSamples);
                    }
                    else {
                        return (_onsets[channelIndex][onsetIndex] = rightBound);
                    }
                    break;

                default:
                    break;
            }
            return 0;
        }

        nframes_t getPrevOnset(channels_t channelIndex, size_t onsetIndex) const {
            return (onsetIndex > 0) ? _onsets[channelIndex][onsetIndex - 1] : 0;
        }
        nframes_t getNextOnset(channels_t channelIndex, size_t onsetIndex) const {
            return (onsetIndex < _onsets[channelIndex].length - 1) ?
                _onsets[channelIndex][onsetIndex + 1] : region.nframes - 1;
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

        @property bool editMode(bool enabled) {
            if(enabled && _onsets is null) {
                computeOnsets();
            }
            return (_editMode = enabled);
        }
        @property bool editMode() const { return _editMode; }

    private:
        this(Region region) {
            this.region = region;
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

                Pattern gradient = Pattern.createLinear(0, yOffset, 0, yOffset + height);
                gradient.addColorStopRgba(0.0, 0.0, 0.0, 1.0, alpha);
                gradient.addColorStopRgba(height, 1.0, 0.0, 0.0, alpha);

                cr.setSource(gradient);
                cr.fillPreserve();

                // if this region is selected, highlight the borders and region header
                cr.setLineWidth(borderWidth);
                if(selected && _mode == Mode.editRegion) {
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
                    _headerLabelLayout.setText(region.name);
                    desc = PgFontDescription.fromString(headerFont);
                    _headerLabelLayout.setFontDescription(desc);
                    desc.free();
                }

                cr.save();
                cr.translate(xOffset + borderWidth, yOffset);
                cr.setSourceRgba(0.5, 0.5, 1.0, alpha);
                PgCairo.updateLayout(cr, _headerLabelLayout);
                PgCairo.showLayout(cr, _headerLabelLayout);
                cr.restore();

                // compute audio rendering parameters
                height = heightPixels - headerHeight; // height of the area containing the waveform, in pixels
                yOffset += headerHeight; // y-coordinate in pixels where the waveform rendering begins
                // sampleOffset is the frame index at which to begin rendering the waveform
                auto sampleOffset = (viewOffset > regionOffset) ? (viewOffset - regionOffset) / samplesPerPixel : 0;
                auto channelHeight = height / region.nChannels; // height of each channel in pixels

                bool moveOnset;
                nframes_t moveOnsetFrameStart, moveOnsetFrameEnd;
                pixels_t moveOnsetPixelsStart,
                    moveOnsetPixelsCenterSrc,
                    moveOnsetPixelsCenterDest,
                    moveOnsetPixelsEnd;
                double firstScaleFactor, secondScaleFactor;
                if(_action == Action.moveOnset) {
                    moveOnset = true;
                    moveOnsetFrameStart = getPrevOnset(_moveOnsetChannel, _moveOnsetIndex);
                    moveOnsetFrameEnd = getNextOnset(_moveOnsetChannel, _moveOnsetIndex);
                    moveOnsetPixelsStart = (moveOnsetFrameStart - sampleOffset) / samplesPerPixel;
                    moveOnsetPixelsCenterSrc = (_moveOnsetFrameSrc - sampleOffset) / samplesPerPixel;
                    moveOnsetPixelsCenterDest = (_moveOnsetFrameDest - sampleOffset) / samplesPerPixel;
                    moveOnsetPixelsEnd = (moveOnsetFrameEnd - sampleOffset) / samplesPerPixel;
                    firstScaleFactor = (_moveOnsetFrameSrc > moveOnsetFrameStart) ?
                        (cast(double)(_moveOnsetFrameDest - moveOnsetFrameStart) /
                         cast(double)(_moveOnsetFrameSrc - moveOnsetFrameStart)) : 0;
                    secondScaleFactor = (moveOnsetFrameEnd > _moveOnsetFrameSrc) ?
                        (cast(double)(moveOnsetFrameEnd - _moveOnsetFrameDest) /
                         cast(double)(moveOnsetFrameEnd - _moveOnsetFrameSrc)) : 0;
                }

                enum OnsetDrawState { init, firstHalf, secondHalf, complete };
                OnsetDrawState onsetDrawState;

                // draw the region's waveform
                auto cacheIndex = region.getCacheIndex(_zoomStep);
                auto channelYOffset = yOffset + (channelHeight / 2);
                for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                    cr.newSubPath();
                    cr.moveTo(xOffset, channelYOffset +
                              region.getMax(channelIndex,
                                            cacheIndex,
                                            samplesPerPixel,
                                            0) * (channelHeight / 2));
                    for(auto i = 1; i < width; ++i) {
                        pixels_t scaledI = i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || _moveOnsetLinkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(i >= moveOnsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(i >= moveOnsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(moveOnsetPixelsStart +
                                                                 (i - moveOnsetPixelsStart) * firstScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(i >= moveOnsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(moveOnsetPixelsCenterDest +
                                                                 (i - moveOnsetPixelsCenterSrc) * secondScaleFactor);

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
                                                      sampleOffset + i), 0, 1) * (channelHeight / 2));
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1; i <= width; ++i) {
                        pixels_t scaledI = width - i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || _moveOnsetLinkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(width - i <= moveOnsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(width - i <= moveOnsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (moveOnsetPixelsCenterDest +
                                             ((width - i) - moveOnsetPixelsCenterSrc) * secondScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(width - i <= moveOnsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (moveOnsetPixelsStart +
                                             ((width - i) - moveOnsetPixelsStart) * firstScaleFactor);
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
                                                      sampleOffset + width - i), -1, 0) * (channelHeight / 2));
                    }
                    cr.closePath();
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    cr.fill();
                    channelYOffset += channelHeight;
                }

                // if the edit mode flag is set, draw the onsets
                if(editMode) {
                    foreach(channelIndex, channel; _onsets) {
                        foreach(onset; channel) {
                            if(onset + regionOffset >= viewOffset &&
                               onset + regionOffset < viewOffset + viewWidthSamples) {
                                cr.moveTo(xOffset + onset / samplesPerPixel - sampleOffset,
                                          yOffset + (channelIndex * channelHeight));
                                cr.lineTo(xOffset + onset / samplesPerPixel - sampleOffset,
                                          yOffset + ((channelIndex + 1) * channelHeight));
                            }
                        }
                    }
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.setLineWidth(1.0);
                    cr.stroke();
                }
            }

            // restore the cairo context state
            cr.restore();
        }

        bool _editMode;
        nframes_t[][] _onsets; // indexed as [channel][onset]

        PgLayout _headerLabelLayout;
    }

    class TrackView {
    public:
        void addRegion(Region region, nframes_t sampleRate) {
            _track.addRegion(region);

            RegionView regionView = new RegionView(region);
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
        }

        Track _track;
        pixels_t _heightPixels;
        RegionView[] _regionViews;
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
    @property nframes_t _zoomStep() const {
        if(samplesPerPixel <= 100) {
            return 10;
        }
        else {
            return 100;
        }
    }

    void _configureHScroll() {
        _hAdjust.configure(0,
                           0,
                           _mixer.nframes + viewWidthSamples,
                           _samplesPerPixel * 50,
                           _samplesPerPixel * 100,
                           viewWidthSamples);
    }

    void _onHScrollChanged(Adjustment adjustment) {
        _viewOffset = cast(typeof(_viewOffset))(adjustment.getValue());
        _canvas.redraw();
    }

    void _zoomIn() {
        _samplesPerPixel = max(_samplesPerPixel - _zoomStep, 10);
        _canvas.redraw();
    }
    void _zoomOut() {
        _samplesPerPixel += _zoomStep;
        _canvas.redraw();
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
        _action = action;
        _setCursor();
    }

    void _setMode(Mode mode) {
        switch(mode) {
            case Mode.editRegion:
                // enable edit mode for selected regions
                foreach(regionView; _regionViews) {
                    if(regionView.selected) {
                        regionView.editMode = true;
                    }
                }
                break;

            default:
                // if the last mode was editRegion, unset the edit mode flag for selected regions
                if(_mode == Mode.editRegion) {
                    foreach(regionView; _regionViews) {
                        if(regionView.selected) {
                            regionView.editMode = false;
                        }
                    }
                }
                break;
        }

        _mode = mode;
        _canvas.redraw();
    }

    class Canvas : DrawingArea {
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
            drawTransport(cr);

            return true;
        }

        void drawTimestrip(ref Scoped!Context cr) {
            // save the existing cairo context state
            cr.save();

            // draw the timestrip background
            cr.rectangle(0, 0, viewWidthPixels, timestripHeightPixels);
            cr.setSourceRgb(0.1, 0.1, 0.1);
            cr.fill();

            // draw the time ticks (for seconds)            
            cr.setSourceRgb(1.0, 1.0, 1.0);
            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);
            for(auto i = viewOffset + ((viewOffset + _mixer.sampleRate) % _mixer.sampleRate);
                i < viewOffset + viewWidthSamples; i += _mixer.sampleRate) {
                cr.moveTo((i - viewOffset) / samplesPerPixel, 0);
                cr.lineTo((i - viewOffset) / samplesPerPixel, timestripHeightPixels * 0.5);
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
                        foreach(regionView; _regionViews) {
                            if(regionView.selected) {
                                regionView.selectedOffset = regionView.region.offset;
                            }
                        }
                        redraw();
                        break;

                    case Action.moveRegion:
                        foreach(regionView; _regionViews) {
                            if(regionView.selected) {
                                nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                                if(_mouseX > prevMouseX) {
                                    regionView.selectedOffset += deltaXSamples;
                                }
                                else if(regionView.selectedOffset > abs(deltaXSamples)) {
                                    regionView.selectedOffset -= deltaXSamples;
                                }
                                else {
                                    regionView.selectedOffset = 0;
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
                                _moveOnsetFrameDest = regionView.moveOnset(_moveOnsetChannel,
                                                                           _moveOnsetIndex,
                                                                           deltaXSamples,
                                                                           direction);
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
            if(event.type == EventType.BUTTON_PRESS && event.button.button == 1) {
                // if the mouse is over the timestrip, move the transport
                if(_mouseY >= 0 && _mouseY < timestripHeightPixels) {
                    _setAction(Action.moveTransport);
                }
                else {
                    switch(_mode) {
                        // implement different behaviors for button presses depending on the current mode
                        case Mode.arrange:
                            // detect if the mouse is over an audio region; if so, select that region
                            bool selectedRegion;
                            foreach(regionView; _regionViews) {
                                if(_mouseX >= regionView.boundingBox.x0 && _mouseX < regionView.boundingBox.x1 &&
                                   _mouseY >= regionView.boundingBox.y0 && _mouseY < regionView.boundingBox.y1) {
                                    regionView.selected = true;
                                    selectedRegion = true;
                                    _setAction(Action.selectRegion);
                                }
                            }

                            // otherwise, deselect all audio regions
                            if(!selectedRegion) {
                                foreach(regionView; _regionViews) {
                                    regionView.selected = false;
                                }
                            }
                            break;

                        case Mode.editRegion:
                            // detect if the mouse is over an onset
                            foreach(regionView; _regionViews) {
                                if(regionView.selected) {
                                    _moveOnsetChannel = regionView.mouseOverChannel(_mouseY);
                                    if(regionView.getOnset(_moveOnsetChannel,
                                                           viewOffset + _mouseX * samplesPerPixel -
                                                           regionView.region.offset,
                                                           mouseOverThreshold * samplesPerPixel,
                                                           _moveOnsetFrameSrc,
                                                           _moveOnsetIndex)) {
                                        _moveOnsetFrameDest = _moveOnsetFrameSrc;
                                        _setAction(Action.moveOnset);
                                    }
                                }
                            }
                            break;

                        default:
                            break;
                    }
                }
                redraw();
            }
            return false;
        }

        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == 1) {
                // reset the cursor if necessary
                switch(_action) {
                    case Action.selectRegion:
                        _setAction(Action.none);
                        redraw();
                        break;

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

                    case Action.moveOnset:
                        // TODO stretch audio here
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
                            _hAdjust.setValue(viewOffset);
                            redraw();
                        }
                        break;

                    case ScrollDirection.RIGHT:
                        if(_hAdjust.getStepIncrement() + viewOffset <= _mixer.nframes) {
                            _viewOffset += _hAdjust.getStepIncrement();
                            _hAdjust.setValue(viewOffset);
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
                switch(event.key.keyval) {
                    case GdkKeysyms.GDK_space:
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

                    case GdkKeysyms.GDK_e:
                        _setMode(_mode == Mode.editRegion ? Mode.arrange : Mode.editRegion);
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

    nframes_t _samplesPerPixel;
    nframes_t _viewOffset;

    Canvas _canvas;
    Adjustment _hAdjust;
    Scrollbar _hScroll;
    Timeout _refreshTimeout;

    pixels_t _transportPixelsOffset;

    Mode _mode;
    Action _action;
    pixels_t _mouseX;
    pixels_t _mouseY;

    bool _moveOnsetLinkChannels; // TODO implement
    size_t _moveOnsetIndex;
    channels_t _moveOnsetChannel;
    nframes_t _moveOnsetFrameSrc;
    nframes_t _moveOnsetFrameDest;
}

void main(string[] args) {
    string appName = "dseq";

    if(!(args.length >= 2)) {
        writeln("Must provide audio file argument!");
        return;
    }

    try {
        Main.init(args);
        MainWindow win = new MainWindow(appName);
        win.setDefaultSize(960, 600);

        ArrangeView arrangeView = new ArrangeView(appName);
        win.add(arrangeView);

        Region testRegion;
        try {
            testRegion = Region.fromFile(args[1]);
            ArrangeView.TrackView trackView = arrangeView.createTrackView();
            trackView.addRegion(testRegion);
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
