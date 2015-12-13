module audio.timeline;

private import std.algorithm;

public import audio.types;

// A concrete class representing a scrubbable audio timeline.
final class Timeline {
public:
    /// Reset the timeline to an empty state. This is useful for starting new sessions.
    void reset() {
        _nframes = 0;
        _transportOffset = 0;
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
    /// Set the current frame index of playback.
    @property nframes_t transportOffset(nframes_t newOffset) @nogc nothrow {
        return (_transportOffset = min(newOffset, nframes));
    }
    /// Move the transport offset forward
    void moveTransport(nframes_t framesPlayed) @nogc nothrow {
        _transportOffset = min(_transportOffset + framesPlayed, nframes);
    }

    /// Checks if `newNFrames` extends past the last frame of the timeline,
    /// and if so, changes the last frame of the timeline to `newNFrames`.
    /// Returns: `true` if and only if the timeline altered its frame
    bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

private:
    /// The total number of frames in the current session.
    /// This indicates the temporal length of the session.
    nframes_t _nframes;

    /// The offset, in frames, of the current playback position.
    /// Should always be greater than or equal to 0 and less than `_nframes`.
    nframes_t _transportOffset;
}
