module audio.region.effects;

private import std.algorithm;
private import std.math;

public import audio.types;
public import audio.progress;

/// Adjust the gain of an audio buffer.
/// Note that this does not send a progress completion message.
void gainBuffer(sample_t[] audioBuffer,
                sample_t gainDB,
                GainState.Callback progressCallback = null) {
    sample_t sampleFactor = pow(10, gainDB / 20);
    foreach(i, ref s; audioBuffer) {
        s *= sampleFactor;

        if(progressCallback !is null && i % (audioBuffer.length / GainState.stepsPerStage) == 0) {
            progressCallback(GainState.gain, cast(double)(i) / cast(double)(audioBuffer.length));
        }
    }
}

/// Normalize an audio buffer.
/// Note that this does not send a progress completion message.
void normalizeBuffer(sample_t[] audioBuffer,
                     sample_t maxGainDB = 0.1f,
                     NormalizeState.Callback progressCallback = null) {
    // calculate the maximum sample
    sample_t minSample = 1;
    sample_t maxSample = -1;
    foreach(s; audioBuffer) {
        if(s > maxSample) maxSample = s;
        if(s < minSample) minSample = s;
    }
    maxSample = max(abs(minSample), abs(maxSample));

    // normalize the buffer
    sample_t sampleFactor = pow(10, (maxGainDB > 0 ? 0 : maxGainDB) / 20) / maxSample;
    foreach(i, ref s; audioBuffer) {
        s *= sampleFactor;

        if(progressCallback !is null && i % (audioBuffer.length / NormalizeState.stepsPerStage) == 0) {
            progressCallback(NormalizeState.normalize, cast(double)(i) / cast(double)(audioBuffer.length));
        }
    }
}

/// Linearly fade in an audio buffer, in-place
void fadeInBuffer(sample_t[] audioBuffer) {
    immutable sample_t bufferLength = cast(sample_t)(audioBuffer.length);
    foreach(i, ref s; audioBuffer) {
        s *= cast(sample_t)(i) / bufferLength;
    }
}

/// Linearly fade out an audio buffer, in-place
void fadeOutBuffer(sample_t[] audioBuffer) {
    immutable sample_t bufferLength = cast(sample_t)(audioBuffer.length);
    foreach(i, ref s; audioBuffer) {
        s *= 1 - cast(sample_t)(i) / bufferLength;
    }
}
