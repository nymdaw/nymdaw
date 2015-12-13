module audio.exportfile.sndfile;

private import std.file;
private import std.string;

private import sndfile;

private import util.scopedarray;

public import audio.mixer;
public import audio.region;
public import audio.timeline;
public import audio.types;

/// Bounce the entire session to an audio file
void exportSessionToFile(Mixer mixer,
                         string fileName,
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

    sfinfo.samplerate = mixer.sampleRate;
    sfinfo.frames = mixer.timeline.nframes;
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

    // initialize a temporary timeline for this bounce
    Timeline bounceTimeline = new Timeline();
    bounceTimeline.nframes = mixer.timeline.nframes;

    // counters for updating the progress bar
    immutable size_t progressIncrement = (bounceTimeline.nframes * exportChannels) / SaveState.stepsPerStage;
    size_t progressCount;

    // write all audio data in the current session to the specified file
    ScopedArray!(sample_t[]) buffer = new sample_t[](maxBufferLength * exportChannels);
    sf_count_t writeTotal;
    sf_count_t writeCount;
    while(writeTotal < bounceTimeline.nframes * exportChannels) {
        auto immutable processNFrames =
            writeTotal + maxBufferLength * exportChannels < bounceTimeline.nframes * exportChannels ?
            maxBufferLength * exportChannels : bounceTimeline.nframes * exportChannels - writeTotal;

        mixer.bounceStereoInterleaved(bounceTimeline, cast(nframes_t)(processNFrames), exportChannels, buffer.ptr);

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
                                 cast(double)(writeTotal) / cast(double)(bounceTimeline.nframes * exportChannels))) {
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
