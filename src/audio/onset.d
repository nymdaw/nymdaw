module audio.onset;

private import std.algorithm;
private import std.math;
private import std.range;
private import std.string;

private import util.sequence;

private import aubio;

private import audio.progress;
private import audio.sequence;
private import audio.types;

/// Structure representing an audio onset (i.e., a transient or attack)
struct Onset {
    /// Index representing the relative frame of the onset from the start of the sequence
    nframes_t onsetFrame;

    /// The slice of audio directly to the left of this onset.
    /// It extends from the previous onset (or the beginning of the sequence) to this onset.
    AudioSequence.AudioPieceTable leftSource;

    /// The slice of audio directly to the right of this onset
    /// It extends from this onset to the next onset (or the end of the sequence).
    AudioSequence.AudioPieceTable rightSource;
}

/// Sequence class instantiation for representing a series of onsets detected in an audio sequence
alias OnsetSequence = Sequence!(Onset[]);

/// Structure containing the parameters for detecting the onsets in an audio sequence
struct OnsetParams {
    enum onsetThresholdMin = 0.0;
    enum onsetThresholdMax = 1.0;
    sample_t onsetThreshold = 0.3;

    enum silenceThresholdMin = -90;
    enum silenceThresholdMax = 0.0;
    sample_t silenceThreshold = -90;
}

/// Implementation of the onset detection functionality.
/// Note that `ChannelIndex` is ignored when `linkChannels` is `true`.
Onset[] computeOnsets(ref const(OnsetParams) params,
                      AudioSequence.AudioPieceTable pieceTable,
                      nframes_t sampleRate,
                      channels_t nChannels,
                      channels_t channelIndex,
                      bool linkChannels,
                      ComputeOnsetsState.Callback progressCallback = null) {
    immutable nframes_t nframes = cast(nframes_t)(pieceTable.length / nChannels);
    immutable nframes_t framesPerProgressStep =
        (nframes / ComputeOnsetsState.stepsPerStage) * (linkChannels ? 1 : nChannels);
    nframes_t progressStep;

    immutable uint windowSize = 512;
    immutable uint hopSize = 256;
    string onsetMethod = "default";

    auto onsetThreshold = clamp(params.onsetThreshold,
                                OnsetParams.onsetThresholdMin,
                                OnsetParams.onsetThresholdMax);
    auto silenceThreshold = clamp(params.silenceThreshold,
                                  OnsetParams.silenceThresholdMin,
                                  OnsetParams.silenceThresholdMax);

    fvec_t* onsetBuffer = new_fvec(1);
    fvec_t* hopBuffer = new_fvec(hopSize);

    auto onsetsApp = appender!(Onset[]);
    aubio_onset_t* o = new_aubio_onset(cast(char*)(onsetMethod.toStringz()), windowSize, hopSize, sampleRate);
    aubio_onset_set_threshold(o, onsetThreshold);
    aubio_onset_set_silence(o, silenceThreshold);
    for(nframes_t samplesRead = 0; samplesRead < nframes; samplesRead += hopSize) {
        uint hopSizeLimit;
        if(((hopSize - 1 + samplesRead) * nChannels + channelIndex) > pieceTable.length) {
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
                    hopBuffer.data[sample] += pieceTable[(sample + samplesRead) * nChannels + i];
                }
            }
        }
        else {
            for(auto sample = 0; sample < hopSizeLimit; ++sample) {
                hopBuffer.data[sample] = pieceTable[(sample + samplesRead) * nChannels + channelIndex];
            }
        }

        aubio_onset_do(o, hopBuffer, onsetBuffer);
        if(onsetBuffer.data[0] != 0) {
            auto lastOnset = aubio_onset_get_last(o);
            if(lastOnset != 0) {
                if(onsetsApp.data.length > 0) {
                    // compute the right source for the previous onset
                    onsetsApp.data[$ - 1].rightSource =
                        pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels .. lastOnset * nChannels];
                    // append the current onset and its left source
                    onsetsApp.put(Onset(lastOnset, pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels ..
                                                              lastOnset * nChannels]));
                }
                else {
                    // append the leftmost onset
                    onsetsApp.put(Onset(lastOnset, pieceTable[0 .. lastOnset * nChannels]));
                }
            }
        }
        // compute the right source for the last onset
        if(onsetsApp.data.length > 0) {
            onsetsApp.data[$ - 1].rightSource =
                pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels .. pieceTable.length];
        }

        if((samplesRead > progressStep) && progressCallback) {
            progressStep = samplesRead + framesPerProgressStep;
            if(linkChannels) {
                progressCallback(ComputeOnsetsState.computeOnsets,
                                 cast(double)(samplesRead) / cast(double)(nframes));
            }
            else {
                progressCallback(ComputeOnsetsState.computeOnsets,
                                 cast(double)(samplesRead + nframes * channelIndex) /
                                 cast(double)(nframes * nChannels));
            }
        }
    }
    del_aubio_onset(o);

    del_fvec(onsetBuffer);
    del_fvec(hopBuffer);
    aubio_cleanup();

    return onsetsApp.data;
}
