module audio.region.stretch;

private import std.algorithm;

private import rubberband;

private import util.scopedarray;

public import audio.sequence;
public import audio.types;

/// Stretches the subregion between the given local indices according to stretchRatio
sample_t[] stretchSubregionBuffer(AudioSequence.AudioPieceTable audioBuffer,
                                  channels_t nChannels,
                                  nframes_t sampleRate,
                                  double stretchRatio) {
    uint subregionLength = cast(uint)(audioBuffer.length / nChannels);
    ScopedArray!(float[][]) subregionChannels = new float[][](nChannels);
    ScopedArray!(float*[]) subregionPtr = new float*[](nChannels);
    for(auto i = 0; i < nChannels; ++i) {
        float[] subregion = new float[](subregionLength);
        subregionChannels[i] = subregion;
        subregionPtr[i] = subregion.ptr;
    }

    foreach(channels_t channelIndex, channel; subregionChannels) {
        foreach(i, ref sample; channel) {
            sample = audioBuffer[i * nChannels + channelIndex];
        }
    }

    uint subregionOutputLength = cast(uint)(subregionLength * stretchRatio);
    ScopedArray!(float[][]) subregionOutputChannels = new float[][](nChannels);
    ScopedArray!(float*[]) subregionOutputPtr = new float*[](nChannels);
    for(auto i = 0; i < nChannels; ++i) {
        float[] subregionOutput = new float[](subregionOutputLength);
        subregionOutputChannels[i] = subregionOutput;
        subregionOutputPtr[i] = subregionOutput.ptr;
    }

    RubberBandState rState = rubberband_new(sampleRate,
                                            nChannels,
                                            RubberBandOption.RubberBandOptionProcessOffline,
                                            stretchRatio,
                                            1.0);
    rubberband_set_max_process_size(rState, subregionLength);
    rubberband_set_expected_input_duration(rState, subregionLength);
    rubberband_study(rState, subregionPtr.ptr, subregionLength, 1);
    rubberband_process(rState, subregionPtr.ptr, subregionLength, 1);
    while(rubberband_available(rState) < subregionOutputLength) {}
    rubberband_retrieve(rState, subregionOutputPtr.ptr, subregionOutputLength);
    rubberband_delete(rState);

    sample_t[] subregionOutput = new sample_t[](subregionOutputLength * nChannels);
    foreach(channels_t channelIndex, channel; subregionOutputChannels) {
        foreach(i, sample; channel) {
            subregionOutput[i * nChannels + channelIndex] = sample;
        }
    }

    return subregionOutput;
}

/// Stretch the audio between `localStartFrame` and `localEndFrame`,
/// such that the frame at `localSrcFrame` becomes the frame at `localDestFrame`.
/// A call to this function should correspond to onset move operation.
/// If linkChannels is `true`, perform the stretch for all channels simultaneously, ignoring `channelIndex`.
/// Otherwise, perform the stretch only for the channel given by `singleChannelIndex`.
/// The `leftSource` and `rightSource` parameters should correspond to the `leftSource` and `rightSource`
/// members of the onset that is being moved.
/// These members ensure that successive three-point stretche operations are not computed from previously
/// stretched audio data, thereby avoiding any unnessary loss in sound quality.
sample_t[] stretchThreePointBuffer(AudioSequence audioSeq,
                                   AudioSequence.AudioPieceTable audioSlice,
                                   nframes_t removeStartIndex,
                                   channels_t nChannels,
                                   nframes_t sampleRate,
                                   nframes_t localStartFrame,
                                   nframes_t localSrcFrame,
                                   nframes_t localDestFrame,
                                   nframes_t localEndFrame,
                                   bool linkChannels,
                                   channels_t singleChannelIndex,
                                   AudioSequence.AudioPieceTable leftSource,
                                   AudioSequence.AudioPieceTable rightSource) {
    immutable channels_t stretchNChannels = linkChannels ? nChannels : 1;
    immutable bool useSource = leftSource && rightSource;

    immutable double firstScaleFactor = (localSrcFrame > localStartFrame) ?
        (cast(double)(localDestFrame - localStartFrame) /
         cast(double)(useSource ? leftSource.length / nChannels : localSrcFrame - localStartFrame)) : 0;
    immutable double secondScaleFactor = (localEndFrame > localSrcFrame) ?
        (cast(double)(localEndFrame - localDestFrame) /
         cast(double)(useSource ? rightSource.length / nChannels : localEndFrame - localSrcFrame)) : 0;

    if(useSource) {
        localStartFrame = 0;
        localSrcFrame = (localStartFrame < localSrcFrame) ? localSrcFrame - localStartFrame : 0;
        localDestFrame = (localStartFrame < localDestFrame) ? localDestFrame - localStartFrame : 0;
        localEndFrame = (localStartFrame < localEndFrame) ? localEndFrame - localStartFrame : 0;
    }

    uint firstHalfLength = cast(uint)(useSource ?
                                      leftSource.length / nChannels :
                                      localSrcFrame - localStartFrame);
    uint secondHalfLength = cast(uint)(useSource ?
                                       rightSource.length / nChannels :
                                       localEndFrame - localSrcFrame);
    ScopedArray!(float[][]) firstHalfChannels = new float[][](stretchNChannels);
    ScopedArray!(float[][]) secondHalfChannels = new float[][](stretchNChannels);
    ScopedArray!(float*[]) firstHalfPtr = new float*[](stretchNChannels);
    ScopedArray!(float*[]) secondHalfPtr = new float*[](stretchNChannels);
    for(auto i = 0; i < stretchNChannels; ++i) {
        float[] firstHalf = new float[](firstHalfLength);
        float[] secondHalf = new float[](secondHalfLength);
        firstHalfChannels[i] = firstHalf;
        secondHalfChannels[i] = secondHalf;
        firstHalfPtr[i] = firstHalf.ptr;
        secondHalfPtr[i] = secondHalf.ptr;
    }

    if(useSource) {
        if(linkChannels) {
            foreach(channels_t channelIndex, channel; firstHalfChannels) {
                foreach(i, ref sample; channel) {
                    sample = leftSource[i * nChannels + channelIndex];
                }
            }
            foreach(channels_t channelIndex, channel; secondHalfChannels) {
                foreach(i, ref sample; channel) {
                    sample = rightSource[i * nChannels + channelIndex];
                }
            }
        }
        else {
            foreach(i, ref sample; firstHalfChannels[0]) {
                sample = leftSource[i * nChannels + singleChannelIndex];
            }
            foreach(i, ref sample; secondHalfChannels[0]) {
                sample = rightSource[i * nChannels + singleChannelIndex];
            }
        }
    }
    else {
        if(linkChannels) {
            foreach(channels_t channelIndex, channel; firstHalfChannels) {
                foreach(i, ref sample; channel) {
                    sample = audioSlice[(localStartFrame + i) * nChannels + channelIndex];
                }
            }
            foreach(channels_t channelIndex, channel; secondHalfChannels) {
                foreach(i, ref sample; channel) {
                    sample = audioSlice[(localSrcFrame + i) * nChannels + channelIndex];
                }
            }
        }
        else {
            foreach(i, ref sample; firstHalfChannels[0]) {
                sample = audioSlice[(localStartFrame + i) * nChannels + singleChannelIndex];
            }
            foreach(i, ref sample; secondHalfChannels[0]) {
                sample = audioSlice[(localSrcFrame + i) * nChannels + singleChannelIndex];
            }
        }
    }

    uint firstHalfOutputLength = cast(uint)(firstHalfLength * firstScaleFactor);
    uint secondHalfOutputLength = cast(uint)(secondHalfLength * secondScaleFactor);
    ScopedArray!(float[][]) firstHalfOutputChannels = new float[][](stretchNChannels);
    ScopedArray!(float[][]) secondHalfOutputChannels = new float[][](stretchNChannels);
    ScopedArray!(float*[]) firstHalfOutputPtr = new float*[](stretchNChannels);
    ScopedArray!(float*[]) secondHalfOutputPtr = new float*[](stretchNChannels);
    for(auto i = 0; i < stretchNChannels; ++i) {
        float[] firstHalfOutput = new float[](firstHalfOutputLength);
        float[] secondHalfOutput = new float[](secondHalfOutputLength);
        firstHalfOutputChannels[i] = firstHalfOutput;
        secondHalfOutputChannels[i] = secondHalfOutput;
        firstHalfOutputPtr[i] = firstHalfOutput.ptr;
        secondHalfOutputPtr[i] = secondHalfOutput.ptr;
    }

    if(firstScaleFactor > 0) {
        RubberBandState rState = rubberband_new(sampleRate,
                                                stretchNChannels,
                                                RubberBandOption.RubberBandOptionProcessOffline,
                                                firstScaleFactor,
                                                1.0);
        rubberband_set_max_process_size(rState, firstHalfLength);
        rubberband_set_expected_input_duration(rState, firstHalfLength);
        rubberband_study(rState, firstHalfPtr.ptr, firstHalfLength, 1);
        rubberband_process(rState, firstHalfPtr.ptr, firstHalfLength, 1);
        while(rubberband_available(rState) < firstHalfOutputLength) {}
        rubberband_retrieve(rState, firstHalfOutputPtr.ptr, firstHalfOutputLength);
        rubberband_delete(rState);
    }

    if(secondScaleFactor > 0) {
        RubberBandState rState = rubberband_new(sampleRate,
                                                stretchNChannels,
                                                RubberBandOption.RubberBandOptionProcessOffline,
                                                secondScaleFactor,
                                                1.0);
        rubberband_set_max_process_size(rState, secondHalfLength);
        rubberband_set_expected_input_duration(rState, secondHalfLength);
        rubberband_study(rState, secondHalfPtr.ptr, secondHalfLength, 1);
        rubberband_process(rState, secondHalfPtr.ptr, secondHalfLength, 1);
        while(rubberband_available(rState) < secondHalfOutputLength) {}
        rubberband_retrieve(rState, secondHalfOutputPtr.ptr, secondHalfOutputLength);
        rubberband_delete(rState);
    }

    sample_t[] outputBuffer = new sample_t[]((firstHalfOutputLength + secondHalfOutputLength) * nChannels);
    if(linkChannels) {
        foreach(channels_t channelIndex, channel; firstHalfOutputChannels) {
            foreach(i, sample; channel) {
                outputBuffer[i * nChannels + channelIndex] = sample;
            }
        }
        auto secondHalfOffset = firstHalfOutputLength * nChannels;
        foreach(channels_t channelIndex, channel; secondHalfOutputChannels) {
            foreach(i, sample; channel) {
                outputBuffer[secondHalfOffset + i * nChannels + channelIndex] = sample;
            }
        }
    }
    else {
        auto firstHalfSourceOffset = removeStartIndex;
        foreach(i, sample; firstHalfOutputChannels[0]) {
            for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
                if(channelIndex == singleChannelIndex) {
                    outputBuffer[i * nChannels + channelIndex] = sample;
                }
                else {
                    outputBuffer[i * nChannels + channelIndex] =
                        audioSeq[firstHalfSourceOffset + i * nChannels + channelIndex];
                }
            }
        }
        auto secondHalfOutputOffset = firstHalfOutputLength * nChannels;
        auto secondHalfSourceOffset = firstHalfSourceOffset + secondHalfOutputOffset;
        foreach(i, sample; secondHalfOutputChannels[0]) {
            for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
                if(channelIndex == singleChannelIndex) {
                    outputBuffer[secondHalfOutputOffset + i * nChannels + channelIndex] = sample;
                }
                else {
                    outputBuffer[secondHalfOutputOffset + i * nChannels + channelIndex] =
                        audioSeq[secondHalfSourceOffset + i * nChannels + channelIndex];
                }
            }
        }
    }

    return outputBuffer;
}
