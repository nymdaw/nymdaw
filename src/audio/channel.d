module audio.channel;

private import std.algorithm;
private import std.math;

private import meters;

public import audio.types;

abstract class Channel {
    this(nframes_t sampleRate) {
        _sampleRate = sampleRate;

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

    final void processSilence(nframes_t bufferLength) @nogc nothrow {
        for(channels_t channelIndex = 0; channelIndex < 2; ++channelIndex) {
            processMeter(channelIndex, _zeroBuffer.ptr, min(bufferLength, _zeroBuffer.length));
        }
    }

    final void resetMeterLeft() @nogc nothrow {
        _meter[0].reset();
        _peakMax[0] = 0;
        _level[0] = 0;
        _lastLevelMax[0] = 0;
    }

    final void resetMeterRight() @nogc nothrow {
        _meter[1].reset();
        _peakMax[1] = 0;
        _level[1] = 0;
        _lastLevelMax[1] = 0;
    }

    final void resetMeters() @nogc nothrow {
        _meter[0].reset();
        _meter[1].reset();
        _peakMax = 0;
        _level = 0;
        _lastLevelMax = 0;
    }

    @property final const(sample_t[2]) level() {
        _resetLastLevel = true;
        sample_t[2] retValue;
        retValue[0] = _lastLevelMax[0];
        retValue[1] = _lastLevelMax[1];
        return retValue;
    }
    @property final ref const(sample_t[2]) peakMax() const { return _peakMax; }

    @property final sample_t faderGainDB() const @nogc nothrow {
        return 20 * log10(_faderGain);
    }
    @property final sample_t faderGainDB(sample_t db) {
        return (_faderGain = pow(10, db / 20));
    }

protected:
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

    sample_t[maxBufferLength][2] buffer;

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

    sample_t _faderGain = 1.0;
}
