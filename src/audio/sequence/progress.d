module audio.sequence.progress;

private import util.progress;

/// Progress state for importing audio files from disk
alias LoadState = ProgressState!(StageDesc("read", "Loading file"),
                                 StageDesc("resample", "Resampling"),
                                 StageDesc("computeOverview", "Computing overview"));

/// Progress state for computing audio onsets for a region
alias ComputeOnsetsState = ProgressState!(StageDesc("computeOnsets", "Computing onsets"));

/// Progress state for adjusting the gain of a region or slice of a region
alias GainState = ProgressState!(StageDesc("gain", "Adjusting gain"));

/// Progress state for normalizing a region or a slice of a region
alias NormalizeState = ProgressState!(StageDesc("normalize", "Normalizing"));

/// Progress state for exporting data to a file on disk
alias SaveState = ProgressState!(StageDesc("write", "Writing file"));
