module util.sequence;

public import util.statehistory;

private import std.array;
private import std.container.dlist;
private import std.conv;
private import std.cstream : derr;

private import core.sync.mutex;

template isValidBuffer(Buffer) {
    enum isValidBuffer = is(typeof((Buffer.init)[size_t.init]));
}

final class Sequence(Buffer) if(isValidBuffer!(Buffer)) {
public:
    static if(is(Buffer == U[], U)) {
        enum BufferCacheIsPointer = false;
        alias BufferCache = Buffer;
    }
    else {
        enum BufferCacheIsPointer = true;
        alias BufferCache = Buffer*;
    }

    alias Element = typeof((Buffer.init)[size_t.init]);

    // original buffer must not be empty
    this(Buffer originalBuffer) {
        assert(originalBuffer.length > 0);
        _originalBuffer = originalBuffer;

        _mutex = new Mutex;

        PieceEntry[] table;
        table ~= PieceEntry(_originalBuffer, 0);
        _stateHistory = new StateHistory!PieceTable(PieceTable(table));
    }

    bool queryUndo() {
        return _stateHistory.queryUndo();
    }
    bool queryRedo() {
        return _stateHistory.queryRedo();
    }

    void undo() {
        _stateHistory.undo();
    }
    void redo() {
        _stateHistory.redo();
    }

    // insert a new buffer at logicalOffset and append the result to the piece table history
    void insert(T)(T buffer, size_t logicalOffset) {
        synchronized(_mutex) {
            _appendToHistory(_currentPieceTable.insert(buffer, logicalOffset));
        }
    }

    // delete all indices in the range [logicalStart, logicalEnd) and
    // append the result to the piece table history
    void remove(size_t logicalStart, size_t logicalEnd) {
        synchronized(_mutex) {
            _appendToHistory(_currentPieceTable.remove(logicalStart, logicalEnd));
        }
    }

    // removes elements in the given range, then insert a new buffer at the start of that range
    // append the result to the piece table history
    void replace(T)(T buffer, size_t logicalStart, size_t logicalEnd) {
        synchronized(_mutex) {
            _appendToHistory(_currentPieceTable.remove(logicalStart, logicalEnd).insert(buffer, logicalStart));
        }
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

    @property size_t length() {
        return _currentPieceTable.length;
    }
    alias opDollar = length;

    Element[] toArray() {
        return _currentPieceTable.toArray();
    }

    override string toString() {
        return _currentPieceTable.toString();
    }

    static struct PieceEntry {
        Buffer buffer;
        size_t logicalOffset;

        @property size_t length() {
            return buffer.length;
        }
    }

    static struct PieceTable {
    public:
        this(PieceEntry[] table) {
            this.table = table;
        }

        debug {
            void debugPrint() {
                import std.stdio : write, writeln;

                write("[");
                foreach(piece; table) {
                    write("(", piece.length, ", ", piece.logicalOffset, "), ");
                }
                writeln("]");
            }
        }

        // insert a new buffer at logicalOffset
        PieceTable insert(T)(T buffer, size_t logicalOffset)
            if(is(T == Buffer) || is(T == PieceTable)) {
                if(logicalOffset > logicalLength) {
                    derr.writefln("Warning: requested insertion to a piece table with length ", logicalLength,
                                  " at logical offset ", logicalOffset);
                    return PieceTable();
                }

                // construct a new piece table appender
                Appender!(PieceEntry[]) pieceTable;

                // check if the existing table is empty
                if(table.empty) {
                    // insert the new piece provided by the given argument
                    static if(is(T == Buffer)) {
                        pieceTable.put(PieceEntry(buffer, 0));
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
                    static if(is(T == Buffer)) {
                        pieceTable.put(PieceEntry(buffer, logicalOffset));
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

        // delete all indices in the range [logicalStart, logicalEnd)
        PieceTable remove(size_t logicalStart, size_t logicalEnd) {
            // degenerate case
            if(logicalStart == logicalEnd) {
                return PieceTable();
            }

            // range checks
            if(logicalStart > logicalEnd ||
               logicalStart >= logicalLength ||
               logicalEnd > logicalLength) {
                derr.writefln("Warning: invalid piece table removal slice [", logicalStart, " ", logicalEnd, "]");
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
                auto splitIndex = logicalStart - table[nStartSkipped].logicalOffset;
                auto splitBuffer = table[nStartSkipped].buffer[0 .. splitIndex];
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

        // return the element at the given logical index; optimized for ascending sequential access
        // asserts if the index is out of range
        auto ref opIndex(size_t index) @nogc nothrow {
            if(_cachedBuffer) {
                // if the index is in the cached buffer
                if(index >= _cachedBufferStart && index < _cachedBufferEnd) {
                    static if(BufferCacheIsPointer) {
                        return (*_cachedBuffer)[index - _cachedBufferStart];
                    }
                    else {
                        return _cachedBuffer[index - _cachedBufferStart];
                    }
                }
                // try the next cache buffer, since most accesses should be sequential
                else if(++_cachedBufferIndex < table.length) {
                    static if(BufferCacheIsPointer) {
                        _cachedBuffer = &(table[_cachedBufferIndex].buffer);
                    }
                    else {
                        _cachedBuffer = table[_cachedBufferIndex].buffer;
                    }
                    _cachedBufferStart = table[_cachedBufferIndex].logicalOffset;
                    _cachedBufferEnd = _cachedBufferStart + table[_cachedBufferIndex].length;
                    if(index >= _cachedBufferStart && index < _cachedBufferEnd) {
                        static if(BufferCacheIsPointer) {
                            return (*_cachedBuffer)[index - _cachedBufferStart];
                        }
                        else {
                            return _cachedBuffer[index - _cachedBufferStart];
                        }
                    }
                }
            }

            // in case of random access, search the entire piece table for the index
            foreach(i, ref piece; table) {
                if(index >= piece.logicalOffset && index < piece.logicalOffset + piece.length) {
                    static if(BufferCacheIsPointer) {
                        _cachedBuffer = &piece.buffer;
                    }
                    else {
                        _cachedBuffer = piece.buffer;
                    }
                    _cachedBufferIndex = i;
                    _cachedBufferStart = piece.logicalOffset;
                    _cachedBufferEnd = piece.logicalOffset + piece.length;
                    static if(BufferCacheIsPointer) {
                        return (*_cachedBuffer)[index - _cachedBufferStart];
                    }
                    else {
                        return _cachedBuffer[index - _cachedBufferStart];
                    }
                }
            }

            // otherwise, the index was out of range
            assert(0, "range error when indexing sequence of buffer type: " ~ Buffer.stringof);
        }

        // returns a new piece table, with similar semantics to built-in array slicing
        PieceTable opSlice(size_t logicalStart, size_t logicalEnd) {
            // degenerate case
            if(logicalStart == logicalEnd) {
                return PieceTable();
            }

            // range checks
            if(logicalStart > logicalEnd ||
               logicalStart >= logicalLength ||
               logicalEnd > logicalLength) {
                derr.writefln("Warning: invalid piece table slice [", logicalStart, " ", logicalEnd, "]");
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

        // copy this piece table
        PieceTable opSlice() {
            return this;
        }

        @property size_t logicalLength() {
            if(table.length > 0) {
                return table[$ - 1].logicalOffset + table[$ - 1].length;
            }
            return 0;
        }

        alias length = logicalLength;
        alias opDollar = length;

        T opCast(T : bool)() {
            return length > 0;
        }

        @property bool empty() {
            return _pos >= length;
        }

        @property auto ref front() {
            return this[_pos];
        }

        void popFront() {
            ++_pos;
        }

        @property auto save() {
            return this;
        }

        Element[] toArray() {
            auto result = appender!(Element[]);
            foreach(piece; table) {
                for(auto i = 0; i < piece.length; ++i) {
                    result.put(piece.buffer[i]);
                }
            }
            return result.data;
        }

        string toString() {
            return to!string(toArray);
        }

        PieceEntry[] table;

    private:
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

    Mutex _mutex;

    Buffer _originalBuffer;
    StateHistory!(PieceTable) _stateHistory;
}

// test sequence indexing
unittest {
    alias IntSeq = SequenceT!(int[]).Sequence;

    int[] intArray = [1, 2, 3];
    IntSeq intSeq = new IntSeq(intArray);

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

// test sequence slicing
unittest {
    alias IntSeq = SequenceT!(int[]).Sequence;

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);
 
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
        IntSeq intSeq = new IntSeq(intArray);

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

// test sequence insertion
unittest {
    alias IntSeq = SequenceT!(int[]).Sequence;

    {
        int[] intArray = [1];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([2], 0);
        assert(intSeq.toArray() == [2, 1]);

        intSeq.insert([3], 1);
        assert(intSeq.toArray() == [2, 3, 1]);

        intSeq.insert([4], intSeq.length);
        assert(intSeq.toArray() == [2, 3, 1, 4]);
    }

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([3, 4], 2);
        assert(intSeq.toArray() == [1, 2, 3, 4]);

        intSeq.insert([5, 6], 2);
        assert(intSeq.toArray() == [1, 2, 5, 6, 3, 4]);

        intSeq.insert([6, 7], 1);
        assert(intSeq.toArray() == [1, 6, 7, 2, 5, 6, 3, 4]);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

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

// test sequence removal
unittest {
    alias IntSeq = SequenceT!(int[]).Sequence;

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

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
        IntSeq intSeq = new IntSeq(intArray);

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

// test sequence replacement
unittest {
    alias IntSeq = SequenceT!(int[]).Sequence;

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.replace([5], 3, 4);
        assert(intSeq.toArray() == [1, 2, 3, 5]);

        intSeq.replace([6, 7, 8], 0, 2);
        assert(intSeq.toArray() == [6, 7, 8, 3, 5]);

        intSeq.replace([9, 10], 2, 4);
        assert(intSeq.toArray() == [6, 7, 9, 10, 5]);
    }

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.replace([3, 4], 0, 2);
        assert(intSeq.toArray() == [3, 4]);
    }
}

// test sequence iteration
unittest {
    alias IntSeq = SequenceT!(int[]).Sequence;

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(intArray);

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
