module audio.importfile;

private import std.path;

private import audio.importfile.sndfile;
private import audio.importfile.mp3;

public import audio.importfile.resamplecallback;
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
                            ResampleCallback resampleCallback = null,
                            LoadState.Callback progressCallback = null) {
    if(extension(fileName) == ".mp3") {
        version(HAVE_MPG123) {
            return loadMp3(fileName, sampleRate, resampleCallback, progressCallback);
        }
        else {
            if(progressCallback !is null) {
                progressCallback(LoadState.complete, 0);
            }
            return null;
        }
    }
    else {
        return loadSndFile(fileName, sampleRate, resampleCallback, progressCallback);
    }
}
