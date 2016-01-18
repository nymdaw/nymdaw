module audio.sequence.sequence;

private import std.container.dlist;

private import util.sequence;

public import audio.region;
public import audio.sequence.segment;
public import audio.types;

/// A wrapper around a generic sequence, specific to audio regions.
/// Stores a list of registered region "links", which are typically referred to as "soft copies" in the UI.
/// This allows edits to a sequence to be immediatley reflected in all regions "linked" to the that sequence.
final class AudioSequence {
public:
    /// Polymorphic base class for implementing links
    static class Link {
        this(Region region) {
            this.region = region;
        }

        string name() {
            return region.name;
        }

        /// The region object associated with this link
        Region region;
    }

    /// Params:
    /// originalBuffer = Raw, interleaved audio data from which to initialize this sequence
    /// sampleRate = The sampling rate, in samples per second, of the audio data
    /// nChannels = The number of channels in the audio data
    /// name = The name of sequence. This is ypically the name of the file from which the audio data was read.
    this(immutable(AudioSegment) originalBuffer, nframes_t sampleRate, channels_t nChannels, string name) {
        sequence = new Sequence!(AudioSegment)(originalBuffer);

        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _name = name;
    }

    /// Params:
    /// originalPieceTable = A precomputed piece table with which to initialize this sequence
    /// sampleRate = The sampling rate, in samples per second, of the audio data
    /// nChannels = The number of channels in the audio data
    /// name = The name of sequence. This is ypically the name of the file from which the audio data was read.
    this(AudioPieceTable originalPieceTable, nframes_t sampleRate, channels_t nChannels, string name) {
        sequence = new Sequence!(AudioSegment)(originalPieceTable);

        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _name = name;
    }

    /// Copy constructor for creating a hard copy based on the current state of this sequence
    this(AudioSequence other) {
        this(cast(immutable)(AudioSegment(cast(immutable)(other.sequence[].toArray()), other.nChannels)),
             other.sampleRate, other.nChannels, other.name ~ " (copy)");
    }

    /// The sequence implementation
    Sequence!(AudioSegment) sequence;
    alias sequence this;

    /// The piece table type for the sequence implementation
    alias AudioPieceTable = Sequence!(AudioSegment).PieceTable;

    /// The piece entry type for hte sequence implementation
    alias AudioPieceEntry = Sequence!(AudioSegment).PieceEntry;

    /// Registers a soft link with this sequence
    void addSoftLink(Link link) {
        _softLinks.insertBack(link);
    }

    /// Removes a soft link that was previoulsy registered with this sequence
    /// Params:
    /// link = The soft link object to remove
    /// equal = An equality predicate for comparing currently registered links with the link to be removed
    void removeSoftLink(T)(T link, bool function(T x, T y) equal = function bool(T x, T y) { return x is y; })
        if(is(T : Link)) {
            auto softLinkRange = _softLinks[];
            for(; !softLinkRange.empty; softLinkRange.popFront()) {
                auto front = cast(T)(softLinkRange.front);
                if(front !is null && equal(front, link)) {
                    _softLinks.linearRemove(take(softLinkRange, 1));
                    break;
                }
            }
        }

    /// Call this function when a region is edited.
    /// This will reflect the edits to that region to all other regions linked to the
    /// sequence corresponding to the edited region.
    void updateSoftLinks(nframes_t prevNFrames, nframes_t newNFrames) {
        auto softLinkRange = _softLinks[];
        for(; !softLinkRange.empty; softLinkRange.popFront()) {
            softLinkRange.front.region.updateSliceEnd(prevNFrames, newNFrames);
        }
    }

    /// Returns: A forward range of consisting of all links registered with this sequence.
    @property auto softLinks() { return _softLinks[]; }

    /// The total number of frames in the sequence
    @property nframes_t nframes() { return cast(nframes_t)(sequence.length / nChannels); }

    /// The sampling rate of the sequence, in samples per second
    @property nframes_t sampleRate() const { return _sampleRate; }

    /// The number of interleaved channels in the sequence's audio buffers
    @property channels_t nChannels() const { return _nChannels; }

    /// The name of the sequence. This is typically the name of the file from which the audio data was read.
    @property string name() const { return _name; }

private:
    DList!Link _softLinks;

    immutable nframes_t _sampleRate;
    immutable channels_t _nChannels;
    immutable string _name;
}
