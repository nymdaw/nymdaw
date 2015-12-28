module audio.importfile.sndfile;

private import std.math;
private import std.path;
private import std.string;
private import util.scopedarray;

private import sndfile;
private import samplerate;

public import audio.importfile.resamplecallback;
public import audio.progress;
public import audio.region;
public import audio.sequence;
public import audio.types;

/// Load an audio file via libsndfile
AudioSequence loadSndFile(string fileName,
                          nframes_t sampleRate,
                          ResampleCallback resampleCallback = null,
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
    auto newSequence = new AudioSequence(cast(immutable)(AudioSegment(cast(immutable)(audioBuffer), nChannels)),
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
