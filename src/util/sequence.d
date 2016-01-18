module util.sequence;

private import std.array;
private import std.container.dlist;
private import std.conv;

public import util.statehistory;

/// Evaluates to `true` if and only if the template argument can be indexed with array-like semantics
template isValidBuffer(Buffer) {
    enum isValidBuffer = is(typeof((Buffer.init)[size_t.init]));
}

/// Generic container for a "sequence" data structure.
/// This implementation is based on the paper "Data Structures for Text Sequences" by Charles Crowley.
/// The basic idea is that any changes made to the original data buffer are stored independently,
/// and the sequence is constructed on the fly as a series of slices. Each slice points to either the
/// original buffer or a modified buffer. This class also sits atop the `StateHistory` structure,
/// and thus has native support for undo/redo operations. Each state in the history consists of
/// a piece table representing the complete state of the sequence.
final class Sequence(Buffer) if(isValidBuffer!(Buffer)) {
public:
    /// The type of data contained by the `Buffer` type
    static if(is(Buffer == immutable(T), T)) {
        alias Element = typeof((T.init)[size_t.init]);
    }
    else {
        alias Element = typeof((Buffer.init)[size_t.init]);
    }

    /// Pointer to a buffer, used for caching a piece entry for fast access
    alias BufferCache = immutable(Buffer)*;

    /// The original buffer should not be empty
    this(immutable Buffer originalBuffer) {
        assert(originalBuffer.length > 0);

        PieceEntry[] table;
        table ~= PieceEntry(originalBuffer, 0);
        _stateHistory = new StateHistory!PieceTable(PieceTable(table));
    }

    /// Construct a sequence from a piece table; it should not be empty
    this(PieceTable initialPieceTable) {
        assert(initialPieceTable.length > 0);

        _stateHistory = new StateHistory!PieceTable(initialPieceTable);
    }

    /// Returns: `true` if and only if an undo operation is currently possible
    bool queryUndo() {
        return _stateHistory.queryUndo();
    }

    /// Returns: `true` if and only if a redo operation is currently possible
    bool queryRedo() {
        return _stateHistory.queryRedo();
    }

    /// Undo the last operation, if possible.
    /// This function will clear the redo history if the user subsequently appends a new operation.
    void undo() {
        _stateHistory.undo();
    }

    /// Redo the last operation, if possible.
    void redo() {
        _stateHistory.redo();
    }

    /// Insert a new buffer at `logicalOffset` and append the result to the piece table history
    void insert(T)(T buffer, size_t logicalOffset) {
        _appendToHistory(_currentPieceTable.insert(buffer, logicalOffset));
    }

    /// Append a new buffer at the end offset and append the result to the piece table history
    void append(T)(T buffer) {
        _appendToHistory(_currentPieceTable.append(buffer));
    }

    /// Delete all indices in the range [`logicalStart`, `logicalEnd`) and
    /// append the result to the piece table history
    void remove(size_t logicalStart, size_t logicalEnd) {
        _appendToHistory(_currentPieceTable.remove(logicalStart, logicalEnd));
    }

    /// Remove elements in the range [`logicalStart`, `logicalEnd`],
    /// then insert a new buffer at `logicalStart` and append the result to the piece table history
    void replace(T)(T buffer, size_t logicalStart, size_t logicalEnd) {
        _appendToHistory(_currentPieceTable.remove(logicalStart, logicalEnd).insert(buffer, logicalStart));
    }

    auto opSlice(size_t logicalStart, size_t logicalEnd) {
        return _currentPieceTable[logicalStart .. logicalEnd];
    }
    auto opSlice() {
        return _currentPieceTable[];
    }

    auto ref opIndex(size_t index) @nogc nothrow {
        return _currentPieceTable[index];
    }

    @property size_t length() const {
        return _currentPieceTable.length;
    }
    alias opDollar = length;

    Element[] toArray() {
        return _currentPieceTable.toArray();
    }

    override string toString() {
        return _currentPieceTable.toString();
    }

    /// Structure representing a single entry in a piece table.
    /// This is implemented via slices of type `Buffer`
    static struct PieceEntry {
        immutable Buffer buffer; /// The slice of data for this piece table entry
        size_t logicalOffset; /// The absolute offset of this piece in its corresponding piece table

        /// Retrieve the length of the buffer for this piece table entry
        @property size_t length() const {
            return buffer.length;
        }
    }

    /// Structure containing a table of `PieceEntry` objects.
    static struct PieceTable {
    public:
        /// Initialize the piece table with a simple array of `PieceEntry` objects
        this(PieceEntry[] table) {
            this.table = table;
        }

        /// Copy constructor
        this(const PieceTable pieceTable) {
            this.table = pieceTable.table.dup;
        }

        debug {
            /// Print all piece entries in a piece table, for debugging purposes
            void debugPrint() {
                import std.stdio : write, writeln;

                write("[");
                foreach(piece; table) {
                    write("(", piece.length, ", ", piece.logicalOffset, "), ");
                }
                writeln("]");
            }
        }

        /// Insert a new buffer at logicalOffset
        PieceTable insert(T)(T buffer, size_t logicalOffset) const
            if(is(T == Buffer) || is(T == immutable(Buffer)) || is(T == PieceTable)) {
                if(logicalOffset > logicalLength) {
                    // TODO implement logger
                    //derr.writefln("Warning: requested insertion to a piece table with length ", logicalLength,
                    //              " at logical offset ", logicalOffset);
                    return PieceTable();
                }

                // construct a new piece table appender
                Appender!(PieceEntry[]) pieceTable;

                // check if the existing table is empty
                if(table.empty) {
                    // insert the new piece provided by the given argument
                    static if(is(T == Buffer) || is(T == immutable(Buffer))) {
                        pieceTable.put(PieceEntry(cast(immutable)(buffer), 0));
                    }
                    else if(is(T == PieceTable)) {
                        foreach(piece; buffer.table) {
                            pieceTable.put(PieceEntry(piece.buffer, piece.logicalOffset));
                        }
                    }

                    return PieceTable(pieceTable.data);
                }

                // copy elements from the previous piece table until the insertion point is found
                size_t nCopied;
                foreach(ref piece; table) {
                    if(piece.logicalOffset + piece.length >= logicalOffset) {
                        break;
                    }
                    else {
                        pieceTable.put(piece);
                        ++nCopied;
                    }
                }

                if(table[nCopied].logicalOffset + table[nCopied].length >= logicalOffset) {
                    auto splitIndex = logicalOffset - table[nCopied].logicalOffset;
                    auto splitFirstHalfBuffer = table[nCopied].buffer[0 .. splitIndex];
                    auto splitSecondHalfBuffer = table[nCopied].buffer[splitIndex .. $];
                    if(splitFirstHalfBuffer.length > 0) {
                        pieceTable.put(PieceEntry(splitFirstHalfBuffer, table[nCopied].logicalOffset));
                    }

                    // insert the new piece provided by the given argument
                    static if(is(T == Buffer) || is(T == immutable(Buffer))) {
                        pieceTable.put(PieceEntry(cast(immutable)(buffer), logicalOffset));
                    }
                    else if(is(T == PieceTable)) {
                        foreach(piece; buffer.table) {
                            pieceTable.put(PieceEntry(piece.buffer, piece.logicalOffset + logicalOffset));
                        }
                    }

                    // insert another new piece containing the remaining part of the split piece
                    if(splitSecondHalfBuffer.length > 0) {
                        pieceTable.put(PieceEntry(splitSecondHalfBuffer, logicalOffset + buffer.length));
                    }
                }

                // copy the remaining pieces and fix their logical offsets
                ++nCopied;
                if(nCopied < table.length) {
                    foreach(i, ref piece; table[nCopied .. $]) {
                        pieceTable.put(PieceEntry(table[nCopied + i].buffer,
                                                  table[nCopied + i].logicalOffset + buffer.length));
                    }
                }

                return PieceTable(pieceTable.data);
            }

        /// Insert a new buffer at the ending offset
        PieceTable append(T)(T buffer) const {
            return insert(buffer, length);
        }

        /// Delete all indices in the range [`logicalStart`, `logicalEnd`)
        PieceTable remove(size_t logicalStart, size_t logicalEnd) const {
            // degenerate case
            if(logicalStart == logicalEnd) {
                return PieceTable();
            }

            // range checks
            if(logicalStart > logicalEnd ||
               logicalStart >= logicalLength ||
               logicalEnd > logicalLength) {
                // TODO implement logger
                //derr.writefln("Warning: invalid piece table removal slice [", logicalStart, " ", logicalEnd, "]");
                return PieceTable();
            }

            // construct a new piece table appender
            Appender!(PieceEntry[]) pieceTable;

            // skip all pieces in the piece table that end before logicalStart
            size_t nStartSkipped;
            foreach(ref piece; table) {
                if(piece.logicalOffset + piece.length >= logicalStart) {
                    break;
                }
                else {
                    pieceTable.put(piece);
                    ++nStartSkipped;
                }
            }

            // if logicalStart is contained within another piece, split that piece
            {
                auto immutable splitIndex = logicalStart - table[nStartSkipped].logicalOffset;
                auto immutable splitBuffer = table[nStartSkipped].buffer[0 .. splitIndex];
                if(splitBuffer.length > 0) {
                    pieceTable.put(PieceEntry(splitBuffer, table[nStartSkipped].logicalOffset));
                }
            }

            // skip all pieces between logicalStart and logicalEnd
            size_t nEndSkipped = nStartSkipped;
            if(nEndSkipped < table.length) {
                foreach(ref piece; table[nStartSkipped .. $]) {
                    if(piece.logicalOffset + piece.length >= logicalEnd) {
                        break;
                    }
                    else {
                        ++nEndSkipped;
                    }
                }
            }

            if(nEndSkipped < table.length) {
                // insert a new piece containing the remaining part of the split piece
                auto splitIndex = logicalEnd - table[nEndSkipped].logicalOffset;
                auto splitBuffer = table[nEndSkipped].buffer[splitIndex .. $];
                if(splitBuffer.length > 0) {
                    pieceTable.put(PieceEntry(splitBuffer, logicalStart));
                }

                // copy the remaining pieces and fix their logical offsets
                ++nEndSkipped;
                foreach(i, ref piece; table[nEndSkipped .. $]) {
                    pieceTable.put(PieceEntry(table[nEndSkipped + i].buffer,
                                              table[nEndSkipped + i].logicalOffset - (logicalEnd - logicalStart)));
                }
            }

            return PieceTable(pieceTable.data);
        }

        /// Params:
        /// index = A logical index into the sequence. This function asserts if the index is out of range.
        /// Returns: The element at the given logical index; optimized for ascending sequential access.
        auto ref opIndex(size_t index) @nogc nothrow {
            if(_cachedBuffer) {
                // if the index is in the cached buffer
                if(index >= _cachedBufferStart && index < _cachedBufferEnd) {
                    return (*_cachedBuffer)[index - _cachedBufferStart];
                }
                // try the next cache buffer, since most accesses should be sequential
                else if(++_cachedBufferIndex < table.length) {
                    _cachedBuffer = &(table[_cachedBufferIndex].buffer);
                    _cachedBufferStart = table[_cachedBufferIndex].logicalOffset;
                    _cachedBufferEnd = _cachedBufferStart + table[_cachedBufferIndex].length;
                    if(index >= _cachedBufferStart && index < _cachedBufferEnd) {
                        return (*_cachedBuffer)[index - _cachedBufferStart];
                    }
                }
            }

            // in case of random access, search the entire piece table for the index
            foreach(i, ref piece; table) {
                if(index >= piece.logicalOffset && index < piece.logicalOffset + piece.length) {
                    _cachedBuffer = &piece.buffer;
                    _cachedBufferIndex = i;
                    _cachedBufferStart = piece.logicalOffset;
                    _cachedBufferEnd = piece.logicalOffset + piece.length;
                    return (*_cachedBuffer)[index - _cachedBufferStart];
                }
            }

            // otherwise, the index was out of range
            assert(0, "range error when indexing sequence of buffer type: " ~ Buffer.stringof);
        }

        // Returns: A new piece table, with similar semantics to built-in array slicing
        PieceTable opSlice(size_t logicalStart, size_t logicalEnd) const {
            // degenerate case
            if(logicalStart == logicalEnd) {
                return PieceTable();
            }

            // range checks
            if(logicalStart > logicalEnd ||
               logicalStart >= logicalLength ||
               logicalEnd > logicalLength) {
                // TODO implement logger
                //derr.writefln("Warning: invalid piece table slice [", logicalStart, " ", logicalEnd, "]");
                return PieceTable();
            }

            // construct a new piece table appender
            Appender!(PieceEntry[]) pieceTable;

            // skip all pieces in the piece table that end before logicalStart
            size_t nStartSkipped;
            foreach(ref piece; table) {
                if(piece.logicalOffset + piece.length >= logicalStart) {
                    break;
                }
                else {
                    ++nStartSkipped;
                }
            }

            // if the current piece contains the entire slice
            if(table[nStartSkipped].logicalOffset + table[nStartSkipped].length >= logicalEnd) {
                auto sliceBuffer = table[nStartSkipped].buffer[logicalStart - table[nStartSkipped].logicalOffset ..
                                                               logicalEnd - table[nStartSkipped].logicalOffset];
                pieceTable.put(PieceEntry(sliceBuffer, 0));
                return PieceTable(pieceTable.data);
            }
            // otherwise, split the current piece
            else {
                auto splitIndex = logicalStart - table[nStartSkipped].logicalOffset;
                auto splitBuffer = table[nStartSkipped].buffer[splitIndex .. $];
                if(splitBuffer.length > 0) {
                    pieceTable.put(PieceEntry(splitBuffer, 0));
                }
            }

            // copy elements into the slice until the element ending past the end of the slice is found
            size_t nCopied = nStartSkipped + 1;
            foreach(ref piece; table[nCopied .. $]) {
                if(piece.logicalOffset + piece.length >= logicalEnd) {
                    break;
                }
                else {
                    pieceTable.put(PieceEntry(piece.buffer, piece.logicalOffset - logicalStart));
                    ++nCopied;
                }
            }

            // insert the last element in the slice
            immutable size_t endIndex = nCopied;
            if(endIndex < table.length && table[endIndex].logicalOffset < logicalEnd) {
                auto splitBuffer = table[endIndex].buffer[0 .. logicalEnd - table[endIndex].logicalOffset];
                pieceTable.put(PieceEntry(splitBuffer, table[endIndex].logicalOffset - logicalStart));
            }

            // return the slice
            return PieceTable(pieceTable.data);
        }

        /// Copy this piece table
        PieceTable opSlice() const {
            return PieceTable(this);
        }

        /// Returns the logical length of the piece table.
        /// This is equivalent to the sum of all the lengths of all piece table entries.
        @property size_t logicalLength() const {
            if(table.length > 0) {
                return table[$ - 1].logicalOffset + table[$ - 1].length;
            }
            return 0;
        }

        alias length = logicalLength;
        alias opDollar = length;

        T opCast(T : bool)() const {
            return length > 0;
        }

        /// This function allows this class to be used as a Forward Range.
        /// Returns: `true` if and only if all elements in the piece table have been popped from the range.
        @property bool empty() const {
            return _pos >= length;
        }

        /// This function allows this class to be used as a Forward Range.
        /// Returns: the front element of the range.
        @property auto ref front() {
            return this[_pos];
        }

        /// This function allows this class to be used as a Forward Range.
        /// Removes the front element from the range.
        void popFront() {
            ++_pos;
        }

        /// This function allows this class to be used as a Forward Range.
        /// It simply copies the piece table object.
        @property auto save() const {
            return PieceTable(this);
        }

        /// Copies all elements in the piece table, in logical order, into a new array
        Element[] toArray() const {
            auto result = appender!(Element[]);
            foreach(piece; table) {
                for(auto i = 0; i < piece.length; ++i) {
                    result.put(cast(Element)(piece.buffer[i]));
                }
            }
            return result.data;
        }

        /// Formats all elements in the piece table, in logical order, into a string.
        /// This is only practically useful as a debugging aid.
        string toString() const {
            return to!string(toArray);
        }

        /// The actual piece table is implemented as an array of `PieceEntry` objects
        PieceEntry[] table;

    private:
        /// The current position in the piece table, when this structure is used as a Forward Range
        size_t _pos;

        BufferCache _cachedBuffer;
        size_t _cachedBufferIndex;
        size_t _cachedBufferStart;
        size_t _cachedBufferEnd;
    }

private:
    void _appendToHistory(PieceEntry[] pieceTable) {
        _stateHistory.appendState(PieceTable(pieceTable));
    }

    void _appendToHistory(PieceTable pieceTable) {
        _stateHistory.appendState(pieceTable);
    }

    @property ref PieceTable _currentPieceTable() @nogc nothrow {
        return _stateHistory.currentState;
    }
    @property ref const(PieceTable) _currentPieceTable() const @nogc nothrow {
        return _stateHistory.currentState;
    }

    StateHistory!(PieceTable) _stateHistory;
}

/// Test sequence indexing
unittest {
    alias IntSeq = Sequence!(int[]);

    int[] intArray = [1, 2, 3];
    IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

    intSeq.insert([4, 5], 0);
    intSeq.insert([6, 7], 1);
    assert(intSeq.toArray() == [4, 6, 7, 5, 1, 2, 3]);

    assert(intSeq[0] == 4);
    assert(intSeq[1] == 6);
    assert(intSeq[2] == 7);
    assert(intSeq[3] == 5);
    assert(intSeq[4] == 1);
    assert(intSeq[5] == 2);
    assert(intSeq[6] == 3);

    assert(intSeq[2] == 7);
    assert(intSeq[6] == 3);
    assert(intSeq[3] == 5);
}

/// Test sequence slicing
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));
 
        assert(intSeq.toArray() == [1, 2, 3, 4]);
        assert(intSeq.length == intArray.length);

        assert(intSeq[0 .. 0].toArray() == intArray[0 .. 0]);
        assert(intSeq[0 .. $].toArray() == intArray[0 .. $]);
        assert(intSeq[0 .. 1].toArray() == intArray[0 .. 1]);
        assert(intSeq[0 .. 2].toArray() == intArray[0 .. 2]);
        assert(intSeq[0 .. 3].toArray() == intArray[0 .. 3]);

        assert(intSeq[1 .. 1].toArray() == intArray[1 .. 1]);
        assert(intSeq[1 .. 2].toArray() == intArray[1 .. 2]);
        assert(intSeq[1 .. 3].toArray() == intArray[1 .. 3]);
        assert(intSeq[1 .. $].toArray() == intArray[1 .. $]);

        assert(intSeq[2 .. 3].toArray() == intArray[2 .. 3]);
        assert(intSeq[2 .. $].toArray() == intArray[2 .. $]);

        assert(intSeq[3 .. $].toArray() == intArray[3 .. $]);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.insert([5, 6], 2);
        intSeq.insert([7, 8, 9], 5);
        intSeq.insert([10, 11], 0);
        intSeq.insert([12, 13], 2);

        int[] newArray = [10, 11, 12, 13, 1, 2, 5, 6, 3, 7, 8, 9, 4];
        assert(intSeq.toArray() == newArray);

        assert(intSeq.toArray() == newArray);
        assert(intSeq[0 .. $].toArray() == newArray);
        assert(intSeq[0 .. 1].toArray() == newArray[0 .. 1]);
        assert(intSeq[1 .. 4].toArray() == newArray[1 .. 4]);
        assert(intSeq[2 .. 7].toArray() == newArray[2 .. 7]);
        assert(intSeq[3 .. 5].toArray() == newArray[3 .. 5]);
        assert(intSeq[8 .. 9].toArray() == newArray[8 .. 9]);
        assert(intSeq[5 .. 10].toArray() == newArray[5 .. 10]);
        assert(intSeq[11 .. 12].toArray() == newArray[11 .. 12]);
    }
}

/// Test sequence insertion
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.insert([2], 0);
        assert(intSeq.toArray() == [2, 1]);

        intSeq.insert([3], 1);
        assert(intSeq.toArray() == [2, 3, 1]);

        intSeq.insert([4], intSeq.length);
        assert(intSeq.toArray() == [2, 3, 1, 4]);
    }

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.insert([3, 4], 2);
        assert(intSeq.toArray() == [1, 2, 3, 4]);

        intSeq.insert([5, 6], 2);
        assert(intSeq.toArray() == [1, 2, 5, 6, 3, 4]);

        intSeq.insert([6, 7], 1);
        assert(intSeq.toArray() == [1, 6, 7, 2, 5, 6, 3, 4]);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.insert([5, 6], 2);
        assert(intSeq.toArray() == [1, 2, 5, 6, 3, 4]);

        intSeq.insert([7, 8, 9], 5);
        assert(intSeq.toArray() == [1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.insert([10, 11], 0);
        assert(intSeq.toArray() == [10, 11, 1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.insert([12], 6);
        assert(intSeq.toArray() == [10, 11, 1, 2, 5, 6, 12, 3, 7, 8, 9, 4]);

        intSeq.insert([13], 8);
        assert(intSeq.toArray() == [10, 11, 1, 2, 5, 6, 12, 3, 13, 7, 8, 9, 4]);

        intSeq.insert([13, 14], 2);
        assert(intSeq.toArray() == [10, 11, 13, 14, 1, 2, 5, 6, 12, 3, 13, 7, 8, 9, 4]);

        intSeq.insert([15], 13);
        assert(intSeq.toArray() == [10, 11, 13, 14, 1, 2, 5, 6, 12, 3, 13, 7, 8, 15, 9, 4]);
    }
}

/// Test sequence appending
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.append([4]);
        assert(intSeq.toArray() == [1, 2, 3, 4]);

        intSeq.append([5, 6]);
        assert(intSeq.toArray() == [1, 2, 3, 4, 5, 6]);

        intSeq.append([7, 8, 9]);
        assert(intSeq.toArray() == [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    }
}

/// Test sequence removal
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.remove(0, 1);
        assert(intSeq.toArray() == [2, 3, 4]);

        intSeq.remove(1, 2);
        assert(intSeq.toArray() == [2, 4]);

        intSeq.remove(0, 1);
        assert(intSeq.toArray() == [4]);

        intSeq.remove(0, 1);
        assert(intSeq.toArray() == []);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.insert([5, 6], 2);
        intSeq.insert([7, 8, 9], 5);
        intSeq.insert([10, 11], 0);
        intSeq.insert([12, 13], 2);
        assert(intSeq.toArray() == [10, 11, 12, 13, 1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.remove(3, 4);
        assert(intSeq.toArray() == [10, 11, 12, 1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.remove(11, 12);
        assert(intSeq.toArray() == [10, 11, 12, 1, 2, 5, 6, 3, 7, 8, 9]);

        intSeq.remove(2, 7);
        assert(intSeq.toArray() == [10, 11, 3, 7, 8, 9]);

        intSeq.remove(2, 3);
        assert(intSeq.toArray() == [10, 11, 7, 8, 9]);

        intSeq.remove(3, 5);
        assert(intSeq.toArray() == [10, 11, 7]);

        intSeq.remove(0, 3);
        assert(intSeq.toArray() == []);
    }
}

/// Test sequence replacement
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.replace([5], 3, 4);
        assert(intSeq.toArray() == [1, 2, 3, 5]);

        intSeq.replace([6, 7, 8], 0, 2);
        assert(intSeq.toArray() == [6, 7, 8, 3, 5]);

        intSeq.replace([9, 10], 2, 4);
        assert(intSeq.toArray() == [6, 7, 9, 10, 5]);
    }

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.replace([3, 4], 0, 2);
        assert(intSeq.toArray() == [3, 4]);
    }
}

/// Test sequence iteration
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(cast(immutable)(intArray));

        intSeq.insert([3, 4], 0);
        intSeq.insert([5, 6], 3);
        intSeq.insert([7], 6);
        assert(intSeq.toArray() == [3, 4, 1, 5, 6, 2, 7]);

        auto app = appender!(int[]);
        foreach(i; intSeq) {
            app.put(i);
        }
        assert(app.data == [3, 4, 1, 5, 6, 2, 7]);

        auto app2 = appender!(int[]);
        foreach(i; intSeq) {
            app2.put(i);
        }
        assert(app2.data == [3, 4, 1, 5, 6, 2, 7]);
    }
}
