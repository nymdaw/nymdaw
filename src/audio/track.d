module audio.track;

public import audio.channel;
public import audio.region;
public import audio.types;

final class Track : Channel {
public:
    void addRegion(Region region) {
        region.resizeDelegate = resizeDelegate;
        _regions ~= region;
        if(resizeDelegate !is null) {
            resizeDelegate(region.offset + region.nframes);
        }
    }

    const(Region[]) regions() const { return _regions; }

package:
    this(nframes_t sampleRate) {
        super(sampleRate);
    }

    void bounceStereoInterleaved(nframes_t offset,
                                 nframes_t bufNFrames,
                                 channels_t nChannels,
                                 sample_t* mixBuf) @nogc nothrow {
        _mixStereoInterleaved(offset, bufNFrames, nChannels, mixBuf);
    }

    void mixStereoInterleaved(nframes_t offset,
                              nframes_t bufNFrames,
                              channels_t nChannels,
                              sample_t* mixBuf) @nogc nothrow {
        _mixStereoInterleaved(offset, bufNFrames, nChannels, mixBuf);

        if(!mute) {
            processMeter(0, buffer[0].ptr, bufNFrames);
            processMeter(1, buffer[1].ptr, bufNFrames);
        }
        else {
            processSilence(bufNFrames);
        }
    }

    void mixStereoNonInterleaved(nframes_t offset,
                                 nframes_t bufNFrames,
                                 sample_t* mixBuf1,
                                 sample_t* mixBuf2) @nogc nothrow {
        _mixStereoNonInterleaved(offset, bufNFrames, mixBuf1, mixBuf2);

        if(!mute) {
            processMeter(0, buffer[0].ptr, bufNFrames);
            processMeter(1, buffer[1].ptr, bufNFrames);
        }
        else {
            processSilence(bufNFrames);
        }
    }

    ResizeDelegate resizeDelegate;

private:
    void _mixStereoInterleaved(nframes_t offset,
                               nframes_t bufNFrames,
                               channels_t nChannels,
                               sample_t* mixBuf) @nogc nothrow {
        if(!mute) {
            sample_t tempSample;
            for(auto i = 0, j = 0; i < bufNFrames; i += nChannels, ++j) {
                foreach(r; _regions) {
                    if(!r.mute()) {
                        // mono buffer
                        if(nChannels == 1) {
                            // mono region
                            if(r.nChannels == 1) {
                                auto sample = r.getSampleGlobal(0, offset + j) * faderGain;

                                mixBuf[i] += sample;
                                if(leftSolo) {
                                    buffer[0][j] = sample;
                                    buffer[1][j] = 0;
                                }
                                else if(rightSolo) {
                                    buffer[0][j] = 0;
                                    buffer[1][j] = sample;
                                }
                                else {
                                    buffer[0][j] = sample;
                                    buffer[1][j] = sample;
                                }
                            }
                            // stereo region
                            else if(r.nChannels >= 2) {
                                auto sample1 = r.getSampleGlobal(0, offset + j) * faderGain;
                                auto sample2 = r.getSampleGlobal(1, offset + j) * faderGain;

                                if(leftSolo) {
                                    mixBuf[i] += sample1;
                                    buffer[0][j] = sample1;
                                    buffer[1][j] = 0;
                                }
                                else if(rightSolo) {
                                    mixBuf[i] += sample2;
                                    buffer[0][j] = 0;
                                    buffer[1][j] = sample2;
                                }
                                else {
                                    mixBuf[i] += sample1 + sample2;
                                    buffer[0][j] = sample1;
                                    buffer[1][j] = sample2;
                                }
                            }
                        }
                        // stereo buffer
                        else if(nChannels >= 2) {
                            // mono region
                            if(r.nChannels == 1) {
                                auto sample = r.getSampleGlobal(0, offset + j) * faderGain;

                                if(leftSolo) {
                                    mixBuf[i] += sample;
                                    buffer[0][j] = sample;
                                    buffer[1][j] = 0;
                                }
                                else if(rightSolo) {
                                    mixBuf[i + 1] += sample;
                                    buffer[0][j] = 0;
                                    buffer[1][j] = sample;
                                }
                                else {
                                    mixBuf[i] += sample;
                                    mixBuf[i + 1] += sample;
                                    buffer[0][j] = sample;
                                    buffer[1][j] = sample;
                                }
                            }
                            // stereo region
                            else if(r.nChannels >= 2) {
                                auto sample1 = r.getSampleGlobal(0, offset + j) * faderGain;
                                auto sample2 = r.getSampleGlobal(1, offset + j) * faderGain;

                                if(leftSolo) {
                                    mixBuf[i] += sample1;
                                    buffer[0][j] = sample1;
                                    buffer[1][j] = 0;
                                }
                                else if(rightSolo) {
                                    mixBuf[i + 1] += sample2;
                                    buffer[0][j] = 0;
                                    buffer[1][j] = sample2;
                                }
                                else {
                                    mixBuf[i] += sample1;
                                    mixBuf[i + 1] += sample2;
                                    buffer[0][j] = sample1;
                                    buffer[1][j] = sample2;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    void _mixStereoNonInterleaved(nframes_t offset,
                                  nframes_t bufNFrames,
                                  sample_t* mixBuf1,
                                  sample_t* mixBuf2) @nogc nothrow {
        if(!mute) {
            sample_t tempSample;
            for(auto i = 0; i < bufNFrames; ++i) {
                foreach(r; _regions) {
                    if(!r.mute()) {
                        // mono region
                        if(r.nChannels == 1) {
                            auto sample = r.getSampleGlobal(0, offset + i) * faderGain;

                            if(leftSolo) {
                                mixBuf1[i] += sample;
                                buffer[0][i] = sample;
                                buffer[1][i] = 0;
                            }
                            else if(rightSolo) {
                                mixBuf2[i] += sample;
                                buffer[0][i] = 0;
                                buffer[1][i] = sample;
                            }
                            else {
                                mixBuf1[i] += sample;
                                mixBuf2[i] += sample;
                                buffer[0][i] = sample;
                                buffer[1][i] = sample;
                            }
                        }
                        // stereo region
                        else if(r.nChannels >= 2) {
                            auto sample1 = r.getSampleGlobal(0, offset + i) * faderGain;
                            auto sample2 = r.getSampleGlobal(1, offset + i) * faderGain;

                            if(leftSolo) {
                                mixBuf1[i] += sample1;
                                buffer[0][i] = sample1;
                                buffer[1][i] = 0;
                            }
                            else if(rightSolo) {
                                mixBuf2[i] += sample2;
                                buffer[0][i] = 0;
                                buffer[1][i] = sample2;
                            }
                            else {
                                mixBuf1[i] += sample1;
                                mixBuf2[i] += sample2;
                                buffer[0][i] = sample1;
                                buffer[1][i] = sample2;
                            }
                        }
                    }
                }
            }
        }
    }

    Region[] _regions;
}
