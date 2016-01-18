module audio.importfile.mp3;

private import std.array;
private import std.path;
private import std.string;
private import util.scopedarray;

public import audio.importfile.resamplecallback;
public import audio.progress;
public import audio.region;
public import audio.sequence;
public import audio.types;

version(HAVE_MPG123) {
    private import mpg123;

    /// Load an audio file via libmpg123
    AudioSequence loadMp3(string fileName,
                          nframes_t sampleRate,
                          ResampleCallback resampleCallback = null,
                          LoadState.Callback progressCallback = null) {
        mpg123_handle* mh;
	ScopedArray!(ubyte[]) buffer;
	size_t bufferSize;
	size_t bytesRead;
	int channels;
	int encoding;
	int frameSize = 1;
	long rate;
	int err = mpg123_errors.MPG123_OK;
	off_t samples;

        scope(exit) {
            mpg123_close(mh);
            mpg123_delete(mh);
            mpg123_exit();
        }

        err = mpg123_init();
        if(err != mpg123_errors.MPG123_OK || (mh = mpg123_new(null, &err)) is null) {
            return null;
        }

        mpg123_param(mh, mpg123_parms.MPG123_ADD_FLAGS, mpg123_param_flags.MPG123_FORCE_FLOAT, 0.);
        mpg123_param(mh, mpg123_parms.MPG123_RESYNC_LIMIT, -1, 0);

        if(mpg123_open(mh, fileName.toStringz()) != mpg123_errors.MPG123_OK ||
           mpg123_getformat(mh, &rate, &channels, &encoding) != mpg123_errors.MPG123_OK) {
            return null;
        }

        immutable size_t estimatedLengthSamples = mpg123_length(mh);

        mpg123_format_none(mh);
        mpg123_format(mh, rate, channels, encoding);

        bufferSize = mpg123_outblock(mh);
        buffer = new ubyte[](bufferSize);

        // allocate contiguous audio buffer
        immutable size_t chunkSize = sampleRate * 10;
        auto audioBuffersApp = appender!(sample_t[][]);

        // counters for updating the progress bar
        immutable size_t progressIncrement = (estimatedLengthSamples * channels) / LoadState.stepsPerStage;
        size_t progressCount;

        // read the file into the audio buffer
        size_t readTotal;
        size_t readCount;
        do {
            sample_t[] currentAudioBuffer = new sample_t[](chunkSize);

            err = mpg123_read(mh, cast(ubyte*)(currentAudioBuffer.ptr), currentAudioBuffer.length, &bytesRead);
            readCount = bytesRead / sample_t.sizeof;
            currentAudioBuffer.length = readCount;
            audioBuffersApp.put(currentAudioBuffer);

            readTotal += readCount;

            if(progressCallback !is null && readTotal >= progressCount) {
                progressCount += progressIncrement;
                if(!progressCallback(LoadState.read,
                                     cast(double)(readTotal) / cast(double)(estimatedLengthSamples * channels))) {
                    return null;
                }
            }
        }
        while(bytesRead && err == mpg123_errors.MPG123_OK);

        if(err != mpg123_errors.MPG123_DONE || audioBuffersApp.data.empty) {
            return null;
        }

        AudioSequence.AudioPieceTable audioPieceTable;
        foreach(audioBuffer; audioBuffersApp.data) {
            audioPieceTable = audioPieceTable.append(AudioSegment(cast(immutable)(audioBuffer),
                                                                  cast(channels_t)(channels)));
        }

        auto newSequence = new AudioSequence(audioPieceTable,
                                             sampleRate,
                                             cast(channels_t)(channels),
                                             baseName(fileName));
        if(progressCallback !is null) {
            if(!progressCallback(LoadState.complete, 1)) {
                newSequence.destroy();
                return null;
            }
        }
        return newSequence;
    }
}
