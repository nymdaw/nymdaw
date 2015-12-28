module audio.exportfile.format;

/// Enumeration of all currently supported audio file formats
enum AudioFileFormat {
    wavFilterName = "WAV",
    flacFilterName = "FLAC",
    oggVorbisFilterName = "Ogg/Vorbis",
    aiffFilterName = "AIFF",
    cafFilterName = "CAF",
}

/// Enumeration for audio bit depths, used for exporting audio files
enum AudioBitDepth {
    pcm16Bit,
    pcm24Bit
}
