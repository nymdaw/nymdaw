module dseq;

import std.stdio;
import core.stdc.string;

import jack.client;
import sndfile.sndfile;

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

class Region {
public:
    this(sample_t[] audioBuffer, channels_t nChannels) {
        _audioBuffer = audioBuffer;
        _nChannels = nChannels;
        _nframes = cast(nframes_t)(audioBuffer.length / nChannels);
    }

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
        sample_t[] audioBuffer = new sample_t[](sfinfo.frames * sfinfo.channels);

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

        return new Region(audioBuffer, cast(channels_t)(sfinfo.channels));
    }

    const(sample_t) opIndex(nframes_t frame, channels_t channelIndex) const {
        return frame >= offset ?
            (frame < _offset + _nframes ? _audioBuffer[(frame - _offset) * _nChannels + channelIndex] : 0 ) : 0;
    }

    @property const(sample_t[]) audioBuffer() const { return _audioBuffer; }
    @property const(channels_t) nChannels() const { return _nChannels; }
    @property const(nframes_t) nframes() const { return _nframes; }
    @property const(nframes_t) offset() const { return _offset; }

private:
    sample_t[] _audioBuffer; // raw audio data for all channels
    channels_t _nChannels; // number of channels in the audio data
    nframes_t _nframes; // number of frames in the audio data, where 1 frame contains 1 sample for each channel

    nframes_t _offset; // the offset, in frames, for the start of this region
}

class Track {
public:
    void addRegion(Region region) {
        _regions ~= region;
        _resizeIfNecessary(region.offset + region.nframes);
    }

package:
    this(bool delegate(nframes_t) resizeIfNecessary) {
        _resizeIfNecessary = resizeIfNecessary;
    }
    
    void mixStereo(nframes_t offset, nframes_t bufNFrames, sample_t* mixBuf1, sample_t* mixBuf2) const {
        for(nframes_t i = 0; i < bufNFrames; ++i) {
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

    @property const(nframes_t) nframes() const { return _nframes; }
    @property nframes_t nframes(nframes_t newNFrames) { return (_nframes = newNFrames); }

    @property const(nframes_t) offset() const { return _offset; }
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }

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
            memset(mixBuf1, 0, jack_nframes_t.sizeof * bufNFrames);
            memset(mixBuf2, 0, jack_nframes_t.sizeof * bufNFrames);

            if(_playing && _offset >= _nframes) {
                _playing = false;
                _offset = _nframes;
            }
            else if(_playing) {
                foreach(t; _tracks) {
                    t.mixStereo(_offset, bufNFrames, mixBuf1, mixBuf2);
                }

                _offset += bufNFrames;
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
    nframes_t _offset;
    bool _playing;
}

void main(string[] args) {
    string appName = "dseq";

    if(!(args.length >= 2)) {
        writeln("Must provide audio file argument!");
        return;
    }

    try {
        Mixer mixer = new Mixer(appName);

        Region testRegion;
        try {
            testRegion = Region.fromFile(args[1]);
        }
        catch(FileError e) {
            writeln("Fatal file error: ", e.msg);
        }

        Track track = mixer.createTrack();
        track.addRegion(testRegion);
        mixer.play();
    }
    catch(AudioError e) {
        writeln("Fatal audio error: ", e.msg);
    }

    stdin.readln();
}
