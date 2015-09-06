module audio.channel;

private import std.algorithm;
private import std.math;

private import meters;

public import audio.types;

/// An abstract class representing a generic stereo audio output source, such as a track or bus.
/// This class handles common functionality such as mute/solo, soloing left/right channels,
/// output metering, and adjusting output gain via a fader.
abstract class Channel {
    /// Params:
    /// sampleRate = the sample rate of the session, in samples per second. This is required for metering.
    this(nframes_t sampleRate) {
        _sampleRate = sampleRate;

        // initialize separate meters for the left/right channels
        _meter[0] = new TruePeakDSP();
        _meter[1] = new TruePeakDSP();
        _meter[0].init(_sampleRate);
        _meter[1].init(_sampleRate);
    }

    @property final nframes_t sampleRate() const { return _sampleRate; }

    @property final bool mute() const @nogc nothrow { return _mute; }
    @property final bool mute(bool enable) { return (_mute = enable); }

    @property final bool solo() const @nogc nothrow { return _solo; }
    @property final bool solo(bool enable) { return (_solo = enable); }

    @property final bool leftSolo() const @nogc nothrow { return _leftSolo; }
    @property final bool leftSolo(bool enable) {
        if(enable && _rightSolo) {
            _rightSolo = false;
        }
        return (_leftSolo = enable);
    }

    @property final bool rightSolo() const @nogc nothrow { return _rightSolo; }
    @property final bool rightSolo(bool enable) {
        if(enable && _leftSolo) {
            _leftSolo = false;
        }
        return (_rightSolo = enable);
    }

    /// This function is useful to allow the meters to smoothly return to -infinity
    /// after the mixer has stopped playing, since the `processMeter` member function
    /// will no longer be called when the mixer stops playing.
    final void processSilence(nframes_t bufferLength) @nogc nothrow {
        for(channels_t channelIndex = 0; channelIndex < 2; ++channelIndex) {
            processMeter(channelIndex, _zeroBuffer.ptr, min(bufferLength, _zeroBuffer.length));
        }
    }

    /// Reset the meter for the left channel to its initial state
    final void resetMeterLeft() @nogc nothrow {
        _meter[0].reset();
        _peakMax[0] = 0;
        _level[0] = 0;
        _lastLevelMax[0] = 0;
    }

    /// Reset the meter for the right channel to its initial state
    final void resetMeterRight() @nogc nothrow {
        _meter[1].reset();
        _peakMax[1] = 0;
        _level[1] = 0;
        _lastLevelMax[1] = 0;
    }

    /// Reset the meters for both the left and right channels to their initial states
    final void resetMeters() @nogc nothrow {
        _meter[0].reset();
        _meter[1].reset();
        _peakMax = 0;
        _level = 0;
        _lastLevelMax = 0;
    }

    /// Returns: The maximum sample values for the left and right channels
    /// since the last call to this function.
    /// This ensures that level peaks are properly rendered, since the UI most likely refreshes
    /// at a slower rate than the meter processes incoming audio buffers.
    @property final const(sample_t[2]) level() {
        _resetLastLevel = true;
        sample_t[2] retValue;
        retValue[0] = _lastLevelMax[0];
        retValue[1] = _lastLevelMax[1];
        return retValue;
    }

    /// Returns: The maximum sample values for detected peaks for the left and right channels.
    @property final ref const(sample_t[2]) peakMax() const { return _peakMax; }

    /// Returns: The fader gain (analogous to an analog mixer) for this channel's stereo output, in dBFS
    @property final sample_t faderGainDB() const @nogc nothrow {
        return 20 * log10(_faderGain);
    }

    /// Params:
    /// db = The fader gain (analogous to an analog mixer) for this channel's stereo output, in dBFS
    @property final sample_t faderGainDB(sample_t db) {
        return (_faderGain = pow(10, db / 20));
    }

protected:
    /// Sets the current meter levels and peaks for the given mono audio buffer.
    /// This function should be called separately for both the left and right channels.
    final void processMeter(channels_t channelIndex, sample_t* buffer, nframes_t nframes) @nogc nothrow {
        _meter[channelIndex].process(buffer, nframes);

        float m, p;
        _meter[channelIndex].read(m, p);

        _level[channelIndex] = m;
        if(_resetLastLevel || _lastLevelMax[channelIndex] < m) {
            _lastLevelMax[channelIndex] = m;
        }

        if(_peakMax[channelIndex] < p) {
            _peakMax[channelIndex] = p;
        }
    }

    /// This is a statically allocated stereo buffer (non-interleaved),
    /// which should be at least as large as any practical audio device output buffer.
    /// Derived classes may fill this buffer with audio data, then pass its pointer to `processMeter`.
    sample_t[maxBufferLength][2] buffer;

    /// Returns: The fader gain, as a raw sample factor (not in dBFS)
    @property sample_t faderGain() const @nogc nothrow { return _faderGain; }

private:
    const(nframes_t) _sampleRate;

    bool _mute;
    bool _solo;
    bool _leftSolo;
    bool _rightSolo;

    TruePeakDSP[2] _meter;
    sample_t[maxBufferLength] _zeroBuffer = 0;
    sample_t[2] _peakMax = 0;
    sample_t[2] _level = 0;
    sample_t[2] _lastLevelMax = 0;
    bool _resetLastLevel;

    /// By default, the fader gain should be at 0 dBFS, which equates to a sample multiplier of 1.0
    sample_t _faderGain = 1.0;
}
