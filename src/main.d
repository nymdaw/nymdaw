module dseq;

import std.stdio;
import std.algorithm;
import std.math;

import jack.client;
import sndfile.sndfile;
import samplerate.samplerate;

import gtk.MainWindow;
import gtk.Main;
import gtk.Widget;
import gtk.VBox;
import gtk.DrawingArea;
import gtk.Adjustment;
import gtk.Scrollbar;
import gdk.Event;
import gdk.Keysyms;
import gtkc.gtktypes;

import glib.Timeout;

import cairo.Context;
import cairo.Pattern;
import cairo.Surface;

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
    this(nframes_t sampleRate, channels_t nChannels, sample_t[] audioBuffer) {
        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _audioBuffer = audioBuffer;
        _nframes = cast(typeof(_nframes))(audioBuffer.length / nChannels);

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

        return new Region(cast(nframes_t)(sfinfo.samplerate), cast(channels_t)(sfinfo.channels), audioBuffer);
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
            if(s < binSize && binSize % s == 0) {
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
//        writeln("length: ", _waveformCacheList[channelIndex][cacheIndex].maxValues.length);
//        writeln(sampleOffset, " ", sampleOffset * (binSize / cacheSize) , " .. ", (sampleOffset + 1) * (binSize / cacheSize));
        return _max(_waveformCacheList[channelIndex][cacheIndex].maxValues
                    [sampleOffset * (binSize / cacheSize) .. (sampleOffset + 1) * (binSize / cacheSize)]);
    }

    sample_t opIndex(nframes_t frame, channels_t channelIndex) const {
        return frame >= offset ?
            (frame < _offset + _nframes ? _audioBuffer[(frame - _offset) * _nChannels + channelIndex] : 0) : 0;
    }

    @property const(sample_t[]) audioBuffer() const { return _audioBuffer; }
    @property nframes_t sampleRate() const { return _sampleRate; }
    @property channels_t nChannels() const { return _nChannels; }
    @property nframes_t nframes() const { return _nframes; }
    @property nframes_t offset() const { return _offset; }

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

    static immutable(nframes_t[]) _cacheBinSizes = [ 10, 100, 1000, 10000 ];
    static assert(_cacheBinSizes.length > 0);

    WaveformCache[][] _waveformCacheList; // indexed as [channel][waveform]

    nframes_t _sampleRate; // sample rate of the audio data
    channels_t _nChannels; // number of channels in the audio data
    sample_t[] _audioBuffer; // raw audio data for all channels
    nframes_t _nframes; // number of frames in the audio data, where 1 frame contains 1 sample for each channel

    nframes_t _offset; // the offset, in frames, for the start of this region
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
                mixBuf1[i] += r[offset + i, 0];
                mixBuf2[i] += r[offset + i, 1];
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

class ArrangeView : VBox {
public:
    enum defaultSamplesPerPixel = 500; // default zoom level, in samples per pixel
    enum defaultTrackHeightPixels = 200; // default height in pixels of new tracks in the arrange view
    enum zoomStep = 100; // unit for zoom increments in samples per pixel
    enum refreshRate = 50; // rate in hertz at which to redraw the view when the transport is playing

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

    class TrackView {
    public:
        void addRegion(Region region, nframes_t sampleRate) {
            _track.addRegion(region);
            _configureHScroll();
        }
        void addRegion(Region region) {
            addRegion(region, _mixer.sampleRate);
        }

        void draw(ref Scoped!Context cr, pixels_t yOffset) {
            foreach(r; _track.regions) {
                if((r.offset >= viewOffset && r.offset < viewOffset + viewWidthSamples) ||
                   (r.offset < viewOffset &&
                    (r.offset + r.nframes >= viewOffset || r.offset + r.nframes <= viewOffset + viewWidthSamples))) {
                    _drawRegion(cr, r, yOffset);
                }
            }
        }

        @property pixels_t heightPixels() const { return _heightPixels; }

    private:
        this(Track track, pixels_t heightPixels) {
            _track = track;
            _heightPixels = heightPixels;
        }

        // this function assumes that the region is within the visible area of the arrange view
        void _drawRegion(ref Scoped!Context cr, const(Region) region, pixels_t yOffset) {
            enum radius = 4; // radius of the rounded corners of the region, in pixels
            enum borderWidth = 1; // width of the edges of the region, in pixels
            enum degrees = PI / 180.0;

            immutable(pixels_t) xOffset =
                (viewOffset < region.offset) ? (region.offset - viewOffset) / samplesPerPixel : 0;
            immutable(pixels_t) height = _heightPixels;

            // calculate the width, in pixels, of the visible area of the given region
            pixels_t width;
            if(region.offset >= viewOffset) {
                // the region begins after the view offset, and ends within the view
                if(region.offset + region.nframes <= viewOffset + viewWidthSamples) {
                    width = max(region.nframes / samplesPerPixel, 2 * radius);
                }
                // the region begins after the view offset, and ends past the end of the view
                else {
                    width = (viewWidthSamples - (region.offset - viewOffset)) / samplesPerPixel;
                }
            }
            else {
                // the region begins before the view offset, and ends within the view
                if(region.offset + region.nframes < viewOffset + viewWidthSamples) {
                    width = (region.offset + region.nframes - viewOffset) / samplesPerPixel;
                }
                // the region begins before the view offset, and ends past the end of the view
                else {
                    width = viewWidthSamples / samplesPerPixel;
                }
            }

            // these variables designate whether the left and right endpoints of the given region are visible
            bool lCorners = region.offset + (radius * samplesPerPixel) >= viewOffset;
            bool rCorners =
                (region.offset + region.nframes) - (radius * samplesPerPixel) <= viewOffset + viewWidthSamples;

            cr.newSubPath();
            // top left corner
            if(lCorners) {
                cr.arc(xOffset + radius, yOffset + radius, radius, 180 * degrees, 270 * degrees);
            }
            else {
                cr.moveTo(xOffset - borderWidth, yOffset);
                cr.lineTo(xOffset + width + (rCorners ? -radius : borderWidth), yOffset);
            }

            // right corners
            if(rCorners) {
                cr.arc(xOffset + width - radius, yOffset + radius, radius, -90 * degrees, 0 * degrees);
                cr.arc(xOffset + width - radius, yOffset + height - radius, radius, 0 * degrees, 90 * degrees);
            }
            else {
                cr.lineTo(xOffset + width + borderWidth, yOffset);
                cr.lineTo(xOffset + width + borderWidth, yOffset + height);
            }

            // bottom left corner
            if(lCorners) {
                cr.arc(xOffset + radius, yOffset + height - radius, radius, 90 * degrees, 180 * degrees);
            }
            else {
                cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + height);
            }
            cr.closePath();

            Pattern gradient = Pattern.createLinear(0, yOffset, 0, yOffset + height);
            gradient.addColorStopRgb(0, 0, 0, 1);
            gradient.addColorStopRgb(height, 1, 0, 0);

            cr.setSource(gradient);
            cr.fillPreserve();

            cr.setSourceRgb(1.0, 1.0, 1.0);
            cr.setLineWidth(borderWidth);
            cr.stroke();

            // draw the region's waveform
            auto cacheIndex = region.getCacheIndex(samplesPerPixel);
            auto sampleOffset = (viewOffset > region.offset) ? (viewOffset - region.offset) / samplesPerPixel : 0;
            auto channelHeight = height / region.nChannels;
            auto channelYOffset = yOffset + (channelHeight / 2);

            for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                cr.newSubPath();
                cr.moveTo(xOffset, channelYOffset +
                          region.getMax(channelIndex,
                                        cacheIndex,
                                        samplesPerPixel,
                                        0) * (channelHeight / 2));
                for(auto i = 1; i < width; ++i) {
                    cr.lineTo(xOffset + i, channelYOffset -
                              clamp(region.getMax(channelIndex,
                                                  cacheIndex,
                                                  samplesPerPixel,
                                                  sampleOffset + i), 0, 1) * (channelHeight / 2));
                }
                for(auto i = 1; i <= width; ++i) {
                    cr.lineTo(xOffset + width - i, channelYOffset -
                              clamp(region.getMin(channelIndex,
                                                  cacheIndex,
                                                  samplesPerPixel,
                                                  sampleOffset + width - i), -1, 0) * (channelHeight / 2));
                }
                cr.closePath();
                cr.setSourceRgb(1, 1, 1);
                cr.fill();
                channelYOffset += channelHeight;
            }
        }

        Track _track;
        pixels_t _heightPixels;
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

        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(_refreshTimeout is null) {
                _refreshTimeout = new Timeout(cast(uint)(1.0 / refreshRate * 1000), &onRefresh, false);
            }

            cr.setSourceRgb(0, 0, 0);
            cr.paint();

            drawTracks(cr);
            drawTransport(cr);

            return true;
        }

        void drawTracks(ref Scoped!Context cr) {
            pixels_t yOffset = 0;
            foreach(t; _trackViews) {
                t.draw(cr, yOffset);
                yOffset += t.heightPixels;
            }
        }

        void drawTransport(ref Scoped!Context cr) {
            enum transportHeadWidth = 16;
            enum transportHeadHeight = 10;

            if(_buttonIsDown) {
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

        void onSizeAllocate(GtkAllocation* allocation, Widget widget) {
            _configureHScroll();
        }

        bool onRefresh() {
            if(_mixer.playing) {
                redraw();
            }
            return true;
        }

        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                if(_buttonIsDown) {
                    redraw();
                }
            }
            return true;
        }

        bool onButtonPress(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_PRESS && event.button.button == 1) {
                _buttonIsDown = true;
                redraw();
            }
            return false;
        }

        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == 1) {
                _buttonIsDown = false;
                _mixer.transportOffset = viewOffset + (clamp(_mouseX, 0, viewWidthPixels) * samplesPerPixel);
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
                if(event.key.keyval == GdkKeysyms.GDK_space) {
                    if(_mixer.playing) {
                        _mixer.pause();
                    }
                    else {
                        _mixer.play();
                    }
                }
            }
            return false;
        }
    }

    Mixer _mixer;
    TrackView[] _trackViews;

    nframes_t _samplesPerPixel;
    nframes_t _viewOffset;

    Canvas _canvas;
    Adjustment _hAdjust;
    Scrollbar _hScroll;
    Timeout _refreshTimeout;

    pixels_t _transportPixelsOffset;
    bool _buttonIsDown;
    pixels_t _mouseX;
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
