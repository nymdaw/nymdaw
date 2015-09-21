/// Functions to initialize `AudioSequence` instances from audio files

module audio.file;

private import std.conv;
private import std.math;
private import std.path;
private import std.string;
private import std.typecons;

private import samplerate;
private import sndfile;
version(HAVE_MPG123) {
    private import mpg123;
}

private import util.scopedarray;

public import audio.region;
public import audio.types;

/// Load an audio file and create a new sequence from its data
/// Params:
/// fileName = The file (including its path on disk) from which to load audio data
/// sampleRate = The smapling rate of the current session
/// resampleCallback = A delegate that will be called in the case that the
///                    audio file's sampling rate is not the same as that of the current session
AudioSequence loadAudioFile(string fileName,
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

/// Resample audio in the given buffer
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
