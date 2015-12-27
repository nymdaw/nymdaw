module audio.sequence.onset;

private import util.sequence;

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
