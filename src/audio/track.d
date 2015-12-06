module audio.track;

public import audio.channel;
public import audio.region;
public import audio.timeline;
public import audio.types;

/// A concrete channel subclass representing a stereo output containing any number of audio regions.
final class Track : Channel {
public:
    /// Register a region object with this track.
    /// This will automatically increase the the mixer's last frame, if the added region extends beyond
    /// the current end of the session.
    void addRegion(Region region) {
        region.timeline = _timeline;
        _regions ~= region;
        if(_timeline !is null) {
            _timeline.resizeIfNecessary(region.offset + region.nframes);
        }
    }

    /// Returns: An array of all region objects currently registered with this track.
    const(Region[]) regions() const { return _regions; }

package:
    /// This constructor should only be called by the mixer.
    this(nframes_t sampleRate, Timeline timeline) {
        super(sampleRate);

        _timeline = timeline;
    }

    /// This function should be called in place of the corresponding
    /// mix function when bouncing to an audio file, since this
    /// function eschews any metering calls
    /// Params:
    /// offset = The absolute frame index of playback, from the start of the session
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
    void bounceStereoInterleaved(nframes_t offset,
                                 nframes_t bufNFrames,
                                 channels_t nChannels,
                                 sample_t* mixBuf) @nogc nothrow {
        _mixStereoInterleaved(offset, bufNFrames, nChannels, mixBuf);
    }

    /// Mix all registered regions into an interleaved stereo buffer and update the meters
    /// Params:
    /// offset = The absolute frame index of playback, from the start of the session
    /// bufNFrames = The the total length of the inverleaved output buffer, including all channels
    /// nChannels = The total number of interleaved channels in the output buffer (typically two)
    /// mixBuf = The interleaved output buffer
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

    /// Mix all registered regions into a non-interleaved stereo buffer and upate the meters
    /// Params:
    /// offset = The absolute frame index of playback, from the start of the session
    /// bufNFrames = The individual length of each output buffer
    /// mixBuf1 = The left output buffer
    /// mixBuf2 = The right output buffer
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

private:
    /// Copy the appropriate samples from all registered regions into an interleaved stereo output buffer,
    /// and apply the fader gain.
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

    /// Copy the appropriate samples from all registered regions into non-interleaved stereo output buffers,
    /// and apply the fader gain.
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

    /// Array of all regions currently registered with this track
    Region[] _regions;

    /// The timeline for this mixer instance; contains the number of frames and transport
    Timeline _timeline;
}
