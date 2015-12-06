module audio.timeline;

private import std.algorithm;
private import core.memory;

public import audio.types;

/// A concrete channel subclass representing a stereo output containing any number of audio regions.
final class Timeline {
public:
    /// Reset the timeline to an empty state. This is useful for starting new sessions.
    void reset() {
        _nframes = 0;
        _nframes = 0;
        _transportOffset = 0;
        _playing = false;
        _looping = false;
        _loopStart = _loopEnd = 0;
    }

    /// Checks if `newNFrames` extends past the last frame of the mixer,
    /// and if so, changes the last frame of the mixer to `newNFrames`.
    /// Returns: `true` if and only if the mixer altered its frame
    bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    /// The total number of frames in the current session.
    /// This indicates the temporal length of the session.
    @property nframes_t nframes() const @nogc nothrow {
        return _nframes;
    }
    /// ditto
    @property nframes_t nframes(nframes_t newNFrames) @nogc nothrow {
        return (_nframes = newNFrames);
    }

    /// Safely get the index of the last frame in the session.
    /// Returns: Either the last index of the last frame, or 0 if the session is empty.
    @property nframes_t lastFrame() const @nogc nothrow {
        return (_nframes > 0 ? nframes - 1 : 0);
    }

    /// The current frame index of playback.
    @property nframes_t transportOffset() const @nogc nothrow {
        return _transportOffset;
    }
    /// Set the current frame index of playback. This will disable looping.
    @property nframes_t transportOffset(nframes_t newOffset) @nogc nothrow {
        disableLoop();
        return (_transportOffset = min(newOffset, nframes));
    }

    /// Indicates whether the mixer is current playing (i.e., moving the transport), or paused.
    @property bool playing() const @nogc nothrow {
        return _playing;
    }

    /// If the mixer is currently paused, begin playing
    void play() nothrow {
        GC.disable(); // disable garbage collection while playing

        _playing = true;
    }

    /// If the mixer is currently playing, pause the mixer
    void pause() nothrow {
        disableLoop();
        _playing = false;

        GC.enable(); // enable garbage collection while paused
    }

    /// Indicates whether the mixer is currently looping a section of audio specified by the user.
    @property bool looping() const @nogc nothrow {
        return _looping;
    }

    /// Specify a section of audio to loop
    void enableLoop(nframes_t loopStart, nframes_t loopEnd) @nogc nothrow {
        _looping = true;
        _loopStart = loopStart;
        _loopEnd = loopEnd;
    }

    /// Disable looping and return to the conventional playback mode
    void disableLoop() @nogc nothrow {
        _looping = false;
    }

package:
    /// Move the transport offset forward, and update the playing and looping status.
    void moveTransport(nframes_t framesPlayed) @nogc nothrow {
        _transportOffset += framesPlayed;

        _checkTransportFinished();
        _updateLooping();
    }

private:
    /// Stop playing if the transport has moved past the end of the session
    void _checkTransportFinished() @nogc nothrow {
        if(_playing && _transportOffset >= lastFrame) {
            _playing = _looping; // don't stop playing if currently looping
            _transportOffset = lastFrame;
        }
    }

    /// Update the transport if currently looping
    void _updateLooping() @nogc nothrow {
        if(looping && _transportOffset >= _loopEnd) {
            _transportOffset = _loopStart;
        }
    }

    /// The total number of frames in the current session.
    /// This indicates the temporal length of the session.
    nframes_t _nframes;

    /// The offset, in frames, of the current playback position.
    /// Should always be greater than or equal to 0 and less than `_nframes`.
    nframes_t _transportOffset;

    /// Indicates whether the mixer is current playing (i.e., moving the transport), or paused.
    bool _playing;

    /// Indicates whether the mixer is currently looping a section of audio specified by the user.
    bool _looping;

    /// The start frame of the currently looping section, as specified by the user.
    nframes_t _loopStart;

    /// The end frame of the currently looping section, as specified by the user.
    nframes_t _loopEnd;
}
