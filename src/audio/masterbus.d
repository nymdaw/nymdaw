module audio.masterbus;

public import audio.channel;

final class MasterBus : Channel {
public:
    void processStereoInterleaved(sample_t* mixBuf,
                                  nframes_t bufNFrames,
                                  channels_t nChannels) @nogc nothrow {
        for(auto i = 0, j = 0; i < bufNFrames; i += nChannels, ++j) {
            mixBuf[i] *= faderGain;
            mixBuf[i + 1] *= faderGain;

            buffer[0][j] = mixBuf[i];
            buffer[1][j] = mixBuf[i + 1];
        }

        processMeter(0, buffer[0].ptr, bufNFrames);
        processMeter(1, buffer[1].ptr, bufNFrames);
    }

    void processStereoNonInterleaved(sample_t* mixBuf1,
                                     sample_t* mixBuf2,
                                     nframes_t bufNFrames) @nogc nothrow {
        for(auto i = 0; i < bufNFrames; ++i) {
            mixBuf1[i] *= faderGain;
            mixBuf2[i] *= faderGain;

            buffer[0][i] = mixBuf1[i];
            buffer[1][i] = mixBuf2[i];
        }

        processMeter(0, buffer[0].ptr, bufNFrames);
        processMeter(1, buffer[1].ptr, bufNFrames);
    }

package:
    this(nframes_t sampleRate) {
        super(sampleRate);
    }
}
