module audio.importfile.resamplecallback;

public import std.typecons;

public import audio.region.samplerate;
public import audio.types;

/// Delegate type, useful for displaying a GUI that prompts the user to select resampling options
alias ResampleCallback = Nullable!SampleRateConverter delegate(nframes_t originalSampleRate,
                                                               nframes_t newSampleRate);
