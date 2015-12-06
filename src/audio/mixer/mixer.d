module audio.mixer.mixer;

private import std.file;
private import std.string;

private import sndfile;

private import util.scopedarray;

public import audio.masterbus;
public import audio.timeline;
public import audio.track;
public import audio.types;

/// This class handles all audio output, such as real-time output to hardware or offline output to a file.
/// It handles the master bus, stores all tracks in the session in an array,
/// and provides routines to control the "transport", which indicates the temporal position of audio playback
/// for the session.
/// It also provides abstract methods to initialize and uninitialize a specific audio driver.
/// Implementations of this class are responsible for setting up an audio thread and callback, which
/// should call either `mixStereoInterleaved` or `mixStereoNonInterleaved` to fill the output device's
/// audio buffers in real time.
/// Note this class's constructor initializes the driver, but the user is responsible for manually
/// calling `cleanupMixer` when the application exits. This ensures that the application will properly
/// destroy the audio thread and exit cleanly, without a segmentation fault.
abstract class Mixer {
public:
    /// Params:
    /// appName = The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    this(string appName) {
        _appName = appName;

        // abstract method to initialize the audio driver
        onInitialize();

        // initialize the master bus
        _masterBus = new MasterBus(sampleRate);

        // initialize the timeline
        _timeline = new Timeline();
    }

    /// Abstract method to get the sample rate, in samples per second, of the session
    @property nframes_t sampleRate();

    /// The user is responsible for calling cleanup() before the application exits
    /// or the mixer destructor is called.
    /// This ensures that the application won't crash when exiting.
    final void cleanup() {
        onCleanup();
    }

    /// Bounce the entire session to an audio file
    final void exportSessionToFile(string fileName,
                                   AudioFileFormat audioFileFormat,
                                   AudioBitDepth bitDepth,
                                   SaveState.Callback progressCallback = null) {
        // default to stereo for exporting
        enum exportChannels = 2;

        // helper function to remove the partially-written file in the case of an error
        void removeFile() {
            try {
                std.file.remove(fileName);
            }
            catch(FileException e) {
            }
        }

        SNDFILE* outfile;
        SF_INFO sfinfo;

        sfinfo.samplerate = sampleRate;
        sfinfo.frames = _timeline.nframes;
        sfinfo.channels = exportChannels;
        switch(audioFileFormat) {
            case AudioFileFormat.wavFilterName:
                sfinfo.format = SF_FORMAT_WAV;
                break;

            case AudioFileFormat.flacFilterName:
                sfinfo.format = SF_FORMAT_FLAC;
                break;

            case AudioFileFormat.oggVorbisFilterName:
                sfinfo.format = SF_FORMAT_OGG | SF_FORMAT_VORBIS;
                break;

            case AudioFileFormat.aiffFilterName:
                sfinfo.format = SF_FORMAT_AIFF;
                break;

            case AudioFileFormat.cafFilterName:
                sfinfo.format = SF_FORMAT_CAF;
                break;

            default:
                if(progressCallback !is null) {
                    progressCallback(SaveState.complete, 0);
                    removeFile();
                }
                throw new AudioError("Invalid audio file format");
        }

        if(audioFileFormat == AudioFileFormat.wavFilterName ||
           audioFileFormat == AudioFileFormat.aiffFilterName ||
           audioFileFormat == AudioFileFormat.cafFilterName) {
            if(bitDepth == AudioBitDepth.pcm16Bit) {
                sfinfo.format |= SF_FORMAT_PCM_16;
            }
            else if(bitDepth == AudioBitDepth.pcm24Bit) {
                sfinfo.format |= SF_FORMAT_PCM_24;
            }
        }

        // ensure the constructed sfinfo object is valid
        if(!sf_format_check(&sfinfo)) {
            if(progressCallback !is null) {
                progressCallback(SaveState.complete, 0);
                removeFile();
            }
            throw new AudioError("Invalid output file parameters for " ~ fileName);
        }

        // attempt to open the specified file
        outfile = sf_open(fileName.toStringz(), SFM_WRITE, &sfinfo);
        if(!outfile) {
            if(progressCallback !is null) {
                progressCallback(SaveState.complete, 0);
                removeFile();
            }
            throw new AudioError("Could not open file " ~ fileName ~ " for writing");
        }

        // close the file when leaving this scope
        scope(exit) sf_close(outfile);

        // reset the bounce transport
        _bounceTransportOffset = 0;

        // counters for updating the progress bar
        immutable size_t progressIncrement = (_timeline.nframes * exportChannels) / SaveState.stepsPerStage;
        size_t progressCount;

        // write all audio data in the current session to the specified file
        ScopedArray!(sample_t[]) buffer = new sample_t[](maxBufferLength * exportChannels);
        sf_count_t writeTotal;
        sf_count_t writeCount;
        while(writeTotal < _timeline.nframes * exportChannels) {
            auto immutable processNFrames =
                writeTotal + maxBufferLength * exportChannels < _timeline.nframes * exportChannels ?
                maxBufferLength * exportChannels : _timeline.nframes * exportChannels - writeTotal;

            bounceStereoInterleaved(cast(nframes_t)(processNFrames), exportChannels, buffer.ptr);

            static if(is(sample_t == float)) {
                writeCount = sf_write_float(outfile, buffer.ptr, processNFrames);
            }
            else if(is(sample_t == double)) {
                writeCount = sf_write_double(outfile, buffer.ptr, processNFrames);
            }

            if(writeCount != processNFrames) {
                if(progressCallback !is null) {
                    progressCallback(SaveState.complete, 0);
                    removeFile();
                }
                throw new AudioError("Could not write to file " ~ fileName);
            }

            writeTotal += writeCount;

            if(progressCallback !is null && writeTotal >= progressCount) {
                progressCount += progressIncrement;
                if(!progressCallback(SaveState.write,
                                     cast(double)(writeTotal) / cast(double)(_timeline.nframes * exportChannels))) {
                    removeFile();
                    return;
                }
            }
        }

        if(progressCallback !is null) {
            if(!progressCallback(SaveState.complete, 1)) {
                removeFile();
            }
        }
    }

    /// Reset the mixer to an empty state. This is useful for starting new sessions.
    final void reset() {
        _tracks = [];
        _soloTrack = false;
        _timeline.reset();
    }

    /// Construct a track object and register it with the mixer
    final Track createTrack() {
        Track track = new Track(sampleRate, _timeline);
        _tracks ~= track;
        return track;
    }

    /// Returns: The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    @property final string appName() const @nogc nothrow {
        return _appName;
    }

    /// The timeline for this mixer instance; contains the number of frames and transport
    @property final Timeline timeline() @nogc nothrow {
        return _timeline;
    }

    /// The master bus object associated with the mixer
    @property final MasterBus masterBus() @nogc nothrow {
        return _masterBus;
    }
    /// ditto 
    @property final const(MasterBus) masterBus() @nogc nothrow const {
        return _masterBus;
    }

    /// Whether any track registered with the mixer is currently in "solo" mode.
    @property final bool soloTrack() const @nogc nothrow { return _soloTrack; }
    /// ditto
    @property final bool soloTrack(bool enable) @nogc nothrow { return (_soloTrack = enable); }

    /// Mix all registered tracks into an interleaved stereo buffer using a specialized bounce transport.
    /// Params:
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
    final void bounceStereoInterleaved(nframes_t bufNFrames,
                                       channels_t nChannels,
                                       sample_t* mixBuf) {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        _bounceTracksStereoInterleaved(_bounceTransportOffset, bufNFrames, nChannels, mixBuf);

        _bounceTransportOffset += bufNFrames / nChannels;
    }

    /// Mix all registered tracks into an interleaved stereo buffer and update the playback transport
    /// Params:
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
    final void mixStereoInterleaved(nframes_t bufNFrames,
                                    channels_t nChannels,
                                    sample_t* mixBuf) @nogc nothrow {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(_timeline.playing) {
            _mixTracksStereoInterleaved(_timeline.transportOffset, bufNFrames, nChannels, mixBuf);

            if(_masterBus !is null) {
                _masterBus.processStereoInterleaved(mixBuf, bufNFrames, nChannels);
            }

            _timeline.moveTransport(bufNFrames / nChannels);
        }
    }

    /// Mix all registered tracks into a non-interleaved stereo buffer and update the playback transport
    /// Params:
    /// bufNFrames = The individual length of each output buffer
    /// mixBuf1 = The left output buffer
    /// mixBuf2 = The right output buffer
    final void mixStereoNonInterleaved(nframes_t bufNFrames,
                                       sample_t* mixBuf1,
                                       sample_t* mixBuf2) @nogc nothrow {
        // initialize the buffers to silence
        import core.stdc.string: memset;
        memset(mixBuf1, 0, sample_t.sizeof * bufNFrames);
        memset(mixBuf2, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(_timeline.playing) {
            _mixTracksStereoNonInterleaved(_timeline.transportOffset, bufNFrames, mixBuf1, mixBuf2);

            if(_masterBus !is null) {
                _masterBus.processStereoNonInterleaved(mixBuf1, mixBuf2, bufNFrames);
            }

            _timeline.moveTransport(bufNFrames);
        }
    }

protected:
    /// Abstract method to initialize the audio driver, audio thread and its associated callback function
    void onInitialize();

    /// Abstract method to uninitialize the audio driver and destroy the audio thread
    void onCleanup() nothrow;

private:
    /// Template function to mix down all registered tracks to a single buffer,
    /// with interleaved stereo channels.
    /// At this time, the template argument should either be "mixStereoInterleaved" or
    /// "bounceStereoInterleaved". This guarantees identical behavior when mixing or bouncing
    /// to an interleaved stereo device or file.
    final void _mixTracksStereoInterleaved(string MixFunc = "mixStereoInterleaved")
        (nframes_t offset,
         nframes_t bufNFrames,
         channels_t nChannels,
         sample_t* mixBuf) @nogc nothrow {
        if(_soloTrack) {
            foreach(t; _tracks) {
                if(t.solo) {
                    mixin("t." ~ MixFunc ~ "(offset, bufNFrames, nChannels, mixBuf);");
                }
            }
        }
        else {
            foreach(t; _tracks) {
                mixin("t." ~ MixFunc ~ "(offset, bufNFrames, nChannels, mixBuf);");
            }
        }
    }

    /// Mix down all registered tracks to two separate buffers, corresponding to the left and right
    /// channels of a stereo output device.
    final void _mixTracksStereoNonInterleaved(nframes_t offset,
                                              nframes_t bufNFrames,
                                              sample_t* mixBuf1,
                                              sample_t* mixBuf2) @nogc nothrow {
        if(_soloTrack) {
            foreach(t; _tracks) {
                if(t.solo) {
                    t.mixStereoNonInterleaved(offset, bufNFrames, mixBuf1, mixBuf2);
                }
            }
        }
        foreach(t; _tracks) {
            t.mixStereoNonInterleaved(offset, bufNFrames, mixBuf1, mixBuf2);
        }
    }

    /// Wrap the template argument for `_mixTracksStereoInterleaved` in the case when the
    /// mixer is bouncing the session to a file instead of playing it back on an audio device.
    alias _bounceTracksStereoInterleaved = _mixTracksStereoInterleaved!"bounceStereoInterleaved";

    /// A separate transport offset used for bouncing the session offline.
    nframes_t _bounceTransportOffset;

    /// The application name, typically one word, lower case, useful for identifying
    /// the applicatin e.g. to the JACK router
    string _appName;

    /// Array of all tracks curently registered with the mixer
    Track[] _tracks;

    /// The master bus object, should usually check for a null reference in the audio thread,
    /// since the audio driver may be initialized prior to construction of the master bus
    MasterBus _masterBus;

    /// The timeline for this mixer instance; contains the number of frames and transport
    Timeline _timeline;

    /// Indicates whether there are any tracks for which "solo" mode is enabled.
    bool _soloTrack;
}
