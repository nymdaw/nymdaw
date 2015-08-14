module dseq;

import std.stdio;
import std.conv;
import std.algorithm;
import std.array;
import std.path;
import std.math;
import std.getopt;
import std.string;
import std.format;
import std.random;
import std.container;
import std.uni;
import std.concurrency;
import std.parallelism;
import std.typecons;
import std.traits;
import std.typetuple;
import std.range;
import std.cstream;

import core.memory;
import core.time;

version(HAVE_JACK) {
    import jack.jack;
}

import sndfile;
import samplerate;
import aubio;
import rubberband;
import meters;

import gtk.Window;
import gtk.MainWindow;
import gtk.Main;
import gtk.Widget;
import gtk.Box;
import gtk.DrawingArea;
import gtk.Adjustment;
import gtk.Scrollbar;
import gtk.Menu;
import gtk.MenuItem;
import gtk.CheckMenuItem;
import gtk.Dialog;
import gtk.Label;
import gtk.ButtonBox;
import gtk.Button;
import gtk.Scale;
import gtk.FileChooserDialog;
import gtk.MessageDialog;
import gtk.ProgressBar;
import gtk.RadioButton;
import gtk.Entry;

import gtkc.gtktypes;

import gdk.Cursor;
import gdk.Display;
import gdk.Event;
import gdk.Keymap;
import gdk.Keysyms;
import gdk.Screen;

import glib.Timeout;
import glib.ListSG;
import glib.Str;
import glib.URI;

import cairo.Context;
import cairo.Pattern;
import cairo.Surface;

import pango.PgCairo;
import pango.PgLayout;
import pango.PgFontDescription;

class AudioError: Exception {
    this(string msg) {
        super(msg);
    }
}

version(HAVE_JACK) {
    alias nframes_t = jack_nframes_t;
    alias sample_t = jack_default_audio_sample_t;
}
else {
    alias nframes_t = uint;
    alias sample_t = float;
}
alias channels_t = uint;
alias ResizeDelegate = bool delegate(nframes_t);

alias pixels_t = int;

struct ScopedArray(T) if (is(T t == U[], U)) {
public:
    alias ArrayType = T;
    ArrayType data;
    alias data this;

    this(ArrayType rhs) {
        data = rhs;
    }

    void opAssign(ArrayType rhs) {
        _destroyData();
        data = rhs;
    }

    ~this() {
        _destroyData();
    }

private:
     template rank(T) {
        static if(is(T t == U[], U)) {
            enum size_t rank = 1 + rank!U;
        }
        else {
            enum size_t rank = 0;
        }
    }

    template destroySubArrays(string S, T) {
        enum element = "element" ~ to!string(rank!T);

        static if(rank!T > 1 && is(T t == U[], U)) {
            enum rec = destroySubArrays!(element, U);
        }
        else {
            enum rec = "";
        }

        enum destroySubArrays = "foreach(" ~ element ~ "; " ~ S ~ ") {" ~
            rec ~ element ~ ".destroy(); GC.free(&" ~ element ~ "); }";
    }

    void _destroyData() {
        static if(rank!ArrayType > 1) {
            mixin(destroySubArrays!("data", ArrayType));
        }
        data.destroy();
        GC.free(&data);
    }
}

struct StateHistory(T) {
public:
    this(T initialState) {
        _undoHistory.insertFront(initialState);
    }

    @disable this();

    // returns true if an undo operation is currently possible
    bool queryUndo() {
        auto undoRange = _undoHistory[];
        if(!undoRange.empty) {
            // the undo history must always contain at least one element
            undoRange.popFront();
            return !undoRange.empty();
        }
        return false;
    }

    // returns true if a redo operation is currently possible
    bool queryRedo() {
        auto redoRange = _redoHistory[];
        return !redoRange.empty;
    }

    // undo the last operation, if possible
    // this function will clear the redo history if the user subsequently appends new operation
    void undo() {
        auto operation = takeOne(retro(_undoHistory[]));
        if(!operation.empty) {
            // never remove the last element in the undo history
            auto newUndoHistory = _undoHistory[];
            newUndoHistory.popFront();
            if(!newUndoHistory.empty) {
                _undoHistory.removeBack(1);
                _redoHistory.insertFront(operation);
                _clearRedoHistory = true;
            }
        }
    }

    // redo the last operation, if possible
    void redo() {
        auto operation = takeOne(_redoHistory[]);
        if(!operation.empty) {
            _redoHistory.removeFront(1);
            _undoHistory.insertBack(operation);
        }
    }

    // execute this function when the user effects a new undo-able state
    void appendState(T t) {
        _undoHistory.insertBack(t);

        if(_clearRedoHistory) {
            _clearRedoHistory = false;
            _redoHistory.clear();
        }
    }

    // returns the current user-modifiable state
    @property ref T currentState() @nogc nothrow {
        return _undoHistory.back;
    }

private:
    alias HistoryContainer = DList!T;
    HistoryContainer _undoHistory;
    HistoryContainer _redoHistory;

    bool _clearRedoHistory;
}

class Sequence(Buffer) if(is(typeof((Buffer.init)[size_t.init]))) {
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
        this.originalBuffer = originalBuffer;

        PieceEntry[] table;
        table ~= PieceEntry(originalBuffer, 0);
        stateHistory = StateHistory!PieceTable(PieceTable(table));
    }

    bool queryUndo() {
        return stateHistory.queryUndo();
    }
    bool queryRedo() {
        return stateHistory.queryRedo();
    }

    void undo() {
        stateHistory.undo();
    }
    void redo() {
        stateHistory.redo();
    }

    // insert a new buffer at logicalOffset and append the result to the piece table history
    void insert(T)(T buffer, size_t logicalOffset) {
        appendToHistory(currentPieceTable.insert(buffer, logicalOffset));
    }

    // delete all indices in the range [logicalStart, logicalEnd) and append the result to the piece table history
    void remove(size_t logicalStart, size_t logicalEnd) {
        appendToHistory(currentPieceTable.remove(logicalStart, logicalEnd));
    }

    // removes elements in the given range, then insert a new buffer at the start of that range
    // append the result to the piece table history
    void replace(T)(T buffer, size_t logicalStart, size_t logicalEnd) {
        appendToHistory(currentPieceTable.remove(logicalStart, logicalEnd).insert(buffer, logicalStart));
    }

    struct PieceEntry {
        Buffer buffer;
        size_t logicalOffset;

        @property size_t length() const {
            return buffer.length;
        }
    }

    struct PieceTable {
    public:
        this(PieceEntry[] table) {
            this.table = table;
        }

        debug:
        void debugPrint() {
            write("[");
            foreach(piece; table) {
                write("(", piece.length, ", ", piece.logicalOffset, "), ");
            }
            writeln("]");
        }

        // insert a new buffer at logicalOffset
        PieceTable insert(T)(T buffer, size_t logicalOffset) if(is(T == Buffer) || is(T == PieceTable)) {
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

        @property size_t logicalLength() const {
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

        @property bool empty() const {
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

        @property Element[] toArray() {
            auto result = appender!(Element[]);
            foreach(piece; table) {
                for(auto i = 0; i < piece.length; ++i) {
                    result.put(piece.buffer[i]);
                }
            }
            return result.data;
        }

        @property string toString() {
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

    void appendToHistory(PieceEntry[] pieceTable) {
        stateHistory.appendState(PieceTable(pieceTable));
    }
    void appendToHistory(PieceTable pieceTable) {
        stateHistory.appendState(pieceTable);
    }

    @property ref PieceTable currentPieceTable() @nogc nothrow {
        return stateHistory.currentState;
    }
    alias currentPieceTable this;

protected:
    Buffer originalBuffer;
    StateHistory!PieceTable stateHistory;
}

// test sequence indexing
unittest {
    alias IntSeq = Sequence!(int[]);

    int[] intArray = [1, 2, 3];
    IntSeq intSeq = new IntSeq(intArray);

    intSeq.insert([4, 5], 0);
    intSeq.insert([6, 7], 1);
    assert(intSeq.toArray == [4, 6, 7, 5, 1, 2, 3]);

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
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        assert(intSeq.toArray == [1, 2, 3, 4]);
        assert(intSeq.logicalLength == intArray.length);

        assert(intSeq[0 .. 0].toArray == intArray[0 .. 0]);
        assert(intSeq[0 .. $].toArray == intArray[0 .. $]);
        assert(intSeq[0 .. 1].toArray == intArray[0 .. 1]);
        assert(intSeq[0 .. 2].toArray == intArray[0 .. 2]);
        assert(intSeq[0 .. 3].toArray == intArray[0 .. 3]);

        assert(intSeq[1 .. 1].toArray == intArray[1 .. 1]);
        assert(intSeq[1 .. 2].toArray == intArray[1 .. 2]);
        assert(intSeq[1 .. 3].toArray == intArray[1 .. 3]);
        assert(intSeq[1 .. $].toArray == intArray[1 .. $]);

        assert(intSeq[2 .. 3].toArray == intArray[2 .. 3]);
        assert(intSeq[2 .. $].toArray == intArray[2 .. $]);

        assert(intSeq[3 .. $].toArray == intArray[3 .. $]);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([5, 6], 2);
        intSeq.insert([7, 8, 9], 5);
        intSeq.insert([10, 11], 0);
        intSeq.insert([12, 13], 2);

        int[] newArray = [10, 11, 12, 13, 1, 2, 5, 6, 3, 7, 8, 9, 4];
        assert(intSeq.toArray == newArray);

        assert(intSeq[].toArray == newArray);
        assert(intSeq[0 .. $].toArray == newArray);
        assert(intSeq[0 .. 1].toArray == newArray[0 .. 1]);
        assert(intSeq[1 .. 4].toArray == newArray[1 .. 4]);
        assert(intSeq[2 .. 7].toArray == newArray[2 .. 7]);
        assert(intSeq[3 .. 5].toArray == newArray[3 .. 5]);
        assert(intSeq[8 .. 9].toArray == newArray[8 .. 9]);
        assert(intSeq[5 .. 10].toArray == newArray[5 .. 10]);
        assert(intSeq[11 .. 12].toArray == newArray[11 .. 12]);
    }
}

// test sequence insertion
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([2], 0);
        assert(intSeq.toArray == [2, 1]);

        intSeq.insert([3], 1);
        assert(intSeq.toArray == [2, 3, 1]);

        intSeq.insert([4], intSeq.logicalLength);
        assert(intSeq.toArray == [2, 3, 1, 4]);
    }

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([3, 4], 2);
        assert(intSeq.toArray == [1, 2, 3, 4]);

        intSeq.insert([5, 6], 2);
        assert(intSeq.toArray == [1, 2, 5, 6, 3, 4]);

        intSeq.insert([6, 7], 1);
        assert(intSeq.toArray == [1, 6, 7, 2, 5, 6, 3, 4]);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([5, 6], 2);
        assert(intSeq.toArray == [1, 2, 5, 6, 3, 4]);

        intSeq.insert([7, 8, 9], 5);
        assert(intSeq.toArray == [1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.insert([10, 11], 0);
        assert(intSeq.toArray == [10, 11, 1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.insert([12], 6);
        assert(intSeq.toArray == [10, 11, 1, 2, 5, 6, 12, 3, 7, 8, 9, 4]);

        intSeq.insert([13], 8);
        assert(intSeq.toArray == [10, 11, 1, 2, 5, 6, 12, 3, 13, 7, 8, 9, 4]);

        intSeq.insert([13, 14], 2);
        assert(intSeq.toArray == [10, 11, 13, 14, 1, 2, 5, 6, 12, 3, 13, 7, 8, 9, 4]);

        intSeq.insert([15], 13);
        assert(intSeq.toArray == [10, 11, 13, 14, 1, 2, 5, 6, 12, 3, 13, 7, 8, 15, 9, 4]);
    }
}

// test sequence removal
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.remove(0, 1);
        assert(intSeq.toArray == [2, 3, 4]);

        intSeq.remove(1, 2);
        assert(intSeq.toArray == [2, 4]);

        intSeq.remove(0, 1);
        assert(intSeq.toArray == [4]);

        intSeq.remove(0, 1);
        assert(intSeq.toArray == []);
    }

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([5, 6], 2);
        intSeq.insert([7, 8, 9], 5);
        intSeq.insert([10, 11], 0);
        intSeq.insert([12, 13], 2);
        assert(intSeq.toArray == [10, 11, 12, 13, 1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.remove(3, 4);
        assert(intSeq.toArray == [10, 11, 12, 1, 2, 5, 6, 3, 7, 8, 9, 4]);

        intSeq.remove(11, 12);
        assert(intSeq.toArray == [10, 11, 12, 1, 2, 5, 6, 3, 7, 8, 9]);

        intSeq.remove(2, 7);
        assert(intSeq.toArray == [10, 11, 3, 7, 8, 9]);

        intSeq.remove(2, 3);
        assert(intSeq.toArray == [10, 11, 7, 8, 9]);

        intSeq.remove(3, 5);
        assert(intSeq.toArray == [10, 11, 7]);

        intSeq.remove(0, 3);
        assert(intSeq.toArray == []);
    }
}

// test sequence replacement
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2, 3, 4];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.replace([5], 3, 4);
        assert(intSeq.toArray == [1, 2, 3, 5]);

        intSeq.replace([6, 7, 8], 0, 2);
        assert(intSeq.toArray == [6, 7, 8, 3, 5]);

        intSeq.replace([9, 10], 2, 4);
        assert(intSeq.toArray == [6, 7, 9, 10, 5]);
    }

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.replace([3, 4], 0, 2);
        assert(intSeq.toArray == [3, 4]);
    }
}

// test sequence iteration
unittest {
    alias IntSeq = Sequence!(int[]);

    {
        int[] intArray = [1, 2];
        IntSeq intSeq = new IntSeq(intArray);

        intSeq.insert([3, 4], 0);
        intSeq.insert([5, 6], 3);
        intSeq.insert([7], 6);
        assert(intSeq.toArray == [3, 4, 1, 5, 6, 2, 7]);

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

struct StageDesc {
    string name;
    string description;
}

template isStageDesc(alias T) {
    enum isStageDesc = __traits(isSame, StageDesc, typeof(T));
}

struct ProgressState(Stages...) if(allSatisfy!(isStageDesc, Stages)) {
public:
    mixin("enum Stage : int { " ~ _enumString(Stages) ~ " complete }");
    alias Stage this;
    enum nStages = (EnumMembers!Stage).length - 1;
    static immutable string[nStages] stageDescriptions = mixin(_createStageDescList(Stages));

    enum stepsPerStage = 5;

    alias Callback = void delegate(Stage stage, double stageFraction);

    this(Stage stage, double stageFraction) {
        this.stage = stage;
        completionFraction = (stage == complete) ? 1.0 : (stage + stageFraction) / nStages;
    }

    Stage stage;
    double completionFraction;

private:
    static string _enumString(T...)(T stageDescList) {
        string result;
        foreach(stageDesc; stageDescList) {
            result ~= stageDesc.name ~ ", ";
        }
        return result;
    }
    static string _createStageDescList(T...)(T stageDescList) {
        string result = "[ ";
        foreach(stageDesc; stageDescList) {
            result ~= "\"" ~ stageDesc.description ~ "\", ";
        }
        result ~= " ]";
        return result;
    }
}

template ProgressTask(Task)
    if(is(Task == U delegate(), U) ||
       (isPointer!Task && __traits(isSame, TemplateOf!(PointerTarget!Task), std.parallelism.Task)) ||
       __traits(isSame, TemplateOf!Task, std.parallelism.Task)) {
    struct ProgressTask {
        string name;

        static if(is(Task == U delegate(), U)) {
            this(string name, Task task) {
                this.name = name;
                this.task = std.parallelism.task!Task(task);
            }

            typeof(std.parallelism.task!Task(delegate U() {})) task;
        }
        else {
            this(string name, Task task) {
                this.name = name;
                this.task = task;
            }

            Task task;
        }
    }
}

alias DefaultProgressTask = ProgressTask!(void delegate());

auto progressTask(Task)(string name, Task task) {
    return ProgressTask!Task(name, task);
}

auto progressTaskCallback(ProgressState)() if(__traits(isSame, TemplateOf!ProgressState, .ProgressState)) {
    Tid callbackTid = thisTid;
    return delegate(ProgressState.Stage stage, double stageFraction) {
        send(callbackTid, ProgressState(stage, stageFraction));
    };
}

alias LoadState = ProgressState!(StageDesc("read", "Loading file"),
                                 StageDesc("resample", "Resampling"),
                                 StageDesc("computeOverview", "Computing overview"));
alias ComputeOnsetsState = ProgressState!(StageDesc("computeOnsets", "Computing onsets"));
alias NormalizeState = ProgressState!(StageDesc("normalize", "Normalizing"));

auto sliceMin(T)(T sourceData) if(isIterable!T && isNumeric!(typeof(sourceData[size_t.init]))) {
    alias BaseSampleType = typeof(sourceData[size_t.init]);
    static if(is(BaseSampleType == const(U), U)) {
        alias SampleType = U;
    }
    else {
        alias SampleType = BaseSampleType;
    }

    SampleType minSample = 1;
    foreach(s; sourceData) {
        if(s < minSample) minSample = s;
    }
    return minSample;
}

auto sliceMax(T)(T sourceData) if(isIterable!T && isNumeric!(typeof(sourceData[size_t.init]))) {
    alias BaseSampleType = typeof(sourceData[size_t.init]);
    static if(is(BaseSampleType == const(U), U)) {
        alias SampleType = U;
    }
    else {
        alias SampleType = BaseSampleType;
    }

    SampleType maxSample = -1;
    foreach(s; sourceData) {
        if(s > maxSample) maxSample = s;
    }
    return maxSample;
}

sample_t[] convertSampleRate(sample_t[] audioBuffer,
                             channels_t nChannels,
                             nframes_t oldSampleRate,
                             nframes_t newSampleRate,
                             LoadState.Callback progressCallback = null) {
    if(newSampleRate != oldSampleRate && newSampleRate > 0) {
        if(progressCallback) {
            progressCallback(LoadState.resample, 0);
        }

        // constant indicating the algorithm to use for sample rate conversion
        enum converter = SRC_SINC_MEDIUM_QUALITY; // TODO allow the user to specify this

        // libsamplerate requires floats
        static assert(is(sample_t == float));

        // allocate audio buffers for input/output
        ScopedArray!(float[]) dataIn = audioBuffer;
        float[] dataOut = new float[](audioBuffer.length);

        // compute the parameters for libsamplerate
        double srcRatio = (1.0 * newSampleRate) / oldSampleRate;
        if(!src_is_valid_ratio(srcRatio)) {
            throw new AudioError("Invalid sample rate requested: " ~ to!string(newSampleRate));
        }
        SRC_DATA srcData;
        srcData.data_in = dataIn.ptr;
        srcData.data_out = dataOut.ptr;
        auto immutable nframes = audioBuffer.length / nChannels;
        srcData.input_frames = cast(typeof(srcData.input_frames))(nframes);
        srcData.output_frames = cast(typeof(srcData.output_frames))(ceil(nframes * srcRatio));
        srcData.src_ratio = srcRatio;

        // compute the sample rate conversion
        int error = src_simple(&srcData, converter, cast(int)(nChannels));
        if(error) {
            throw new AudioError("Sample rate conversion failed: " ~ to!string(src_strerror(error)));
        }
        dataOut.length = cast(size_t)(srcData.output_frames_gen);

        if(progressCallback) {
            progressCallback(LoadState.resample, 1);
        }

        return dataOut;
    }

    return audioBuffer;
}

// stores the min/max sample values of a single-channel waveform at a specified binning size
class WaveformBinned {
public:
    @property nframes_t binSize() const { return _binSize; }
    @property const(sample_t[]) minValues() const { return _minValues; }
    @property const(sample_t[]) maxValues() const { return _maxValues; }

    WaveformBinned opSlice(size_t startIndex, size_t endIndex) {
        return new WaveformBinned(_binSize, _minValues[startIndex .. endIndex], _maxValues[startIndex .. endIndex]);
    }

    // compute this cache via raw audio data
    this(nframes_t binSize, sample_t[] audioBuffer, channels_t nChannels, channels_t channelIndex) {
        assert(binSize > 0);

        _binSize = binSize;
        auto immutable cacheLength = (audioBuffer.length / nChannels) / binSize;
        _minValues = new sample_t[](cacheLength);
        _maxValues = new sample_t[](cacheLength);

        for(auto i = 0, j = 0; i < audioBuffer.length && j < cacheLength; i += binSize * nChannels, ++j) {
            auto audioSlice = audioBuffer[i .. i + binSize * nChannels];
            _minValues[j] = 1;
            _maxValues[j] = -1;

            for(auto k = channelIndex; k < audioSlice.length; k += nChannels) {
                if(audioSlice[k] > _maxValues[j]) _maxValues[j] = audioSlice[k];
                if(audioSlice[k] < _minValues[j]) _minValues[j] = audioSlice[k];
            }
        }
    }

    // compute this cache via another cache
    this(nframes_t binSize, const(WaveformBinned) other) {
        assert(binSize > 0);

        auto binScale = binSize / other.binSize;
        _binSize = binSize;
        _minValues = new sample_t[](other.minValues.length / binScale);
        _maxValues = new sample_t[](other.maxValues.length / binScale);

        immutable size_t srcCount = min(other.minValues.length, other.maxValues.length);
        immutable size_t destCount = srcCount / binScale;
        for(auto i = 0, j = 0; i < srcCount && j < destCount; i += binScale, ++j) {
            for(auto k = 0; k < binScale; ++k) {
                _minValues[j] = 1;
                _maxValues[j] = -1;
                if(other.minValues[i + k] < _minValues[j]) {
                    _minValues[j] = other.minValues[i + k];
                }
                if(other.maxValues[i + k] > _maxValues[j]) {
                    _maxValues[j] = other.maxValues[i + k];
                }
            }
        }
    }

    // for initializing this cache from a slice of a previously computed cache
    this(nframes_t binSize, sample_t[] minValues, sample_t[] maxValues) {
        _binSize = binSize;
        _minValues = minValues;
        _maxValues = maxValues;
    }

private:
    nframes_t _binSize;
    sample_t[] _minValues;
    sample_t[] _maxValues;
}

class WaveformCache {
public:
    static immutable nframes_t[] cacheBinSizes = [10, 100];
    static assert(cacheBinSizes.length > 0);

    static Nullable!size_t getCacheIndex(nframes_t binSize) {
        nframes_t binSizeMatch;
        Nullable!size_t cacheIndex;
        foreach(i, s; cacheBinSizes) {
            if(s <= binSize && binSize % s == 0) {
                cacheIndex = i;
                binSizeMatch = s;
            }
            else {
                break;
            }
        }
        return cacheIndex;
    }

    this(sample_t[] audioBuffer, channels_t nChannels) {
        // initialize the cache
        _waveformBinnedChannels = null;
        _waveformBinnedChannels.reserve(nChannels);
        for(auto c = 0; c < nChannels; ++c) {
            WaveformBinned[] channelsBinned;
            channelsBinned.reserve(cacheBinSizes.length);

            // compute the first cache from the raw audio data
            channelsBinned ~= new WaveformBinned(cacheBinSizes[0], audioBuffer, nChannels, c);

            // compute the subsequent caches from previously computed caches
            foreach(binSize; cacheBinSizes[1 .. $]) {
                channelsBinned ~= new WaveformBinned(binSize, channelsBinned[$ - 1]);
            }
            _waveformBinnedChannels ~= channelsBinned;
        }
    }

    WaveformCache opSlice(size_t startIndex, size_t endIndex) {
        WaveformBinned[][] result;
        result.reserve(_waveformBinnedChannels.length);
        foreach(channelsBinned; _waveformBinnedChannels) {
            WaveformBinned[] resultChannelsBinned;
            resultChannelsBinned.reserve(channelsBinned.length);
            foreach(waveformBinned; channelsBinned) {
                resultChannelsBinned ~= waveformBinned[startIndex / waveformBinned.binSize ..
                                                       endIndex / waveformBinned.binSize];
            }
            result ~= resultChannelsBinned;
        }
        return new WaveformCache(result);
    }

    const(WaveformBinned) getWaveformBinned(channels_t channelIndex, size_t cacheIndex) const {
        return _waveformBinnedChannels[channelIndex][cacheIndex];
    }

private:
    this(WaveformBinned[][] waveformBinnedChannels) {
        _waveformBinnedChannels = waveformBinnedChannels;
    }

    WaveformBinned[][] _waveformBinnedChannels; // indexed as [channel][waveformBinned]
}

struct AudioSegment {
    this(sample_t[] audioBuffer, channels_t nChannels) {
        this.audioBuffer = audioBuffer;
        this.nChannels = nChannels;
        waveformCache = new WaveformCache(audioBuffer, nChannels);
    }

    this(sample_t[] audioBuffer, channels_t nChannels, WaveformCache waveformCache) {
        this.audioBuffer = audioBuffer;
        this.nChannels = nChannels;
        this.waveformCache = waveformCache;
    }

    @property size_t length() const @nogc nothrow {
        return audioBuffer.length;
    }

    alias opDollar = length;

    sample_t opIndex(size_t index) const @nogc nothrow {
        return audioBuffer[index];
    }

    AudioSegment opSlice(size_t startIndex, size_t endIndex) {
        return AudioSegment(audioBuffer[startIndex .. endIndex],
                            nChannels,
                            waveformCache[startIndex / nChannels .. endIndex / nChannels]);
    }

    sample_t[] audioBuffer;
    channels_t nChannels;
    WaveformCache waveformCache;
}

class AudioSequence {
public:
    this(AudioSegment originalBuffer, nframes_t sampleRate, channels_t nChannels, string name) {
        sequence = new Sequence!(AudioSegment)(originalBuffer);

        _sampleRate = sampleRate;
        _nChannels = nChannels;
        _name = name;
    }

    // create a sequence from a file
    static AudioSequence fromFile(string fileName,
                                  nframes_t sampleRate,
                                  LoadState.Callback progressCallback = null) {
        SNDFILE* infile;
        SF_INFO sfinfo;

        if(progressCallback) {
            progressCallback(LoadState.read, 0);
        }

        // attempt to open the given file
        infile = sf_open(fileName.toStringz(), SFM_READ, &sfinfo);
        if(!infile) {
            progressCallback(LoadState.complete, 0);
            return null;
        }

        // close the file when leaving this scope
        scope(exit) sf_close(infile);

        // allocate contiguous audio buffer
        sample_t[] audioBuffer = new sample_t[](cast(size_t)(sfinfo.frames * sfinfo.channels));

        // read the file into the audio buffer
        sf_count_t readTotal;
        sf_count_t readCount;
        do {
            sf_count_t readRequest = cast(sf_count_t)(audioBuffer.length >= LoadState.stepsPerStage ?
                                                      audioBuffer.length / LoadState.stepsPerStage :
                                                      audioBuffer.length);
            readRequest -= readRequest % sfinfo.channels;

            static if(is(sample_t == float)) {
                readCount = sf_read_float(infile, audioBuffer.ptr + readTotal, readRequest);
            }
            else if(is(sample_t == double)) {
                readCount = sf_read_double(infile, audioBuffer.ptr + readTotal, readRequest);
            }
            else {
                static assert(0);
            }

            readTotal += readCount;

            if(progressCallback) {
                progressCallback(LoadState.read, cast(double)(readTotal) / cast(double)(audioBuffer.length));
            }
        }
        while(readCount && readTotal < audioBuffer.length);

        immutable nframes_t originalSampleRate = cast(nframes_t)(sfinfo.samplerate);
        immutable channels_t nChannels = cast(channels_t)(sfinfo.channels);

        // resample, if necessary
        if(sampleRate != originalSampleRate) {
            audioBuffer = convertSampleRate(audioBuffer,
                                            nChannels,
                                            originalSampleRate,
                                            sampleRate,
                                            progressCallback);
        }

        // construct the region
        if(progressCallback) {
            progressCallback(LoadState.computeOverview, 0);
        }
        auto newSequence = new AudioSequence(AudioSegment(audioBuffer, nChannels),
                                             sampleRate,
                                             nChannels,
                                             baseName(stripExtension(fileName)));

        if(progressCallback) {
            progressCallback(LoadState.complete, 1.0);
        }

        return newSequence;
    }

    Sequence!(AudioSegment) sequence;
    alias sequence this;
    alias PieceTable = Sequence!(AudioSegment).PieceTable;

    @property nframes_t nframes() { return cast(nframes_t)(sequence.length / nChannels); }
    @property nframes_t sampleRate() const { return _sampleRate; }
    @property channels_t nChannels() const { return _nChannels; }
    @property string name() const { return _name; }

private:
    nframes_t _sampleRate;
    channels_t _nChannels;
    string _name;
}

struct Onset {
    nframes_t onsetFrame;
    AudioSequence.PieceTable leftSource;
    AudioSequence.PieceTable rightSource;
}

alias OnsetSequence = Sequence!(Onset[]);

class Region {
public:
    this(AudioSequence audioSeq, string name) {
        _sampleRate = audioSeq.sampleRate;
        _nChannels = audioSeq.nChannels;
        _name = name;

        _audioSeq = audioSeq;
        _sliceStartFrame = 0;
        _sliceEndFrame = audioSeq.nframes;
        _audioSlice = audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
    }
    this(AudioSequence audioSeq) {
        this(audioSeq, audioSeq.name);
    }

    struct OnsetParams {
        enum onsetThresholdMin = 0.0;
        enum onsetThresholdMax = 1.0;
        sample_t onsetThreshold = 0.3;

        enum silenceThresholdMin = -90;
        enum silenceThresholdMax = 0.0;
        sample_t silenceThreshold = -90;
    }

    // returns an array of frames at which an onset occurs, with frames given locally for this region
    // all channels are summed before computing onsets
    Onset[] getOnsetsLinkedChannels(ref const(OnsetParams) params,
                                    ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          _audioSlice,
                          sampleRate,
                          nChannels,
                          0,
                          true,
                          progressCallback);
    }

    // returns an array of frames at which an onset occurs, with frames given locally for this region
    Onset[] getOnsetsSingleChannel(ref const(OnsetParams) params,
                                   channels_t channelIndex,
                                   ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          _audioSlice,
                          sampleRate,
                          nChannels,
                          channelIndex,
                          false,
                          progressCallback);
    }

    // returns an array of frames at which an onset occurs in a given piece table, with frames given locally
    // all channels are summed before computing onsets
    static Onset[] getOnsetsLinkedChannels(ref const(OnsetParams) params,
                                           AudioSequence.PieceTable pieceTable,
                                           nframes_t sampleRate,
                                           channels_t nChannels,
                                           ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          pieceTable,
                          sampleRate,
                          nChannels,
                          0,
                          true,
                          progressCallback);
    }

    // returns an array of frames at which an onset occurs in a given piece table, with frames given locally
    static Onset[] getOnsetsSingleChannel(ref const(OnsetParams) params,
                                          AudioSequence.PieceTable pieceTable,
                                          nframes_t sampleRate,
                                          channels_t nChannels,
                                          channels_t channelIndex,
                                          ComputeOnsetsState.Callback progressCallback = null) {
        return _getOnsets(params,
                          pieceTable,
                          sampleRate,
                          nChannels,
                          channelIndex,
                          false,
                          progressCallback);
    }

    // stretches the subregion between the given local indices according to stretchRatio
    // returns the local end frame of the stretch
    nframes_t stretchSubregion(nframes_t localStartFrame, nframes_t localEndFrame, double stretchRatio) {
        immutable channels_t nChannels = this.nChannels;

        uint subregionLength = cast(uint)(localEndFrame - localStartFrame);
        ScopedArray!(float[][]) subregionChannels = new float[][](nChannels);
        ScopedArray!(float*[]) subregionPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] subregion = new float[](subregionLength);
            subregionChannels[i] = subregion;
            subregionPtr[i] = subregion.ptr;
        }

        foreach(channels_t channelIndex, channel; subregionChannels) {
            foreach(i, ref sample; channel) {
                sample = _audioSlice[(localStartFrame + i) * this.nChannels + channelIndex];
            }
        }

        uint subregionOutputLength = cast(uint)(subregionLength * stretchRatio);
        ScopedArray!(float[][]) subregionOutputChannels = new float[][](nChannels);
        ScopedArray!(float*[]) subregionOutputPtr = new float*[](nChannels);
        for(auto i = 0; i < nChannels; ++i) {
            float[] subregionOutput = new float[](subregionOutputLength);
            subregionOutputChannels[i] = subregionOutput;
            subregionOutputPtr[i] = subregionOutput.ptr;
        }

        RubberBandState rState = rubberband_new(sampleRate,
                                                nChannels,
                                                RubberBandOption.RubberBandOptionProcessOffline,
                                                stretchRatio,
                                                1.0);
        rubberband_set_max_process_size(rState, subregionLength);
        rubberband_set_expected_input_duration(rState, subregionLength);
        rubberband_study(rState, subregionPtr.ptr, subregionLength, 1);
        rubberband_process(rState, subregionPtr.ptr, subregionLength, 1);
        while(rubberband_available(rState) < subregionOutputLength) {}
        rubberband_retrieve(rState, subregionOutputPtr.ptr, subregionOutputLength);
        rubberband_delete(rState);

        sample_t[] subregionOutput = new sample_t[](subregionOutputLength * nChannels);
        foreach(channels_t channelIndex, channel; subregionOutputChannels) {
            foreach(i, sample; channel) {
                subregionOutput[i * nChannels + channelIndex] = sample;
            }
        }

        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(subregionOutput, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _resizeSlice(prevNFrames, newNFrames);

        return localStartFrame + subregionOutputLength;
    }

    // stretch the audio such that the frame at localSrcFrame becomes the frame at localDestFrame
    // if linkChannels is true, perform the stretch for all channels simultaneously, ignoring channelIndex
    void stretchThreePoint(nframes_t localStartFrame,
                           nframes_t localSrcFrame,
                           nframes_t localDestFrame,
                           nframes_t localEndFrame,
                           bool linkChannels = false,
                           channels_t singleChannelIndex = 0,
                           AudioSequence.PieceTable leftSource = AudioSequence.PieceTable.init,
                           AudioSequence.PieceTable rightSource = AudioSequence.PieceTable.init) {
        immutable channels_t stretchNChannels = linkChannels ? nChannels : 1;
        immutable bool useSource = leftSource && rightSource;

        auto immutable removeStartIndex = clamp((_sliceStartFrame + localStartFrame) * nChannels,
                                                0,
                                                _audioSeq.length);
        auto immutable removeEndIndex = clamp((_sliceStartFrame + localEndFrame) * nChannels,
                                              removeStartIndex,
                                              _audioSeq.length);

        immutable double firstScaleFactor = (localSrcFrame > localStartFrame) ?
            (cast(double)(localDestFrame - localStartFrame) /
             cast(double)(useSource ? leftSource.length / nChannels : localSrcFrame - localStartFrame)) : 0;
        immutable double secondScaleFactor = (localEndFrame > localSrcFrame) ?
            (cast(double)(localEndFrame - localDestFrame) /
             cast(double)(useSource ? rightSource.length / nChannels : localEndFrame - localSrcFrame)) : 0;

        if(useSource) {
            localStartFrame = 0;
            localSrcFrame = (localStartFrame < localSrcFrame) ? localSrcFrame - localStartFrame : 0;
            localDestFrame = (localStartFrame < localDestFrame) ? localDestFrame - localStartFrame : 0;
            localEndFrame = (localStartFrame < localEndFrame) ? localEndFrame - localStartFrame : 0;
        }

        uint firstHalfLength = cast(uint)(useSource ?
                                          leftSource.length / nChannels :
                                          localSrcFrame - localStartFrame);
        uint secondHalfLength = cast(uint)(useSource ?
                                           rightSource.length / nChannels :
                                           localEndFrame - localSrcFrame);
        ScopedArray!(float[][]) firstHalfChannels = new float[][](stretchNChannels);
        ScopedArray!(float[][]) secondHalfChannels = new float[][](stretchNChannels);
        ScopedArray!(float*[]) firstHalfPtr = new float*[](stretchNChannels);
        ScopedArray!(float*[]) secondHalfPtr = new float*[](stretchNChannels);
        for(auto i = 0; i < stretchNChannels; ++i) {
            float[] firstHalf = new float[](firstHalfLength);
            float[] secondHalf = new float[](secondHalfLength);
            firstHalfChannels[i] = firstHalf;
            secondHalfChannels[i] = secondHalf;
            firstHalfPtr[i] = firstHalf.ptr;
            secondHalfPtr[i] = secondHalf.ptr;
        }

        if(useSource) {
            if(linkChannels) {
                foreach(channels_t channelIndex, channel; firstHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = leftSource[i * nChannels + channelIndex];
                    }
                }
                foreach(channels_t channelIndex, channel; secondHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = rightSource[i * nChannels + channelIndex];
                    }
                }
            }
            else {
                foreach(i, ref sample; firstHalfChannels[0]) {
                    sample = leftSource[i * nChannels + singleChannelIndex];
                }
                foreach(i, ref sample; secondHalfChannels[0]) {
                    sample = rightSource[i * nChannels + singleChannelIndex];
                }
            }
        }
        else {
            if(linkChannels) {
                foreach(channels_t channelIndex, channel; firstHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = _audioSlice[(localStartFrame + i) * nChannels + channelIndex];
                    }
                }
                foreach(channels_t channelIndex, channel; secondHalfChannels) {
                    foreach(i, ref sample; channel) {
                        sample = _audioSlice[(localSrcFrame + i) * nChannels + channelIndex];
                    }
                }
            }
            else {
                foreach(i, ref sample; firstHalfChannels[0]) {
                    sample = _audioSlice[(localStartFrame + i) * nChannels + singleChannelIndex];
                }
                foreach(i, ref sample; secondHalfChannels[0]) {
                    sample = _audioSlice[(localSrcFrame + i) * nChannels + singleChannelIndex];
                }
            }
        }

        uint firstHalfOutputLength = cast(uint)(firstHalfLength * firstScaleFactor);
        uint secondHalfOutputLength = cast(uint)(secondHalfLength * secondScaleFactor);
        ScopedArray!(float[][]) firstHalfOutputChannels = new float[][](stretchNChannels);
        ScopedArray!(float[][]) secondHalfOutputChannels = new float[][](stretchNChannels);
        ScopedArray!(float*[]) firstHalfOutputPtr = new float*[](stretchNChannels);
        ScopedArray!(float*[]) secondHalfOutputPtr = new float*[](stretchNChannels);
        for(auto i = 0; i < stretchNChannels; ++i) {
            float[] firstHalfOutput = new float[](firstHalfOutputLength);
            float[] secondHalfOutput = new float[](secondHalfOutputLength);
            firstHalfOutputChannels[i] = firstHalfOutput;
            secondHalfOutputChannels[i] = secondHalfOutput;
            firstHalfOutputPtr[i] = firstHalfOutput.ptr;
            secondHalfOutputPtr[i] = secondHalfOutput.ptr;
        }

        if(firstScaleFactor > 0) {
            RubberBandState rState = rubberband_new(sampleRate,
                                                    stretchNChannels,
                                                    RubberBandOption.RubberBandOptionProcessOffline,
                                                    firstScaleFactor,
                                                    1.0);
            rubberband_set_max_process_size(rState, firstHalfLength);
            rubberband_set_expected_input_duration(rState, firstHalfLength);
            rubberband_study(rState, firstHalfPtr.ptr, firstHalfLength, 1);
            rubberband_process(rState, firstHalfPtr.ptr, firstHalfLength, 1);
            while(rubberband_available(rState) < firstHalfOutputLength) {}
            rubberband_retrieve(rState, firstHalfOutputPtr.ptr, firstHalfOutputLength);
            rubberband_delete(rState);
        }

        if(secondScaleFactor > 0) {
            RubberBandState rState = rubberband_new(sampleRate,
                                                    stretchNChannels,
                                                    RubberBandOption.RubberBandOptionProcessOffline,
                                                    secondScaleFactor,
                                                    1.0);
            rubberband_set_max_process_size(rState, secondHalfLength);
            rubberband_set_expected_input_duration(rState, secondHalfLength);
            rubberband_study(rState, secondHalfPtr.ptr, secondHalfLength, 1);
            rubberband_process(rState, secondHalfPtr.ptr, secondHalfLength, 1);
            while(rubberband_available(rState) < secondHalfOutputLength) {}
            rubberband_retrieve(rState, secondHalfOutputPtr.ptr, secondHalfOutputLength);
            rubberband_delete(rState);
        }

        sample_t[] outputBuffer = new sample_t[]((firstHalfOutputLength + secondHalfOutputLength) * nChannels);
        if(linkChannels) {
            foreach(channels_t channelIndex, channel; firstHalfOutputChannels) {
                foreach(i, sample; channel) {
                    outputBuffer[i * nChannels + channelIndex] = sample;
                }
            }
            auto secondHalfOffset = firstHalfOutputLength * nChannels;
            foreach(channels_t channelIndex, channel; secondHalfOutputChannels) {
                foreach(i, sample; channel) {
                    outputBuffer[secondHalfOffset + i * nChannels + channelIndex] = sample;
                }
            }
        }
        else {
            auto firstHalfSourceOffset = removeStartIndex;
            foreach(i, sample; firstHalfOutputChannels[0]) {
                for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
                    if(channelIndex == singleChannelIndex) {
                        outputBuffer[i * nChannels + channelIndex] = sample;
                    }
                    else {
                        outputBuffer[i * nChannels + channelIndex] =
                            _audioSeq[firstHalfSourceOffset + i * nChannels + channelIndex];
                    }
                }
            }
            auto secondHalfOutputOffset = firstHalfOutputLength * nChannels;
            auto secondHalfSourceOffset = firstHalfSourceOffset + secondHalfOutputOffset;
            foreach(i, sample; secondHalfOutputChannels[0]) {
                for(channels_t channelIndex = 0; channelIndex < nChannels; ++channelIndex) {
                    if(channelIndex == singleChannelIndex) {
                        outputBuffer[secondHalfOutputOffset + i * nChannels + channelIndex] = sample;
                    }
                    else {
                        outputBuffer[secondHalfOutputOffset + i * nChannels + channelIndex] =
                            _audioSeq[secondHalfSourceOffset + i * nChannels + channelIndex];
                    }
                }
            }
        }

        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(outputBuffer, nChannels), removeStartIndex, removeEndIndex);
        auto immutable newNFrames = _audioSeq.nframes;
        _resizeSlice(prevNFrames, newNFrames);
    }

    // normalize subregion from startFrame to endFrame to the given maximum gain, in dBFS
    void normalize(nframes_t localStartFrame,
                   nframes_t localEndFrame,
                   sample_t maxGain = 0.1f,
                   NormalizeState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(NormalizeState.normalize, 0);
        }

        sample_t[] audioBuffer = _audioSlice[localStartFrame * nChannels .. localEndFrame * nChannels].toArray;
        _normalizeBuffer(audioBuffer, maxGain);

        // write the normalized selection to the audio sequence
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels),
                          (_sliceStartFrame + localStartFrame) * nChannels,
                          (_sliceStartFrame + localEndFrame) * nChannels);
        auto immutable newNFrames = _audioSeq.nframes;
        _resizeSlice(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(NormalizeState.complete, 1);
        }
    }

    // normalize entire region (including nonvisible pieces) to the given maximum gain, in dBFS
    void normalize(sample_t maxGain = -0.1f, NormalizeState.Callback progressCallback = null) {
        if(progressCallback !is null) {
            progressCallback(NormalizeState.normalize, 0);
        }

        sample_t[] audioBuffer = _audioSeq[].toArray;
        _normalizeBuffer(audioBuffer, maxGain);

        // write the normalized selection to the audio sequence
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.replace(AudioSegment(audioBuffer, nChannels), 0, _audioSeq.length);
        auto immutable newNFrames = _audioSeq.nframes;
        _resizeSlice(prevNFrames, newNFrames);

        if(progressCallback !is null) {
            progressCallback(NormalizeState.complete, 1);
        }
    }

    sample_t getMin(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) {
        auto immutable cacheSize = WaveformCache.cacheBinSizes[cacheIndex];
        foreach(piece; _audioSlice.table) {
            auto immutable logicalStart = piece.logicalOffset / nChannels;
            auto immutable logicalEnd = (piece.logicalOffset + piece.length) / nChannels;
            if(sampleOffset * binSize >= logicalStart && sampleOffset * binSize < logicalEnd) {
                return sliceMin(piece.buffer.waveformCache.getWaveformBinned(channelIndex, cacheIndex).minValues
                                [(sampleOffset * binSize - logicalStart) / cacheSize..
                                 ((sampleOffset + 1) * binSize - logicalStart) / cacheSize]);
            }
        }
        return 0;
    }
    sample_t getMax(channels_t channelIndex,
                    size_t cacheIndex,
                    nframes_t binSize,
                    nframes_t sampleOffset) {
        auto immutable cacheSize = WaveformCache.cacheBinSizes[cacheIndex];
        foreach(piece; _audioSlice.table) {
            auto immutable logicalStart = piece.logicalOffset / nChannels;
            auto immutable logicalEnd = (piece.logicalOffset + piece.length) / nChannels;
            if(sampleOffset * binSize >= logicalStart && sampleOffset * binSize < logicalEnd) {
                return sliceMax(piece.buffer.waveformCache.getWaveformBinned(channelIndex, cacheIndex).maxValues
                                [(sampleOffset * binSize - logicalStart) / cacheSize ..
                                 ((sampleOffset + 1) * binSize - logicalStart) / cacheSize]);
            }
        }
        return 0;
    }

    // returns the sample value at a given channel and frame, globally indexed
    sample_t getSampleGlobal(channels_t channelIndex, nframes_t frame) @nogc nothrow {
        return frame >= offset ?
            (frame < offset + nframes ? _audioSlice[(frame - offset) * nChannels + channelIndex] : 0) : 0;
    }

    // returns a slice of the internal audio sequence, using local indexes as input
    AudioSequence.PieceTable getSliceLocal(nframes_t localFrameStart, nframes_t localFrameEnd) {
        return _audioSlice[localFrameStart * nChannels .. localFrameEnd * nChannels];
    }

    // insert a subregion at a local offset; does nothing if the offset is not within this region
    void insertLocal(AudioSequence.PieceTable insertSlice, nframes_t localFrameOffset) {
        if(localFrameOffset >= 0 && localFrameOffset < nframes) {
            auto immutable prevNFrames = _audioSeq.nframes;
            _audioSeq.insert(insertSlice, (_sliceStartFrame + localFrameOffset) * nChannels);
            auto immutable newNFrames = _audioSeq.nframes;
            _resizeSlice(prevNFrames, newNFrames);
        }
    }

    // removes a subregion according to the given local offsets
    // does nothing if the offsets are not within this region
    void removeLocal(nframes_t localFrameStart, nframes_t localFrameEnd) {
        if(localFrameStart < localFrameEnd &&
           localFrameStart >= 0 && localFrameStart < nframes &&
           localFrameEnd >= 0 && localFrameEnd < nframes) {
            auto immutable prevNFrames = _audioSeq.nframes;
            _audioSeq.remove((_sliceStartFrame + localFrameStart) * nChannels,
                             (_sliceStartFrame + localFrameEnd) * nChannels);
            auto immutable newNFrames = _audioSeq.nframes;
            _resizeSlice(prevNFrames, newNFrames);
        }
    }

    // undo the last edit operation
    void undoEdit() {
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.undo();
        auto immutable newNFrames = _audioSeq.nframes;
        _resizeSlice(prevNFrames, newNFrames);
    }

    // redo the last edit operation
    void redoEdit() {
        auto immutable prevNFrames = _audioSeq.nframes;
        _audioSeq.redo();
        auto immutable newNFrames = _audioSeq.nframes;
        _resizeSlice(prevNFrames, newNFrames);
    }

    // modifies (within limits) the start of the region, in global frames
    void shrinkStart(nframes_t newStartFrameGlobal) {
        if(newStartFrameGlobal < offset) {
            auto immutable delta = offset - newStartFrameGlobal;
            if(delta < _sliceStartFrame) {
                _offset -= delta;
                _sliceStartFrame -= delta;
            }
            else if(offset >= _sliceStartFrame) {
                _offset -= _sliceStartFrame;
                _sliceStartFrame = 0;
            }
            else {
                return;
            }
        }
        else if(newStartFrameGlobal > offset) {
            auto immutable delta = newStartFrameGlobal - offset;
            if(_sliceStartFrame + delta < _sliceEndFrame) {
                _offset += delta;
                _sliceStartFrame += delta;
            }
            else {
                _offset += _sliceEndFrame - _sliceStartFrame;
                _sliceStartFrame = _sliceEndFrame;
            }
        }
        else {
            return;
        }

        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
    }
    // modifies (within limits) the end of the region, in global frames
    void shrinkEnd(nframes_t newEndFrameGlobal) {
        auto immutable endFrameGlobal = _offset + cast(nframes_t)(_audioSlice.length / nChannels);
        if(newEndFrameGlobal < endFrameGlobal) {
            auto immutable delta = endFrameGlobal - newEndFrameGlobal;
            if(_sliceEndFrame > _sliceStartFrame + delta) {
                _sliceEndFrame -= delta;
            }
            else {
                _sliceEndFrame = _sliceStartFrame;
            }
        }
        else if(newEndFrameGlobal > endFrameGlobal) {
            auto immutable delta = newEndFrameGlobal - endFrameGlobal;
            if(_sliceEndFrame + delta <= _audioSeq.nframes) {
                _sliceEndFrame += delta;
                if(resizeDelegate !is null) {
                    resizeDelegate(offset + nframes);
                }
            }
            else {
                _sliceEndFrame = _audioSeq.nframes;
            }
        }
        else {
            return;
        }

        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
    }

    @property nframes_t sliceStartFrame() const { return _sliceStartFrame; }
    @property nframes_t sliceStartFrame(nframes_t newSliceStartFrame) {
        _sliceStartFrame = min(newSliceStartFrame, _audioSeq.nframes - 1);
        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
        return _sliceStartFrame;
    }
    @property nframes_t sliceEndFrame() const { return _sliceEndFrame; }
    @property nframes_t sliceEndFrame(nframes_t newSliceEndFrame) {
        _sliceEndFrame = min(newSliceEndFrame, _audioSeq.nframes);
        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
        if(resizeDelegate !is null) {
            resizeDelegate(offset + nframes);
        }        
        return _sliceEndFrame;
    }

    // number of frames in the audio data, where 1 frame contains 1 sample for each channel
    @property nframes_t nframes() const @nogc nothrow { return _sliceEndFrame - _sliceStartFrame; }

    @property nframes_t sampleRate() const @nogc nothrow { return _sampleRate; }
    @property channels_t nChannels() const @nogc nothrow { return _nChannels; }
    @property nframes_t offset() const @nogc nothrow { return _offset; }
    @property nframes_t offset(nframes_t newOffset) { return (_offset = newOffset); }
    @property bool mute() const @nogc nothrow { return _mute; }
    @property bool mute(bool enable) { return (_mute = enable); }

    @property string name() const { return _name; }
    @property string name(string newName) { return (_name = newName); }

package:
    ResizeDelegate resizeDelegate;

private:
    // normalize an audio buffer; note that this does not send a progress completion message
    static void _normalizeBuffer(sample_t[] audioBuffer,
                                 sample_t maxGain = 0.1f,
                                 NormalizeState.Callback progressCallback = null) {
        // calculate the maximum sample
        sample_t minSample = 1;
        sample_t maxSample = -1;
        foreach(s; audioBuffer) {
            if(s > maxSample) maxSample = s;
            if(s < minSample) minSample = s;
        }
        maxSample = max(abs(minSample), abs(maxSample));

        // normalize the selection
        sample_t sampleFactor =  pow(10, (maxGain > 0 ? 0 : maxGain) / 20) / maxSample;
        foreach(i, ref s; audioBuffer) {
            s *= sampleFactor;

            if(progressCallback !is null && i % (audioBuffer.length / NormalizeState.stepsPerStage) == 0) {
                progressCallback(NormalizeState.normalize, cast(double)(i) / cast(double)(audioBuffer.length));
            }
        }
    }

    // channelIndex is ignored when linkChannels == true
    static Onset[] _getOnsets(ref const(OnsetParams) params,
                              AudioSequence.PieceTable pieceTable,
                              nframes_t sampleRate,
                              channels_t nChannels,
                              channels_t channelIndex,
                              bool linkChannels,
                              ComputeOnsetsState.Callback progressCallback = null) {
        immutable nframes_t nframes = cast(nframes_t)(pieceTable.length / nChannels);
        immutable nframes_t framesPerProgressStep =
            (nframes / ComputeOnsetsState.stepsPerStage) * (linkChannels ? 1 : nChannels);
        nframes_t progressStep;

        immutable uint windowSize = 512;
        immutable uint hopSize = 256;
        string onsetMethod = "default";

        auto onsetThreshold = clamp(params.onsetThreshold,
                                    OnsetParams.onsetThresholdMin,
                                    OnsetParams.onsetThresholdMax);
        auto silenceThreshold = clamp(params.silenceThreshold,
                                      OnsetParams.silenceThresholdMin,
                                      OnsetParams.silenceThresholdMax);

        fvec_t* onsetBuffer = new_fvec(1);
        fvec_t* hopBuffer = new_fvec(hopSize);

        auto onsetsApp = appender!(Onset[]);
        aubio_onset_t* o = new_aubio_onset(cast(char*)(onsetMethod.toStringz()), windowSize, hopSize, sampleRate);
        aubio_onset_set_threshold(o, onsetThreshold);
        aubio_onset_set_silence(o, silenceThreshold);
        for(nframes_t samplesRead = 0; samplesRead < nframes; samplesRead += hopSize) {
            uint hopSizeLimit;
            if(((hopSize - 1 + samplesRead) * nChannels + channelIndex) > pieceTable.length) {
                hopSizeLimit = nframes - samplesRead;
                fvec_zeros(hopBuffer);
            }
            else {
                hopSizeLimit = hopSize;
            }

            if(linkChannels) {
                for(auto sample = 0; sample < hopSizeLimit; ++sample) {
                    hopBuffer.data[sample] = 0;
                    for(channels_t i = 0; i < nChannels; ++i) {
                        hopBuffer.data[sample] += pieceTable[(sample + samplesRead) * nChannels + i];
                    }
                }
            }
            else {
                for(auto sample = 0; sample < hopSizeLimit; ++sample) {
                    hopBuffer.data[sample] = pieceTable[(sample + samplesRead) * nChannels + channelIndex];
                }
            }

            aubio_onset_do(o, hopBuffer, onsetBuffer);
            if(onsetBuffer.data[0] != 0) {
                auto lastOnset = aubio_onset_get_last(o);
                if(lastOnset != 0) {
                    if(onsetsApp.data.length > 0) {
                        // compute the right source for the previous onset
                        onsetsApp.data[$ - 1].rightSource =
                            pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels .. lastOnset * nChannels];
                        // append the current onset and its left source
                        onsetsApp.put(Onset(lastOnset, pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels ..
                                                                  lastOnset * nChannels]));
                    }
                    else {
                        // append the leftmost onset
                        onsetsApp.put(Onset(lastOnset, pieceTable[0 .. lastOnset * nChannels]));
                    }
                }
            }
            // compute the right source for the last onset
            if(onsetsApp.data.length > 0) {
                onsetsApp.data[$ - 1].rightSource =
                    pieceTable[onsetsApp.data[$ - 1].onsetFrame * nChannels .. pieceTable.length];
            }

            if((samplesRead > progressStep) && progressCallback) {
                progressStep = samplesRead + framesPerProgressStep;
                if(linkChannels) {
                    progressCallback(ComputeOnsetsState.computeOnsets,
                                     cast(double)(samplesRead) / cast(double)(nframes));
                }
                else {
                    progressCallback(ComputeOnsetsState.computeOnsets,
                                     cast(double)(samplesRead + nframes * channelIndex) /
                                     cast(double)(nframes * nChannels));
                }
            }
        }
        del_aubio_onset(o);

        del_fvec(onsetBuffer);
        del_fvec(hopBuffer);
        aubio_cleanup();

        return onsetsApp.data;
    }

    // arguments are the total number of frames in the audio sequence before/after a modification
    // adjusts the ending frame accordingly
    void _resizeSlice(nframes_t prevNFrames, nframes_t newNFrames) {
        if(newNFrames > prevNFrames) {
            _sliceEndFrame += (newNFrames - prevNFrames);
            if(resizeDelegate !is null) {
                resizeDelegate(offset + nframes);
            }
        }
        else if(newNFrames < prevNFrames) {
            _sliceEndFrame = (_sliceEndFrame > prevNFrames - newNFrames) ?
                _sliceEndFrame - (prevNFrames - newNFrames) : _sliceStartFrame;
        }

        _audioSlice = _audioSeq[_sliceStartFrame * nChannels .. _sliceEndFrame * nChannels];
    }

    nframes_t _sampleRate; // sample rate of the audio data
    channels_t _nChannels; // number of channels in the audio data

    AudioSequence _audioSeq; // sequence of interleaved audio data, for all channels
    nframes_t _sliceStartFrame; // start frame for this region, relative to the start of the sequence
    nframes_t _sliceEndFrame; // end frame for this region, relative to the end of the sequence

    // current slice of the audio sequence, based on _sliceStartFrame and _sliceEndFrame
    AudioSequence.PieceTable _audioSlice;

    nframes_t _offset; // the offset, in frames, for the start of this region
    bool _mute; // flag indicating whether to mute all audio in this region during playback
    string _name; // name for this region
}

class Track {
public:
    void addRegion(Region region) {
        region.resizeDelegate = resizeDelegate;
        _regions ~= region;
        if(resizeDelegate !is null) {
            resizeDelegate(region.offset + region.nframes);
        }
    }

    const(Region[]) regions() const { return _regions; }

    @property bool mute() const @nogc nothrow { return _mute; }
    @property bool mute(bool enable) { return (_mute = enable); }
    @property bool solo() const @nogc nothrow { return _solo; }
    @property bool solo(bool enable) { return (_solo = enable); }

package:
    void mixStereoInterleaved(nframes_t offset,
                              nframes_t bufNFrames,
                              channels_t nChannels,
                              sample_t* mixBuf) @nogc nothrow {
        if(!_mute) {
            for(auto i = 0, j = 0; i < bufNFrames; i += nChannels, ++j) {
                foreach(r; _regions) {
                    if(!r.mute()) {
                        mixBuf[i] += r.getSampleGlobal(0, offset + j);
                        if(r.nChannels > 1) {
                            mixBuf[i + 1] += r.getSampleGlobal(1, offset + j);
                        }
                    }
                }
            }
        }
    }

    void mixStereoNonInterleaved(nframes_t offset,
                                 nframes_t bufNFrames,
                                 sample_t* mixBuf1,
                                 sample_t* mixBuf2) @nogc nothrow {
        if(!_mute) {
            for(auto i = 0; i < bufNFrames; ++i) {
                foreach(r; _regions) {
                    if(!r.mute()) {
                        mixBuf1[i] += r.getSampleGlobal(0, offset + i);
                        if(r.nChannels > 1) {
                            mixBuf2[i] += r.getSampleGlobal(1, offset + i);
                        }
                    }
                }
            }
        }
    }

    ResizeDelegate resizeDelegate;

private:
    Region[] _regions;

    bool _mute;
    bool _solo;
}

abstract class Mixer {
public:
    this(string appName) {
        _appName = appName;

        initializeMixer();
    }

    ~this() {
        cleanupMixer();
    }

    final Track createTrack() {
        Track track = new Track();
        track.resizeDelegate = &resizeIfNecessary;
        _tracks ~= track;
        return track;
    }

    final bool resizeIfNecessary(nframes_t newNFrames) {
        if(newNFrames > _nframes) {
            _nframes = newNFrames;
            return true;
        }
        return false;
    }

    @property nframes_t sampleRate();

    @property final string appName() const @nogc nothrow {
        return _appName;
    }
    @property final nframes_t nframes() const @nogc nothrow {
        return _nframes;
    }
    @property final nframes_t nframes(nframes_t newNFrames) @nogc nothrow {
        return (_nframes = newNFrames);
    }
    @property final nframes_t lastFrame() const @nogc nothrow {
        return (_nframes > 0 ? nframes - 1 : 0);
    }
    @property final nframes_t transportOffset() const @nogc nothrow {
        return _transportOffset;
    }
    @property final nframes_t transportOffset(nframes_t newOffset) @nogc nothrow {
        disableLoop();
        return (_transportOffset = min(newOffset, nframes));
    }

    @property final bool playing() const @nogc nothrow {
        return _playing;
    }
    final void play() nothrow {
        GC.disable(); // disable garbage collection while playing

        _playing = true;
    }
    final void pause() nothrow {
        _playing = false;

        GC.enable(); // enable garbage collection while paused
    }

    @property final bool soloTrack() const @nogc nothrow { return _soloTrack; }
    @property final bool soloTrack(bool enable) @nogc nothrow { return (_soloTrack = enable); }

    @property final bool looping() const @nogc nothrow {
        return _looping;
    }
    final void enableLoop(nframes_t loopStart, nframes_t loopEnd) @nogc nothrow {
        _looping = true;
        _loopStart = loopStart;
        _loopEnd = loopEnd;
    }
    final void disableLoop() @nogc nothrow {
        _looping = false;
    }

    final void mixStereoInterleaved(nframes_t bufNFrames, channels_t nChannels, sample_t* mixBuf) @nogc nothrow {
        // initialize the buffer to silence
        import core.stdc.string: memset;
        memset(mixBuf, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(!_transportFinished() && _playing) {
            if(_soloTrack) {
                foreach(t; _tracks) {
                    if(t.solo) {
                        t.mixStereoInterleaved(_transportOffset, bufNFrames, nChannels, mixBuf);
                    }
                }
            }
            else {
                foreach(t; _tracks) {
                    t.mixStereoInterleaved(_transportOffset, bufNFrames, nChannels, mixBuf);
                }
            }

            _transportOffset += bufNFrames / nChannels;

            if(_looping && _transportOffset >= _loopEnd) {
                _transportOffset = _loopStart;
            }
        }
    }

    final void mixStereoNonInterleaved(nframes_t bufNFrames, sample_t* mixBuf1, sample_t* mixBuf2) @nogc nothrow {
        // initialize the buffers to silence
        import core.stdc.string: memset;
        memset(mixBuf1, 0, sample_t.sizeof * bufNFrames);
        memset(mixBuf2, 0, sample_t.sizeof * bufNFrames);

        // mix all tracks down to stereo
        if(!_transportFinished() && _playing) {
            if(_soloTrack) {
                foreach(t; _tracks) {
                    if(t.solo) {
                        t.mixStereoNonInterleaved(_transportOffset, bufNFrames, mixBuf1, mixBuf2);
                    }
                }
            }
            foreach(t; _tracks) {
                t.mixStereoNonInterleaved(_transportOffset, bufNFrames, mixBuf1, mixBuf2);
            }

            _transportOffset += bufNFrames;

            if(_looping && _transportOffset >= _loopEnd) {
                _transportOffset = _loopStart;
            }
        }
    }

protected:
    void initializeMixer();
    void cleanupMixer();

private:
    // stop playing if the transport is at the end of the project
    bool _transportFinished() @nogc nothrow {
        if(_playing && _transportOffset >= lastFrame) {
            _playing = _looping; // don't stop playing if currently looping
            _transportOffset = lastFrame;
            return true;
        }
        return false;
    }

    string _appName;

    Track[] _tracks;
    nframes_t _nframes;
    nframes_t _transportOffset;
    bool _playing;
    bool _looping;
    bool _soloTrack;
    nframes_t _loopStart;
    nframes_t _loopEnd;
}

version(HAVE_JACK) {

final class JackMixer : Mixer {
public:
    this(string appName) {
        if(_instance !is null) {
            throw new AudioError("Only one JackMixer instance may be constructed per process");
        }
        _instance = this;
        super(appName);
    }

    @property override nframes_t sampleRate() { return jack_get_sample_rate(_client); }

protected:
    override void initializeMixer() {
        _client = jack_client_open(appName.toStringz, JackOptions.JackNoStartServer, null);
        if(!_client) {
            throw new AudioError("jack_client_open failed");
        }

        immutable char* mixPort1Name = "StereoMix1";
        immutable char* mixPort2Name = "StereoMix2";
        _mixPort1 = jack_port_register(_client,
                                       mixPort1Name,
                                       JACK_DEFAULT_AUDIO_TYPE,
                                       JackPortFlags.JackPortIsOutput,
                                       0);
        _mixPort2 = jack_port_register(_client,
                                       mixPort2Name,
                                       JACK_DEFAULT_AUDIO_TYPE,
                                       JackPortFlags.JackPortIsOutput,
                                       0);
        if(!_mixPort1 || !_mixPort2) {
            throw new AudioError("jack_port_register failed");
        }

        // callback to process a single period of audio data
        if(jack_set_process_callback(_client, &_jackProcessCallback, null)) {
            throw new AudioError("jack_set_process_callback failed");
        }

        // activate the client
        if(jack_activate(_client)) {
            throw new AudioError("jack_activate failed");
        }

        // attempt to connect to physical playback ports
        const(char)** playbackPorts =
            jack_get_ports(_client, null, null, JackPortFlags.JackPortIsInput | JackPortFlags.JackPortIsPhysical);
        if(playbackPorts && playbackPorts[1]) {
            auto status1 = jack_connect(_client, jack_port_name(_mixPort1), playbackPorts[0]);
            auto status2 = jack_connect(_client, jack_port_name(_mixPort2), playbackPorts[1]);
            import core.stdc.errno : EEXIST;
            if((status1 && status2 != EEXIST) || (status2 && status2 != EEXIST)) {
                throw new AudioError("jack_connect failed ");
            }
        }
        jack_free(playbackPorts);
    }

    override void cleanupMixer() {
        jack_client_close(_client);
    }

private:
    extern(C) static int _jackProcessCallback(jack_nframes_t bufNFrames, void* arg) @nogc nothrow {
        sample_t* mixBuf1 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort1, bufNFrames));
        sample_t* mixBuf2 = cast(sample_t*)(jack_port_get_buffer(_instance._mixPort2, bufNFrames));

        _instance.mixStereoNonInterleaved(bufNFrames, mixBuf1, mixBuf2);

        return 0;
    };

    __gshared static JackMixer _instance; // there should be only one instance per process

    jack_client_t* _client;
    jack_port_t* _mixPort1;
    jack_port_t* _mixPort2;
}

}

version(HAVE_COREAUDIO) {

private extern(C) @nogc nothrow {
    char* coreAudioErrorString();
    bool coreAudioInit(nframes_t sampleRate, channels_t nChannels, AudioCallback callback);
    void coreAudioCleanup();
    alias AudioCallback = void function(nframes_t, channels_t, sample_t*);
}

final class CoreAudioMixer : Mixer {
public:
    enum outputChannels = 2; // default to stereo

    this(string appName, nframes_t sampleRate = 44100) {
        if(_instance !is null) {
            throw new AudioError("Only one CoreAudioMixer instance may be constructed per process");
        }
        _instance = this;
        _sampleRate = sampleRate;
        super(appName);
    }

    ~this() {
        _instance = null;
    }

    @property override nframes_t sampleRate() { return _sampleRate; }

protected:
    override void initializeMixer() {
        if(!coreAudioInit(sampleRate, outputChannels, &_coreAudioProcessCallback)) {
            throw new AudioError(to!string(coreAudioErrorString()));
        }
    }

    override void cleanupMixer() {
        coreAudioCleanup();
    }

private:
    extern(C) static void _coreAudioProcessCallback(nframes_t bufNFrames,
                                                    channels_t nChannels,
                                                    sample_t* mixBuffer) @nogc nothrow {
        _instance.mixStereoInterleaved(bufNFrames, nChannels, mixBuffer);
    }

    __gshared static CoreAudioMixer _instance; // there should be only one instance per process

    nframes_t _sampleRate;
}

}

enum Direction {
    left,
    right
}

struct BoundingBox {
    pixels_t x0, y0, x1, y1;

    // constructor will automatically adjust coordinates such that x0 <= x1 and y0 <= y1
    this(pixels_t x0, pixels_t y0, pixels_t x1, pixels_t y1) {
        if(x0 > x1) swap(x0, x1);
        if(y0 > y1) swap(y0, y1);

        this.x0 = x0;
        this.y0 = y0;
        this.x1 = x1;
        this.y1 = y1;
    }

    bool intersect(ref const(BoundingBox) other) const {
        return !(other.x0 > x1 || other.x1 < x0 || other.y0 > y1 || other.y1 < y0);
    }

    bool containsPoint(pixels_t x, pixels_t y) const {
        return (x >= x0 && x <= x1) && (y >= y0 && y <= y1);
    }
}

struct Color {
    double r = 0;
    double g = 0;
    double b = 0;

    template opBinary(T) {
        Color opBinary(string op)(T rhs) if(isNumeric!T) {
            static if(op == "+" || op == "-" || op == "*" || op == "/") {
                return mixin("Color(r " ~ op ~ " rhs, g " ~ op ~ " rhs.g, b " ~ op ~" rhs.b)");
            }
            else {
                static assert(0, "Operator " ~ op ~ " not implemented");
            }
        }
    }

    Color opBinary(string op)(Color rhs) {
        static if(op == "+" || op == "-" || op == "*" || op == "/") {
            return mixin("Color(r " ~ op ~ " rhs.r, g " ~ op ~ " rhs.g, b " ~ op ~ " rhs.b)");
        }
        else {
            static assert(0, "Operator " ~ op ~ " not implemented");
        }
    }
}

class ErrorDialog : MessageDialog {
public:
    this(Window parentWindow, string errorMessage) {
        super(parentWindow,
              DialogFlags.MODAL,
              MessageType.ERROR,
              ButtonsType.OK,
              "Error: " ~ errorMessage);
    }

    static display(Window parentWindow, string errorMessage) {
        auto dialog = new ErrorDialog(parentWindow, errorMessage);
        dialog.run();
        dialog.destroy();
    }
}

class ArrangeView : Box {
public:
    enum defaultSamplesPerPixel = 500; // default zoom level, in samples per pixel
    enum defaultTrackHeightPixels = 200; // default height in pixels of new tracks in the arrange view
    enum defaultTrackStubWidth = 200; // default width in pixels for all track stubs
    enum defaultChannelStripWidth = 100; // default width in pixels for the channel strip
    enum refreshRate = 50; // rate in hertz at which to redraw the view when the transport is playing
    enum mouseOverThreshold = 2; // threshold number of pixels in one direction for mouse over events

    // convenience constants for GTK mouse buttons
    enum leftButton = 1;
    enum rightButton = 3;

    enum Mode {
        arrange,
        editRegion
    }

    enum Action {
        none,
        selectRegion,
        shrinkRegionStart,
        shrinkRegionEnd,
        selectSubregion,
        selectBox,
        moveOnset,
        moveRegion,
        moveTransport,
        createMarker,
        jumpToMarker,
        centerView,
        centerViewStart,
        centerViewEnd,
        moveMarker
    }

    this(string appName, Window parentWindow, Mixer mixer) {
        _parentWindow = parentWindow;
        _mixer = mixer;
        _samplesPerPixel = defaultSamplesPerPixel;

        _arrangeStateHistory = StateHistory!ArrangeState(ArrangeState());

        _canvas = new Canvas();
        _channelStrip = new ChannelStrip();
        _trackStubs = new TrackStubs();
        _hScroll = new ArrangeHScroll();
        _vScroll = new ArrangeVScroll();

        super(Orientation.HORIZONTAL, 0);
        auto vBox = new Box(Orientation.VERTICAL, 0);
        vBox.packStart(_canvas, true, true, 0);
        vBox.packEnd(_hScroll, false, false, 0);

        auto channelStripBox = new Box(Orientation.VERTICAL, 0);
        channelStripBox.packStart(_channelStrip, true, true, 0);

        auto trackStubsBox = new Box(Orientation.VERTICAL, 0);
        trackStubsBox.packStart(_trackStubs, true, true, 0);

        auto hBox = new Box(Orientation.HORIZONTAL, 0);
        hBox.packStart(channelStripBox, false, false, 0);
        hBox.packStart(trackStubsBox, false, false, 0);
        hBox.packEnd(vBox, true, true, 0);
        packStart(hBox, true, true, 0);
        packEnd(_vScroll, false, false, 0);

        showAll();
    }

    final class ArrangeHScroll : Scrollbar {
    public:
        this() {
            _hAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
            reconfigure();
            _hAdjust.addOnValueChanged(&onHScrollChanged);
            super(Orientation.HORIZONTAL, _hAdjust);
        }

        void onHScrollChanged(Adjustment adjustment) {
            if(_centeredView) {
                _centeredView = false;
            }
            else if(_action == Action.centerView ||
                    _action == Action.centerViewStart ||
                    _action == Action.centerViewEnd) {
                _setAction(Action.none);
            }
            _viewOffset = cast(nframes_t)(adjustment.getValue());
            _canvas.redraw();
        }

        void reconfigure() {
            if(viewMaxSamples > 0) {
                _hAdjust.configure(_viewOffset, // scroll bar position
                                   viewMinSamples, // min position
                                   viewMaxSamples, // max position
                                   stepSamples,
                                   stepSamples * 5,
                                   viewWidthSamples); // scroll bar size
            }
        }
        void update() {
            _hAdjust.setValue(_viewOffset);
        }

        @property nframes_t stepSamples() {
            enum stepDivisor = 20;

            return cast(nframes_t)(viewWidthSamples / stepDivisor);
        }

    private:
        Adjustment _hAdjust;
    }

    final class ArrangeVScroll : Scrollbar {
    public:
        this() {
            _vAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
            reconfigure();
            _vAdjust.addOnValueChanged(&onVScrollChanged);
            super(Orientation.VERTICAL, _vAdjust);
        }

        void onVScrollChanged(Adjustment adjustment) {
            _verticalPixelsOffset = cast(pixels_t)(_vAdjust.getValue());
            _canvas.redraw();
            _trackStubs.redraw();
        }

        void reconfigure() {
            // add some padding to the bottom of the visible canvas
            pixels_t totalHeightPixels = _canvas.firstTrackYOffset + (defaultTrackHeightPixels / 2);

            // determine the total height of all tracks in pixels
            foreach(track; _trackViews) {
                totalHeightPixels += track.heightPixels;
            }

            _vAdjust.configure(_verticalPixelsOffset,
                               0,
                               totalHeightPixels,
                               totalHeightPixels / 20,
                               totalHeightPixels / 10,
                               _canvas.viewHeightPixels);
        }

        @property void pixelsOffset(pixels_t newValue) {
            _vAdjust.setValue(cast(pixels_t)(newValue));
        }

        @property pixels_t pixelsOffset() {
            return cast(pixels_t)(_vAdjust.getValue());
        }

        @property pixels_t stepIncrement() {
            return cast(pixels_t)(_vAdjust.getStepIncrement());
        }

    private:
        Adjustment _vAdjust;
    }

    abstract class ArrangeDialog {
    public:
        this(bool okButton = true) {
            _dialog = new Dialog();
            _dialog.setDefaultSize(250, 150);
            _dialog.setTransientFor(_parentWindow);
            auto content = _dialog.getContentArea();
            populate(content);

            if(okButton) {
                content.packEnd(createOKCancelButtons(&onOK, &onCancel), false, false, 10);
            }
            else {
                content.packEnd(createCancelButton(&onCancel), false, false, 10);
            }
            _dialog.showAll();
        }

        static ButtonBox createCancelButton(void delegate(Button) onCancel) {
            auto buttonBox = new ButtonBox(Orientation.HORIZONTAL);
            buttonBox.setLayout(ButtonBoxStyle.END);
            buttonBox.setBorderWidth(5);
            buttonBox.setSpacing(7);
            buttonBox.add(new Button("Cancel", onCancel));
            return buttonBox;
        }
        static ButtonBox createOKCancelButtons(void delegate(Button) onOK, void delegate(Button) onCancel) {
            auto buttonBox = new ButtonBox(Orientation.HORIZONTAL);
            buttonBox.setLayout(ButtonBoxStyle.END);
            buttonBox.setBorderWidth(5);
            buttonBox.setSpacing(7);
            buttonBox.add(new Button("OK", onOK));
            buttonBox.add(new Button("Cancel", onCancel));
            return buttonBox;
        }

    protected:
        final void destroyDialog() {
            _dialog.destroy();
        }

        void populate(Box content);

        void onOK(Button button) {
            destroyDialog();
        }
        void onCancel(Button button) {
            destroyDialog();
        }

    private:

        Dialog _dialog;
    }

    final class RenameTrackDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            if(_selectedTrack !is null) {
                _trackView = _selectedTrack;

                auto box = new Box(Orientation.VERTICAL, 5);
                box.packStart(new Label("Track Name"), false, false, 0);
                _nameEntry = new Entry(_trackView.name);
                box.packStart(_nameEntry, false, false, 0);
                content.packStart(box, false, false, 10);
            }
        }

        override void onOK(Button button) {
            if(_trackView !is null) {
                _trackView.name = _nameEntry.getText();
                destroyDialog();

                _trackStubs.redraw();
            }
            else {
                destroyDialog();
            }
        }

    private:
        TrackView _trackView;

        Entry _nameEntry;
    }

    final class OnsetDetectionDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            auto box1 = new Box(Orientation.VERTICAL, 5);
            box1.packStart(new Label("Onset Threshold"), false, false, 0);
            _onsetThresholdAdjustment = new Adjustment(_region.onsetParams.onsetThreshold,
                                                       Region.OnsetParams.onsetThresholdMin,
                                                       Region.OnsetParams.onsetThresholdMax,
                                                       0.01,
                                                       0.1,
                                                       0);
            auto onsetThresholdScale = new Scale(Orientation.HORIZONTAL, _onsetThresholdAdjustment);
            onsetThresholdScale.setDigits(3);
            box1.packStart(onsetThresholdScale, false, false, 0);
            content.packStart(box1, false, false, 10);

            auto box2 = new Box(Orientation.VERTICAL, 5);
            box2.packStart(new Label("Silence Threshold (dbFS)"), false, false, 0);
            _silenceThresholdAdjustment = new Adjustment(_region.onsetParams.silenceThreshold,
                                                         Region.OnsetParams.silenceThresholdMin,
                                                         Region.OnsetParams.silenceThresholdMax,
                                                         0.1,
                                                         1,
                                                         0);
            auto silenceThresholdScale = new Scale(Orientation.HORIZONTAL, _silenceThresholdAdjustment);
            silenceThresholdScale.setDigits(3);
            box2.packStart(silenceThresholdScale, false, false, 0);
            content.packStart(box2, false, false, 10);
        }

        override void onOK(Button button) {
            if(_region !is null) {
                _region.onsetParams.onsetThreshold = _onsetThresholdAdjustment.getValue();
                _region.onsetParams.silenceThreshold = _silenceThresholdAdjustment.getValue();
                destroyDialog();

                _region.computeOnsets();
                _canvas.redraw();
            }
            else {
                destroyDialog();
            }
        }

    private:
        RegionView _region;
        Adjustment _onsetThresholdAdjustment;
        Adjustment _silenceThresholdAdjustment;
    }

    final class StretchSelectionDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            content.packStart(new Label("Stretch factor"), false, false, 0);
            _stretchSelectionFactorAdjustment = new Adjustment(0,
                                                               -10,
                                                               10,
                                                               0.1,
                                                               0.5,
                                                               0);
            auto stretchSelectionRatioScale = new Scale(Orientation.HORIZONTAL, _stretchSelectionFactorAdjustment);
            stretchSelectionRatioScale.setDigits(2);
            content.packStart(stretchSelectionRatioScale, false, false, 10);
        }

        override void onOK(Button button) {
            if(_region !is null) {
                auto stretchRatio = _stretchSelectionFactorAdjustment.getValue();
                if(stretchRatio < 0) {
                    stretchRatio = 1.0 / (-stretchRatio);
                }
                else if(stretchRatio == 0) {
                    stretchRatio = 1;
                }
                destroyDialog();

                _region.subregionEndFrame =
                    _region.region.stretchSubregion(_editRegion.subregionStartFrame,
                                                    _editRegion.subregionEndFrame,
                                                    stretchRatio);
                if(_region.showOnsets) {
                    _region.computeOnsets();
                }
                _region.appendEditState(_region.currentEditState(true));

                _canvas.redraw();
            }
            else {
                destroyDialog();
            }
        }

    private:
        RegionView _region;
        Adjustment _stretchSelectionFactorAdjustment;
    }

    final class NormalizeDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            _normalizeEntireRegion = new RadioButton(cast(ListSG)(null), "Entire Region");
            _normalizeSelectionOnly = new RadioButton(_normalizeEntireRegion, "Selection Only");
            _normalizeSelectionOnly.setSensitive(_editRegion.subregionSelected);
            if(_editRegion.subregionSelected) {
                _normalizeSelectionOnly.setActive(true);
            }
            else {
                _normalizeEntireRegion.setActive(true);
            }

            auto hBox = new Box(Orientation.HORIZONTAL, 10);
            hBox.add(_normalizeEntireRegion);
            hBox.add(_normalizeSelectionOnly);
            content.packStart(hBox, false, false, 10);

            content.packStart(new Label("Normalize gain (dbFS)"), false, false, 0);
            _normalizeGainAdjustment = new Adjustment(-0.1, -20, 0, 0.01, 0.5, 0);
            auto normalizeGainScale = new Scale(Orientation.HORIZONTAL, _normalizeGainAdjustment);
            normalizeGainScale.setDigits(3);
            content.packStart(normalizeGainScale, false, false, 10);
        }

        override void onOK(Button button) {
            bool selectionOnly = _normalizeSelectionOnly.getActive();
            bool entireRegion = _normalizeEntireRegion.getActive();
            destroyDialog();

            if(_region !is null) {
                auto progressCallback = progressTaskCallback!(NormalizeState);
                auto progressTask = progressTask(
                    _region.region.name,
                    delegate void() {
                        if(_region.subregionSelected && selectionOnly) {
                            _region.region.normalize(_region.subregionStartFrame,
                                                     _region.subregionEndFrame,
                                                     cast(sample_t)(_normalizeGainAdjustment.getValue()),
                                                     progressCallback);
                            if(_editRegion.showOnsets) {
                                _editRegion.computeOnsets();
                            }
                            _region.appendEditState(_region.currentEditState(true));
                        }
                        else if(entireRegion) {
                            _region.region.normalize(cast(sample_t)(_normalizeGainAdjustment.getValue()),
                                                     progressCallback);
                            if(_editRegion.showOnsets) {
                                _editRegion.computeOnsets();
                            }
                            _region.appendEditState(_region.currentEditState(true));
                        }
                    });
                beginProgressTask!(NormalizeState, DefaultProgressTask)(progressTask);
                _canvas.redraw();
            }
        }

    private:
        RegionView _region;
        RadioButton _normalizeEntireRegion;
        RadioButton _normalizeSelectionOnly;
        Adjustment _normalizeGainAdjustment;
    }

    class RegionView {
    public:
        enum cornerRadius = 4; // radius of the rounded corners of the region, in pixels
        enum borderWidth = 1; // width of the edges of the region, in pixels
        enum headerHeight = 15; // height of the region's label, in pixels
        enum headerFont = "Arial 10"; // font family and size to use for the region's label

        void drawRegion(ref Scoped!Context cr,
                        pixels_t yOffset,
                        pixels_t heightPixels) {
            _drawRegion(cr, yOffset, heightPixels, region.offset, 1.0);
        }

        void drawRegionMoving(ref Scoped!Context cr,
                              pixels_t yOffset,
                              pixels_t heightPixels) {
            _drawRegion(cr, yOffset, heightPixels, selectedOffset, 0.5);
        }

        void computeOnsetsIndependentChannels() {
            auto progressCallback = progressTaskCallback!(ComputeOnsetsState);
            auto progressTask = progressTask(
                region.name,
                delegate void() {
                    progressCallback(ComputeOnsetsState.computeOnsets, 0);

                    // compute onsets independently for each channel
                    if(_onsets !is null) {
                        _onsets.destroy();
                    }
                    _onsets = [];
                    _onsets.reserve(region.nChannels);
                    for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                        _onsets ~= new OnsetSequence(region.getOnsetsSingleChannel(onsetParams,
                                                                                   channelIndex,
                                                                                   progressCallback));
                    }

                    progressCallback(ComputeOnsetsState.complete, 1);
                });
            beginProgressTask!(ComputeOnsetsState, DefaultProgressTask)(progressTask);
            _canvas.redraw();
        }

        void computeOnsetsLinkedChannels() {
            auto progressCallback = progressTaskCallback!(ComputeOnsetsState);
            auto progressTask = progressTask(
                region.name,
                delegate void() {
                    progressCallback(ComputeOnsetsState.computeOnsets, 0);
            
                    // compute onsets for summed channels
                    if(region.nChannels > 1) {
                        _onsetsLinked = new OnsetSequence(region.getOnsetsLinkedChannels(onsetParams,
                                                                                         progressCallback));
                    }

                    progressCallback(ComputeOnsetsState.complete, 1);
                });
            beginProgressTask!(ComputeOnsetsState, DefaultProgressTask)(progressTask);
            _canvas.redraw();
        }

        void computeOnsets() {
            if(linkChannels) {
                computeOnsetsLinkedChannels();
            }
            else {
                computeOnsetsIndependentChannels();
            }
        }

        // finds the index of any onset between (searchFrame - searchRadius) and (searchFrame + searchRadius)
        // if successful, returns true and stores the index in the searchIndex output argument
        bool getOnset(nframes_t searchFrame,
                      nframes_t searchRadius,
                      out nframes_t foundFrame,
                      out size_t foundIndex,
                      channels_t channelIndex = 0) {
            OnsetSequence onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];

            // recursive binary search helper function
            bool getOnsetRec(nframes_t searchFrame,
                             nframes_t searchRadius,
                             out nframes_t foundFrame,
                             out size_t foundIndex,
                             size_t leftIndex,
                             size_t rightIndex) {
                foundIndex = (leftIndex + rightIndex) / 2;
                if(foundIndex >= onsets.length) return false;

                foundFrame = onsets[foundIndex].onsetFrame;
                if(foundFrame >= searchFrame - searchRadius && foundFrame <= searchFrame + searchRadius) {
                    return true;
                }
                else if(leftIndex >= rightIndex) {
                    return false;
                }

                if(foundFrame < searchFrame) {
                    return getOnsetRec(searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       foundIndex + 1,
                                       rightIndex);
                }
                else {
                    return getOnsetRec(searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       leftIndex,
                                       foundIndex - 1);
                }
            }

            return getOnsetRec(searchFrame,
                               searchRadius,
                               foundFrame,
                               foundIndex,
                               0,
                               onsets.length - 1);
        }

        // move a specific onset given by onsetIndex, with the current position at currentOnsetFrame
        // returns the new onset value (locally indexed for this region)
        nframes_t moveOnset(size_t onsetIndex,
                            nframes_t currentOnsetFrame,
                            nframes_t relativeSamples,
                            Direction direction,
                            channels_t channelIndex = 0) {
            OnsetSequence onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            switch(direction) {
                case Direction.left:
                    nframes_t leftBound = (onsetIndex > 0) ? onsets[onsetIndex - 1].onsetFrame : 0;
                    if(onsets[onsetIndex].onsetFrame > relativeSamples &&
                       currentOnsetFrame - relativeSamples > leftBound) {
                        return currentOnsetFrame - relativeSamples;
                    }
                    else {
                        return leftBound;
                    }

                case Direction.right:
                    nframes_t rightBound = (onsetIndex < onsets.length - 1) ?
                        onsets[onsetIndex + 1].onsetFrame : region.nframes - 1;
                    if(currentOnsetFrame + relativeSamples < rightBound) {
                        return currentOnsetFrame + relativeSamples;
                    }
                    else {
                        return rightBound;
                    }

                default:
                    break;
            }
            return 0;
        }

        // these functions return onset frames, locally indexed for this region
        nframes_t getPrevOnset(size_t onsetIndex, channels_t channelIndex = 0) {
            auto onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            return (onsetIndex > 0) ? onsets[onsetIndex - 1].onsetFrame : 0;
        }
        nframes_t getNextOnset(size_t onsetIndex, channels_t channelIndex = 0) {
            auto onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            return (onsetIndex < onsets.length - 1) ? onsets[onsetIndex + 1].onsetFrame : region.nframes - 1;
        }

        channels_t mouseOverChannel(pixels_t mouseY) const {
            immutable pixels_t trackHeight = (boundingBox.y1 - boundingBox.y0) - headerHeight;
            immutable pixels_t channelHeight = trackHeight / region.nChannels;
            return clamp((mouseY - (boundingBox.y0 + headerHeight)) / channelHeight, 0, region.nChannels - 1);
        }

        struct EditState {
            this(bool audioEdited,
                 bool onsetsEdited,
                 bool onsetsLinkChannels,
                 channels_t onsetsChannelIndex,
                 bool subregionSelected,
                 nframes_t subregionStartFrame = 0,
                 nframes_t subregionEndFrame = 0) {
                this.audioEdited = audioEdited;

                this.onsetsEdited = onsetsEdited;
                this.onsetsLinkChannels = onsetsLinkChannels;
                this.onsetsChannelIndex = onsetsChannelIndex;

                this.subregionSelected = subregionSelected;
                this.subregionStartFrame = subregionStartFrame;
                this.subregionEndFrame = subregionEndFrame;
            }
            const(bool) audioEdited;

            const(bool) onsetsEdited;
            const(bool) onsetsLinkChannels;
            const(channels_t) onsetsChannelIndex;

            const(bool) subregionSelected;
            const(nframes_t) subregionStartFrame;
            const(nframes_t) subregionEndFrame;
        }

        EditState currentEditState(bool audioEdited,
                                   bool onsetsEdited = false,
                                   bool onsetsLinkChannels = false,
                                   channels_t onsetsChannelIndex = 0) {
            return EditState(audioEdited,
                             onsetsEdited,
                             onsetsLinkChannels,
                             onsetsChannelIndex,
                             subregionSelected,
                             subregionStartFrame,
                             subregionEndFrame);
        }

        void updateCurrentEditState() {
            subregionSelected = _editStateHistory.currentState.subregionSelected;
            if(subregionSelected) {
                subregionStartFrame = _editStateHistory.currentState.subregionStartFrame;
                subregionEndFrame = _editStateHistory.currentState.subregionEndFrame;

                editPointOffset = subregionStartFrame;
            }
        }

        void appendEditState(EditState editState) {
            _editStateHistory.appendState(editState);
        }

        void undoEdit() {
            if(_editStateHistory.queryUndo()) {
                if(_editStateHistory.currentState.audioEdited) {
                    region.undoEdit();
                }

                if(_editStateHistory.currentState.onsetsEdited) {
                    OnsetSequence onsets = _editStateHistory.currentState.onsetsLinkChannels ?
                        _onsetsLinked : _onsets[_editStateHistory.currentState.onsetsChannelIndex];
                    if(!onsets.queryUndo()) {
                        computeOnsets();
                    }
                    else {
                        onsets.undo();
                    }
                }
                else if(showOnsets) {
                    computeOnsets();
                }

                _editStateHistory.undo();
                updateCurrentEditState();
            }
        }
        void redoEdit() {
            if(_editStateHistory.queryRedo()) {
                _editStateHistory.redo();
                if(_editStateHistory.currentState.audioEdited) {
                    region.redoEdit();
                }

                if(_editStateHistory.currentState.onsetsEdited) {
                    OnsetSequence onsets = _editStateHistory.currentState.onsetsLinkChannels ?
                        _onsetsLinked : _onsets[_editStateHistory.currentState.onsetsChannelIndex];
                    if(!onsets.queryRedo()) {
                        computeOnsets();
                    }
                    else {
                        onsets.redo();
                    }
                }
                else if(showOnsets) {
                    computeOnsets();
                }

                updateCurrentEditState();
            }
        }

        Region region;

        @property nframes_t sliceStartFrame() const { return region.sliceStartFrame; }
        @property nframes_t sliceStartFrame(nframes_t newSliceStartFrame) {
            return (region.sliceStartFrame = newSliceStartFrame);
        }
        @property nframes_t sliceEndFrame() const { return region.sliceEndFrame; }
        @property nframes_t sliceEndFrame(nframes_t newSliceEndFrame) {
            return (region.sliceEndFrame = newSliceEndFrame);
        }

        @property channels_t nChannels() const @nogc nothrow { return region.nChannels; }
        @property nframes_t nframes() const @nogc nothrow { return region.nframes; }
        @property nframes_t offset() const @nogc nothrow { return region.offset; }
        @property nframes_t offset(nframes_t newOffset) { return (region.offset = newOffset); }

        bool selected;
        nframes_t selectedOffset;
        BoundingBox boundingBox;
        Region.OnsetParams onsetParams;

        nframes_t editPointOffset; // locally indexed for this region

        bool subregionSelected;
        nframes_t subregionStartFrame;
        nframes_t subregionEndFrame;

        @property bool editMode() const { return _editMode; }
        @property bool editMode(bool enable) { return (_editMode = enable); }

        @property bool showOnsets() const { return _showOnsets; }
        @property bool showOnsets(bool enable) {
            if(enable) {
                if(linkChannels && _onsetsLinked is null) {
                    computeOnsetsLinkedChannels();
                }
                else if(_onsets is null) {
                    computeOnsetsIndependentChannels();
                }
            }
            return (_showOnsets = enable);
        }

        @property bool linkChannels() const { return _linkChannels; }
        @property bool linkChannels(bool enable) {
            if(enable) {
                computeOnsetsLinkedChannels();
            }
            else {
                computeOnsetsIndependentChannels();
            }
            return (_linkChannels = enable);
        }

    private:
        this(Region region, Color* color) {
            this.region = region;
            _regionColor = color;

            _arrangeStateHistory = StateHistory!ArrangeState(ArrangeState());
            _editStateHistory = StateHistory!EditState(EditState());
        }

        void _drawRegion(ref Scoped!Context cr,
                         pixels_t yOffset,
                         pixels_t heightPixels,
                         nframes_t regionOffset,
                         double alpha) {
            enum degrees = PI / 180.0;

            cr.save();

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setAntialias(cairo_antialias_t.GOOD);

            // check that this region is in the visible area of the arrange view
            if((regionOffset >= viewOffset && regionOffset < viewOffset + viewWidthSamples) ||
               (regionOffset < viewOffset &&
                (regionOffset + region.nframes >= viewOffset ||
                 regionOffset + region.nframes <= viewOffset + viewWidthSamples))) {
                // xOffset is the number of horizontal pixels, if any, to skip before the start of the waveform
                immutable pixels_t xOffset =
                    (viewOffset < regionOffset) ? (regionOffset - viewOffset) / samplesPerPixel : 0;
                pixels_t height = heightPixels;

                // calculate the width, in pixels, of the visible area of the given region
                pixels_t width;
                if(regionOffset >= viewOffset) {
                    // the region begins after the view offset, and ends within the view
                    if(regionOffset + region.nframes <= viewOffset + viewWidthSamples) {
                        width = max(region.nframes / samplesPerPixel, 2 * cornerRadius);
                    }
                    // the region begins after the view offset, and ends past the end of the view
                    else {
                        width = (viewWidthSamples - (regionOffset - viewOffset)) / samplesPerPixel;
                    }
                }
                else if(regionOffset + region.nframes >= viewOffset) {
                    // the region begins before the view offset, and ends within the view
                    if(regionOffset + region.nframes < viewOffset + viewWidthSamples) {
                        width = (regionOffset + region.nframes - viewOffset) / samplesPerPixel;
                    }
                    // the region begins before the view offset, and ends past the end of the view
                    else {
                        width = viewWidthSamples / samplesPerPixel;
                    }
                }
                else {
                    // the region is not visible
                    return;
                }

                // get the bounding box for this region
                boundingBox.x0 = xOffset;
                boundingBox.y0 = yOffset;
                boundingBox.x1 = xOffset + width;
                boundingBox.y1 = yOffset + height;

                // these variables designate whether the left and right endpoints of the given region are visible
                bool lCorners = regionOffset + (cornerRadius * samplesPerPixel) >= viewOffset;
                bool rCorners = (regionOffset + region.nframes) - (cornerRadius * samplesPerPixel) <=
                    viewOffset + viewWidthSamples;

                cr.newSubPath();
                // top left corner
                if(lCorners) {
                    cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                           cornerRadius, 180 * degrees, 270 * degrees);
                }
                else {
                    cr.moveTo(xOffset - borderWidth, yOffset);
                    cr.lineTo(xOffset + width + (rCorners ? -cornerRadius : borderWidth), yOffset);
                }

                // right corners
                if(rCorners) {
                    cr.arc(xOffset + width - cornerRadius, yOffset + cornerRadius,
                           cornerRadius, -90 * degrees, 0 * degrees);
                    cr.arc(xOffset + width - cornerRadius, yOffset + height - cornerRadius,
                           cornerRadius, 0 * degrees, 90 * degrees);
                }
                else {
                    cr.lineTo(xOffset + width + borderWidth, yOffset);
                    cr.lineTo(xOffset + width + borderWidth, yOffset + height);
                }

                // bottom left corner
                if(lCorners) {
                    cr.arc(xOffset + cornerRadius, yOffset + height - cornerRadius,
                           cornerRadius, 90 * degrees, 180 * degrees);
                }
                else {
                    cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + height);
                }
                cr.closePath();

                // if the region is muted, save the border path for later rendering operations
                cairo_path_t* borderPath;
                if(region.mute) {
                    borderPath = cr.copyPath();
                }

                // fill the region background with a gradient
                if(yOffset != _prevYOffset) {
                    enum gradientScale1 = 0.80;
                    enum gradientScale2 = 0.65;

                    if(_regionGradient) {
                        _regionGradient.destroy();
                    }
                    _regionGradient = Pattern.createLinear(0, yOffset, 0, yOffset + height);
                    _regionGradient.addColorStopRgba(0,
                                                     _regionColor.r * gradientScale1,
                                                     _regionColor.g * gradientScale1,
                                                     _regionColor.b * gradientScale1,
                                                     alpha);
                    _regionGradient.addColorStopRgba(1,
                                                     _regionColor.r - gradientScale2,
                                                     _regionColor.g - gradientScale2,
                                                     _regionColor.b - gradientScale2,
                                                     alpha);
                }
                _prevYOffset = yOffset;
                cr.setSource(_regionGradient);
                cr.fillPreserve();

                // if this region is in edit mode or selected, highlight the borders and region header
                cr.setLineWidth(borderWidth);
                if(editMode) {
                    cr.setSourceRgba(1.0, 1.0, 0.0, alpha);
                }
                else if(selected) {
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                }
                else {
                    cr.setSourceRgba(0.5, 0.5, 0.5, alpha);
                }
                cr.stroke();
                if(selected) {
                    cr.newSubPath();
                    // left corner
                    if(lCorners) {
                        cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                               cornerRadius, 180 * degrees, 270 * degrees);
                    }
                    else {
                        cr.moveTo(xOffset - borderWidth, yOffset);
                        cr.lineTo(xOffset + width + (rCorners ? -cornerRadius : borderWidth), yOffset);
                    }

                    // right corner
                    if(rCorners) {
                        cr.arc(xOffset + width - cornerRadius, yOffset + cornerRadius,
                               cornerRadius, -90 * degrees, 0 * degrees);
                    }
                    else {
                        cr.lineTo(xOffset + width + borderWidth, yOffset);
                    }

                    // bottom
                    cr.lineTo(xOffset + width + (rCorners ? 0 : borderWidth), yOffset + headerHeight);
                    cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + headerHeight);
                    cr.closePath();
                    cr.fill();
                }

                // draw the region's label
                if(!_regionHeaderLabelLayout) {
                    PgFontDescription desc;
                    _regionHeaderLabelLayout = PgCairo.createLayout(cr);
                    desc = PgFontDescription.fromString(headerFont);
                    _regionHeaderLabelLayout.setFontDescription(desc);
                    desc.free();
                }

                void drawRegionLabel() {
                    if(selected) {
                        enum labelColorScale = 0.5;
                        cr.setSourceRgba(_regionColor.r * labelColorScale,
                                         _regionColor.g * labelColorScale,
                                         _regionColor.b * labelColorScale, alpha);
                    }
                    else {
                        cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    }
                    PgCairo.updateLayout(cr, _regionHeaderLabelLayout);
                    PgCairo.showLayout(cr, _regionHeaderLabelLayout);
                }

                cr.save();
                enum labelPadding = borderWidth + 1;
                int labelWidth, labelHeight;
                labelWidth += labelPadding;
                _regionHeaderLabelLayout.setText(region.mute ? region.name ~ " (muted)" : region.name);
                _regionHeaderLabelLayout.getPixelSize(labelWidth, labelHeight);
                if(xOffset == 0 && regionOffset < viewOffset && labelWidth + labelPadding > width) {
                    cr.translate(xOffset - (labelWidth - width), yOffset);
                    drawRegionLabel();
                }
                else if(labelWidth <= width || regionOffset + region.nframes > viewOffset + viewWidthSamples) {
                    cr.translate(xOffset + labelPadding, yOffset);
                    drawRegionLabel();
                }
                cr.restore();

                // height of the area containing the waveform, in pixels
                height = heightPixels - headerHeight;
                // y-coordinate in pixels where the waveform rendering begins
                pixels_t bodyYOffset = yOffset + headerHeight;
                // pixelsOffset is the screen-space x-coordinate at which to begin rendering the waveform
                pixels_t pixelsOffset =
                    (viewOffset > regionOffset) ? (viewOffset - regionOffset) / samplesPerPixel : 0;
                // height of each channel in pixels
                pixels_t channelHeight = height / region.nChannels;

                bool moveOnset;                
                pixels_t onsetPixelsStart,
                    onsetPixelsCenterSrc,
                    onsetPixelsCenterDest,
                    onsetPixelsEnd;
                double firstScaleFactor, secondScaleFactor;
                if(editMode && _editRegion == this && _action == Action.moveOnset) {
                    moveOnset = true;
                    long onsetViewOffset = (viewOffset > regionOffset) ? cast(long)(viewOffset) : 0;
                    long onsetRegionOffset = (viewOffset > regionOffset) ? cast(long)(regionOffset) : 0;
                    long onsetFrameStart, onsetFrameEnd, onsetFrameSrc, onsetFrameDest;

                    onsetFrameStart = onsetRegionOffset + getPrevOnset(_moveOnsetIndex, _moveOnsetChannel);
                    onsetFrameEnd = onsetRegionOffset + getNextOnset(_moveOnsetIndex, _moveOnsetChannel);
                    onsetFrameSrc = onsetRegionOffset + _moveOnsetFrameSrc;
                    onsetFrameDest = onsetRegionOffset + _moveOnsetFrameDest;
                    onsetPixelsStart =
                        cast(pixels_t)((onsetFrameStart - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsCenterSrc =
                        cast(pixels_t)((onsetFrameSrc - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsCenterDest =
                        cast(pixels_t)((onsetFrameDest - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsEnd =
                        cast(pixels_t)((onsetFrameEnd - onsetViewOffset) / samplesPerPixel);
                    firstScaleFactor = (onsetFrameSrc > onsetFrameStart) ?
                        (cast(double)(onsetFrameDest - onsetFrameStart) /
                         cast(double)(onsetFrameSrc - onsetFrameStart)) : 0;
                    secondScaleFactor = (onsetFrameEnd > onsetFrameSrc) ?
                        (cast(double)(onsetFrameEnd - onsetFrameDest) /
                         cast(double)(onsetFrameEnd - onsetFrameSrc)) : 0;
                }

                enum OnsetDrawState { init, firstHalf, secondHalf, complete }
                OnsetDrawState onsetDrawState;

                // draw the region's waveform
                auto cacheIndex = WaveformCache.getCacheIndex(_zoomStep);
                auto channelYOffset = bodyYOffset + (channelHeight / 2);
                for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                    pixels_t startPixel = (moveOnset && onsetPixelsStart < 0 && firstScaleFactor != 0) ?
                        max(cast(pixels_t)(onsetPixelsStart / firstScaleFactor), onsetPixelsStart) : 0;
                    pixels_t endPixel = (moveOnset && onsetPixelsEnd > width && secondScaleFactor != 0) ?
                        min(cast(pixels_t)((onsetPixelsEnd - width) / secondScaleFactor),
                            onsetPixelsEnd - width) : 0;

                    cr.newSubPath();
                    try {
                        cr.moveTo(xOffset, channelYOffset +
                                  region.getMax(channelIndex,
                                                cacheIndex,
                                                samplesPerPixel,
                                                pixelsOffset + startPixel) * (channelHeight / 2));
                    }
                    catch(RangeError) {
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1 + startPixel; i < width + endPixel; ++i) {
                        pixels_t scaledI = i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || linkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(i >= onsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                        goto case;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(i >= onsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                        goto case;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(onsetPixelsStart +
                                                                 (i - onsetPixelsStart) * firstScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(i >= onsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(onsetPixelsCenterDest +
                                                                 (i - onsetPixelsCenterSrc) * secondScaleFactor);

                                    }
                                    break;

                                default:
                                    break;
                            }
                        }
                        try {
                            cr.lineTo(xOffset + scaledI, channelYOffset -
                                      clamp(region.getMax(channelIndex,
                                                          cacheIndex,
                                                          samplesPerPixel,
                                                          pixelsOffset + i), 0, 1) * (channelHeight / 2));
                        }
                        catch(RangeError) {
                        }
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1 - endPixel; i <= width - startPixel; ++i) {
                        pixels_t scaledI = width - i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || linkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(width - i <= onsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                        goto case;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(width - i <= onsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                        goto case;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (onsetPixelsCenterDest +
                                             ((width - i) - onsetPixelsCenterSrc) * secondScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(width - i <= onsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (onsetPixelsStart +
                                             ((width - i) - onsetPixelsStart) * firstScaleFactor);
                                    }
                                    break;

                                default:
                                    break;
                            }
                        }
                        try {
                            cr.lineTo(xOffset + scaledI, channelYOffset -
                                      clamp(region.getMin(channelIndex,
                                                          cacheIndex,
                                                          samplesPerPixel,
                                                          pixelsOffset + width - i), -1, 0) * (channelHeight / 2));
                        }
                        catch(RangeError) {
                        }
                    }
                    cr.closePath();
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    cr.fill();
                    channelYOffset += channelHeight;
                }

                if(editMode) {
                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.setLineWidth(1.0);

                    // draw the onsets
                    if(showOnsets) {
                        if(linkChannels) {
                            foreach(onsetIndex, onset; _onsetsLinked[].enumerate) {
                                auto onsetFrame = (_action == Action.moveOnset && onsetIndex == _moveOnsetIndex) ?
                                    _moveOnsetFrameDest : onset.onsetFrame;
                                if(onsetFrame + regionOffset >= viewOffset &&
                                   onsetFrame + regionOffset < viewOffset + viewWidthSamples) {
                                    cr.moveTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                              bodyYOffset);
                                    cr.lineTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                              bodyYOffset + height);
                                }
                            }
                        }
                        else {
                            foreach(channelIndex, channel; _onsets) {
                                foreach(onsetIndex, onset; channel[].enumerate) {
                                    auto onsetFrame = (_action == Action.moveOnset &&
                                                       channelIndex == _moveOnsetChannel &&
                                                       onsetIndex == _moveOnsetIndex) ?
                                        _moveOnsetFrameDest : onset.onsetFrame;
                                    if(onsetFrame + regionOffset >= viewOffset &&
                                       onsetFrame + regionOffset < viewOffset + viewWidthSamples) {
                                        cr.moveTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                                  bodyYOffset +
                                                  cast(pixels_t)((channelIndex * channelHeight)));
                                        cr.lineTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                                  bodyYOffset +
                                                  cast(pixels_t)(((channelIndex + 1) * channelHeight)));
                                    }
                                }
                            }
                        }

                        cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                        cr.stroke();
                    }

                    // draw the subregion selection box
                    if(subregionSelected || _action == Action.selectSubregion) {
                        cr.setOperator(cairo_operator_t.OVER);
                        cr.setAntialias(cairo_antialias_t.NONE);

                        auto immutable globalSubregionStartFrame = subregionStartFrame + regionOffset;
                        auto immutable globalSubregionEndFrame = subregionEndFrame + regionOffset;
                        pixels_t x0 = (viewOffset < globalSubregionStartFrame) ?
                            (globalSubregionStartFrame - viewOffset) / samplesPerPixel : 0;
                        pixels_t x1 = (viewOffset < globalSubregionEndFrame) ?
                            (globalSubregionEndFrame - viewOffset) / samplesPerPixel : 0;
                        cr.rectangle(x0, yOffset, x1 - x0, headerHeight + height);
                        cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                        cr.fill();
                    }

                    // draw the edit point
                    if(editPointOffset + regionOffset >= viewOffset &&
                       editPointOffset + regionOffset < viewOffset + viewWidthSamples) {
                        enum editPointLineWidth = 1;
                        enum editPointWidth = 16;

                        cr.setLineWidth(editPointLineWidth);
                        cr.setSourceRgba(0.0, 1.0, 0.5, alpha);

                        immutable pixels_t editPointXPixel =
                            xOffset + editPointOffset / samplesPerPixel - pixelsOffset;

                        cr.moveTo(editPointXPixel - editPointWidth / 2, yOffset);
                        cr.lineTo(editPointXPixel - editPointWidth / 2, yOffset + headerHeight);
                        cr.lineTo(editPointXPixel, yOffset + headerHeight / 2);
                        cr.closePath();
                        cr.fill();

                        cr.moveTo(editPointXPixel + editPointLineWidth + editPointWidth / 2, yOffset);
                        cr.lineTo(editPointXPixel + editPointLineWidth + editPointWidth / 2, yOffset + headerHeight);
                        cr.lineTo(editPointXPixel + editPointLineWidth, yOffset + headerHeight / 2);
                        cr.closePath();
                        cr.fill();

                        cr.moveTo(editPointXPixel, yOffset);
                        cr.lineTo(editPointXPixel, yOffset + headerHeight + height);

                        cr.stroke();
                    }
                }

                // if the region is muted, gray it out
                if(region.mute) {
                    cr.setOperator(cairo_operator_t.OVER);
                    cr.appendPath(borderPath);
                    cr.setSourceRgba(0.5, 0.5, 0.5, 0.6);
                    cr.fill();
                }
            }

            cr.restore();
        }

        StateHistory!ArrangeState _arrangeStateHistory;
        StateHistory!EditState _editStateHistory;

        bool _editMode;
        bool _showOnsets;
        bool _linkChannels;

        OnsetSequence[] _onsets; // indexed as [channel][onset]
        OnsetSequence _onsetsLinked; // indexed as [onset]

        Color* _regionColor;

        Pattern _regionGradient;
        pixels_t _prevYOffset;
    }

    class TrackView {
    public:
        void addRegion(Region region, nframes_t sampleRate) {
            synchronized {
                _track.addRegion(region);

                RegionView regionView = new RegionView(region, &_trackColor);
                _regionViews ~= regionView;
                this.outer._regionViews ~= regionView;
            }

            _hScroll.reconfigure();
            _vScroll.reconfigure();
        }
        void addRegion(Region region) {
            addRegion(region, _mixer.sampleRate);
        }

        void drawRegions(ref Scoped!Context cr, pixels_t yOffset) {
            foreach(regionView; _regionViews) {
                Region r = regionView.region;
                if(_action == Action.moveRegion && regionView.selected) {
                    regionView.drawRegionMoving(cr, yOffset, heightPixels);
                }
                else {
                    regionView.drawRegion(cr, yOffset, heightPixels);
                }
            }
        }

        void drawStub(ref Scoped!Context cr,
                      pixels_t yOffset,
                      size_t trackIndex,
                      pixels_t trackNumberWidth) {
            alias labelPadding = TrackStubs.labelPadding;

            immutable Color selectedGradientTop = Color(0.5, 0.5, 0.5);
            immutable Color selectedGradientBottom = Color(0.3, 0.3, 0.3);
            immutable Color gradientTop = Color(0.2, 0.2, 0.2);
            immutable Color gradientBottom = Color(0.15, 0.15, 0.15);

            cr.save();
            cr.setOperator(cairo_operator_t.OVER);

            // compute the bounding box for this track
            boundingBox.x0 = 0;
            boundingBox.x1 = _trackStubWidth;
            boundingBox.y0 = yOffset;
            boundingBox.y1 = yOffset + heightPixels;

            // draw the track stub background
            cr.rectangle(0, yOffset, _trackStubWidth, heightPixels);
            Pattern trackGradient = Pattern.createLinear(0, yOffset, 0, yOffset + heightPixels);
            if(selected) {
                trackGradient.addColorStopRgb(0,
                                              selectedGradientTop.r,
                                              selectedGradientTop.g,
                                              selectedGradientTop.b);
                trackGradient.addColorStopRgb(1,
                                              selectedGradientBottom.r,
                                              selectedGradientBottom.g,
                                              selectedGradientBottom.b);
            }
            else {
                trackGradient.addColorStopRgb(0,
                                              gradientTop.r,
                                              gradientTop.g,
                                              gradientTop.b);
                trackGradient.addColorStopRgb(1,
                                              gradientBottom.r,
                                              gradientBottom.g,
                                              gradientBottom.b);
            }
            cr.setSource(trackGradient);
            cr.fill();

            cr.setSourceRgb(1.0, 1.0, 1.0);

            // draw the numeric track index
            cr.save();
            {
                _trackLabelLayout.setText(to!string(trackIndex + 1));
                int labelWidth, labelHeight;
                _trackLabelLayout.getPixelSize(labelWidth, labelHeight);
                cr.translate(trackNumberWidth / 2 - labelWidth / 2,
                             yOffset + heightPixels / 2 - labelHeight / 2);
                PgCairo.updateLayout(cr, _trackLabelLayout);
                PgCairo.showLayout(cr, _trackLabelLayout);
            }
            cr.restore();

            immutable pixels_t xOffset = trackNumberWidth + labelPadding * 2;

            // draw the track label
            pixels_t trackLabelHeight;
            cr.save();
            {
                _trackLabelLayout.setText(name);
                int labelWidth, labelHeight;
                _trackLabelLayout.getPixelSize(labelWidth, labelHeight);
                trackLabelHeight = cast(pixels_t)(labelHeight);
                cr.translate(xOffset, yOffset + heightPixels / 2 - labelHeight / 2);
                PgCairo.updateLayout(cr, _trackLabelLayout);
                PgCairo.showLayout(cr, _trackLabelLayout);
            }
            cr.restore();

            // draw the mute/solo buttons
            pixels_t buttonXOffset = xOffset;
            pixels_t buttonYOffset = yOffset + heightPixels / 2 + trackLabelHeight / 2 + labelPadding * 2;
            _trackButtonStrip.draw(cr, buttonXOffset, buttonYOffset);

            // draw separators
            cr.save();
            {
                // draw a separator above the first track
                if(trackIndex == 0) {
                    cr.moveTo(0, yOffset);
                    cr.lineTo(_trackStubWidth, yOffset);
                }

                // draw vertical separator
                cr.moveTo(trackNumberWidth, yOffset);
                cr.lineTo(trackNumberWidth, yOffset + heightPixels);

                // draw bottom horizontal separator
                cr.moveTo(0, yOffset + heightPixels);
                cr.lineTo(_trackStubWidth, yOffset + heightPixels);

                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.stroke();
            }
            cr.restore();

            cr.restore();
        }

        abstract class TrackButton {
        public:
            enum buttonWidth = 20;
            enum buttonHeight = 20;
            enum cornerRadius = 4;

            this(bool roundedLeftEdges = true, bool roundedRightEdges = true) {
                this.roundedLeftEdges = roundedLeftEdges;
                this.roundedRightEdges = roundedRightEdges;
            }

            final void draw(ref Scoped!Context cr, pixels_t xOffset, pixels_t yOffset) {
                alias labelPadding = TrackStubs.labelPadding;

                enum degrees = PI / 180.0;

                immutable Color gradientTop = Color(0.5, 0.5, 0.5);
                immutable Color gradientBottom = Color(0.2, 0.2, 0.2);
                immutable Color pressedGradientTop = Color(0.4, 0.4, 0.4);
                immutable Color pressedGradientBottom = Color(0.6, 0.6, 0.6);

                boundingBox.x0 = xOffset;
                boundingBox.y0 = yOffset;
                boundingBox.x1 = xOffset + buttonWidth;
                boundingBox.y1 = yOffset + buttonHeight;

                cr.save();
                cr.setAntialias(cairo_antialias_t.GOOD);
                cr.setLineWidth(1.0);

                // draw the button
                // top left corner
                if(roundedLeftEdges) {
                    cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                           cornerRadius, 180 * degrees, 270 * degrees);
                }
                else {
                    cr.moveTo(xOffset, yOffset);
                    cr.lineTo(xOffset + buttonWidth + (roundedRightEdges ? -cornerRadius : 0), yOffset);
                }

                // right corners
                if(roundedRightEdges) {
                    cr.arc(xOffset + buttonWidth - cornerRadius, yOffset + cornerRadius,
                           cornerRadius, -90 * degrees, 0 * degrees);
                    cr.arc(xOffset + buttonWidth - cornerRadius, yOffset + buttonHeight - cornerRadius,
                           cornerRadius, 0 * degrees, 90 * degrees);
                }
                else {
                    cr.lineTo(xOffset + buttonWidth, yOffset);
                    cr.lineTo(xOffset + buttonWidth, yOffset + buttonHeight);
                }

                // bottom left corner
                if(roundedLeftEdges) {
                    cr.arc(xOffset + cornerRadius, yOffset + buttonHeight - cornerRadius,
                           cornerRadius, 90 * degrees, 180 * degrees);
                }
                else {
                    cr.lineTo(xOffset, yOffset + buttonHeight);
                }
                cr.closePath();

                Pattern buttonGradient = Pattern.createLinear(0, yOffset, 0, yOffset + buttonHeight);
                Color processedGradientTop = (pressed || enabled) ? pressedGradientTop : gradientTop;
                Color processedGradientBottom = (pressed || enabled) ? pressedGradientBottom : gradientBottom;
                if(pressed || enabled) {
                    processedGradientTop = processedGradientTop * enabledColor;
                    processedGradientBottom = processedGradientBottom * enabledColor;
                }
                buttonGradient.addColorStopRgb(0,
                                               processedGradientTop.r,
                                               processedGradientTop.g,
                                               processedGradientTop.b);
                buttonGradient.addColorStopRgb(1,
                                               processedGradientBottom.r,
                                               processedGradientBottom.g,
                                               processedGradientBottom.b);
                cr.setSource(buttonGradient);
                cr.fillPreserve();

                cr.setSourceRgb(0.15, 0.15, 0.15);
                cr.stroke();

                // draw the button's text
                _trackButtonLayout.setText(buttonText);
                int widthPixels, heightPixels;
                _trackButtonLayout.getPixelSize(widthPixels, heightPixels);
                cr.moveTo(xOffset + buttonWidth / 2 - widthPixels / 2,
                          yOffset + buttonHeight / 2 - heightPixels / 2);
                cr.setSourceRgb(1.0, 1.0, 1.0);
                PgCairo.updateLayout(cr, _trackButtonLayout);
                PgCairo.showLayout(cr, _trackButtonLayout);

                cr.restore();
            }

            BoundingBox boundingBox;
            bool pressed;
            @property bool enabled() const { return _enabled; }
            @property bool enabled(bool setEnabled) {
                _enabled = setEnabled;
                onEnabled(setEnabled);
                return _enabled;
            }

        protected:
            void onEnabled(bool enabled) {
            }

            @property string buttonText() const;
            @property Color enabledColor() const { return Color(1.0, 1.0, 1.0); }

            immutable bool roundedLeftEdges;
            immutable bool roundedRightEdges;

        private:
            bool _enabled;
        }

        final class MuteButton : TrackButton {
        public:
            this() {
                super(true, false);
            }

        protected:
            override void onEnabled(bool enabled) {
                _track.mute = enabled;
            }

            @property override string buttonText() const { return "M"; }
            @property override Color enabledColor() const { return Color(0.0, 1.0, 1.0); }
        }

        final class SoloButton : TrackButton {
        public:
            this() {
                super(false, true);
            }

        protected:
            override void onEnabled(bool enabled) {
                _track.solo = enabled;
                if(enabled) {
                    _mixer.soloTrack = true;
                }
                else {
                    foreach(trackView; _trackViews) {
                        if(trackView.solo) {
                            return;
                        }
                    }
                    _mixer.soloTrack = false;
                }
            }

            @property override string buttonText() const { return "S"; }
            @property override Color enabledColor() const { return Color(1.0, 1.0, 0.0); }
        }

        class TrackButtonStrip {
        public:
            this() {
                muteButton = new MuteButton();
                soloButton = new SoloButton();
            }

            void draw(ref Scoped!Context cr, pixels_t xOffset, pixels_t yOffset) {
                muteButton.draw(cr, xOffset, yOffset);
                soloButton.draw(cr, xOffset + TrackButton.buttonWidth, yOffset);
            }

            @property TrackButton[] trackButtons() {
                return [muteButton, soloButton];
            }

            MuteButton muteButton;
            SoloButton soloButton;
        }

        @property TrackButton[] trackButtons() {
            return _trackButtonStrip.trackButtons;
        }

        @property bool mute() const { return _track.mute; }
        @property bool solo() const { return _track.solo; }

        @property pixels_t heightPixels() const {
            return cast(pixels_t)(max(_baseHeightPixels * _verticalScaleFactor, RegionView.headerHeight));
        }

        @property RegionView[] regionViews() { return _regionViews; }

        @property string name() const { return _name; }
        @property string name(string newName) { return (_name = newName); }

        BoundingBox boundingBox;
        bool selected;

    private:
        this(Track track, pixels_t heightPixels, string name) {
            _track = track;

            _baseHeightPixels = heightPixels;
            _trackColor = _newTrackColor();
            _name = name;

            _trackButtonStrip = new TrackButtonStrip();
        }

        static Color _newTrackColor() {
            Color color;
            Random gen;
            auto i = uniform(0, 2);
            auto j = uniform(0, 2);
            auto k = uniform(0, 5);

            color.r = (i == 0) ? 1 : 0;
            color.g = (j == 0) ? 1 : 0;
            color.b = (j == 1) ? 1 : 0;
            color.g = (color.g == 0 && k == 0) ? 1 : color.g;
            color.b = (color.b == 0 && k == 1) ? 1 : color.b;

            if(uniform(0, 2)) color.r *= uniform(0.8, 1.0);
            if(uniform(0, 2)) color.g *= uniform(0.8, 1.0);
            if(uniform(0, 2)) color.b *= uniform(0.8, 1.0);

            return color;
        }
 
        Track _track;
        RegionView[] _regionViews;

        pixels_t _baseHeightPixels;
        Color _trackColor;
        string _name;

        TrackButtonStrip _trackButtonStrip;
    }

    struct Marker {
        nframes_t offset;
        string name;
    }

    TrackView createTrackView(string trackName) {
        synchronized {
            TrackView trackView;
            trackView = new TrackView(_mixer.createTrack(), defaultTrackHeightPixels, trackName);

            // deselect current track
            if(_selectedTrack !is null) {
                _selectedTrack.selected = false;
            }

            // select the new track
            trackView.selected = true;
            _selectedTrack = trackView;
            _trackViews ~= trackView;

            _canvas.redraw();
            _trackStubs.redraw();
            return trackView;
        }
    }

    void loadRegionsFromFiles(const(string[]) fileNames) {
        auto progressCallback = progressTaskCallback!(LoadState);
        void loadRegionTask(string fileName) {
            auto newSequence = AudioSequence.fromFile(fileName, _mixer.sampleRate, progressCallback);
            Region newRegion = new Region(newSequence);
            if(newRegion is null) {
                ErrorDialog.display(_parentWindow, "Could not load file " ~ baseName(fileName));
            }
            else {
                auto newTrack = createTrackView(newRegion.name);
                newTrack.addRegion(newRegion);
            }
        }
        alias RegionTask = ProgressTask!(typeof(task(&loadRegionTask, string.init)));
        auto regionTaskList = appender!(RegionTask[]);
        foreach(fileName; fileNames) {
            regionTaskList.put(progressTask(baseName(fileName), task(&loadRegionTask, fileName)));
        }

        if(regionTaskList.data.length > 0) {
            beginProgressTask!(LoadState, RegionTask)(regionTaskList.data);
            _canvas.redraw();
        }
    }

    @property nframes_t samplesPerPixel() const { return _samplesPerPixel; }
    @property nframes_t viewOffset() const { return _viewOffset; }
    @property nframes_t viewWidthSamples() { return _canvas.viewWidthPixels * _samplesPerPixel; }

    @property nframes_t viewMinSamples() { return 0; }
    @property nframes_t viewMaxSamples() { return _mixer.lastFrame + viewWidthSamples; }

private:
    enum _zoomStep = 10;
    @property size_t _zoomMultiplier() const {
        if(_samplesPerPixel > 2000) {
            return 20;
        }
        if(_samplesPerPixel > 1000) {
            return 10;
        }
        if(_samplesPerPixel > 700) {
            return 5;
        }
        if(_samplesPerPixel > 400) {
            return 4;
        }
        else if(_samplesPerPixel > 200) {
            return 3;
        }
        else if(_samplesPerPixel > 100) {
            return 2;
        }
        else {
            return 1;
        }
    }

    enum _verticalZoomFactor = 1.2f;
    enum _verticalZoomFactorMax = _verticalZoomFactor * 3;
    enum _verticalZoomFactorMin = _verticalZoomFactor / 10;

    void _createArrangeMenu() {
        _arrangeMenu = new Menu();

        _arrangeMenu.append(new MenuItem(&onImportFile, "Import file..."));

        _arrangeMenu.attachToWidget(this, null);
    }

    void onImportFile(MenuItem menuItem) {
        if(_importFileChooser is null) {
            _importFileChooser = new FileChooserDialog("Import Audio file",
                                                       _parentWindow,
                                                       FileChooserAction.OPEN,
                                                       null,
                                                       null);
            _importFileChooser.setSelectMultiple(true);
        }

        auto fileNames = appender!(string[])();
        auto response = _importFileChooser.run();
        if(response == ResponseType.OK) {
            ListSG fileList = _importFileChooser.getUris();
            for(auto i = 0; i < fileList.length(); ++i) {
                string hostname;
                fileNames.put(URI.filenameFromUri(Str.toString(cast(char*)(fileList.nthData(i))), hostname));
            }
            _importFileChooser.hide();
        }
        else if(response == ResponseType.CANCEL) {
            _importFileChooser.hide();
        }
        else {
            _importFileChooser.destroy();
            _importFileChooser = null;
        }

        loadRegionsFromFiles(fileNames.data);
    }

    auto beginProgressTask(ProgressState, ProgressTask, bool cancelButton = true)(ProgressTask[] taskList)
        if(__traits(isSame, TemplateOf!ProgressState, .ProgressState) &&
           __traits(isSame, TemplateOf!ProgressTask, .ProgressTask)) {
            enum progressRefreshRate = 10; // in Hz
            enum progressMessageTimeout = 10.msecs;

            auto progressDialog = new Dialog();
            progressDialog.setDefaultSize(400, 75);
            progressDialog.setTransientFor(_parentWindow);

            auto dialogBox = progressDialog.getContentArea();
            auto progressBar = new ProgressBar();
            dialogBox.packStart(progressBar, false, false, 20);

            auto progressLabel = new Label(string.init);
            dialogBox.packStart(progressLabel, false, false, 10);

            static if(cancelButton) {
                void onProgressCancel(Button button) {
                    progressDialog.response(ResponseType.CANCEL);
                }
                dialogBox.packEnd(ArrangeDialog.createCancelButton(&onProgressCancel), false, false, 10);
            }

            if(taskList.length > 0) {
                setMaxMailboxSize(thisTid,
                                  LoadState.nStages * LoadState.stepsPerStage,
                                  OnCrowding.ignore);

                size_t currentTaskIndex = 0;
                ProgressTask currentTask = taskList[currentTaskIndex];

                void beginTask(ProgressTask currentTask) {
                    progressDialog.setTitle(currentTask.name);
                    currentTask.task.executeInNewThread();
                }
                beginTask(currentTask);

                static string stageCases() {
                    string result;
                    foreach(stage; __traits(allMembers, ProgressState.Stage)[0 .. $ - 1]) {
                        result ~=
                            "case ProgressState.Stage." ~ cast(string)(stage) ~ ": " ~
                            "progressLabel.setText(ProgressState.stageDescriptions[ProgressState.Stage." ~
                            cast(string)(stage) ~ "] ~ \": \" ~ " ~ "currentTask.name); break;\n";
                    }
                    return result;
                }

                Timeout progressTimeout;
                bool onProgressRefresh() {
                    bool currentTaskComplete;
                    while(receiveTimeout(progressMessageTimeout,
                                         (ProgressState progressState) {
                                             progressBar.setFraction(progressState.completionFraction);

                                             final switch(progressState.stage) {
                                                 mixin(stageCases());

                                                 case ProgressState.complete:
                                                     currentTaskComplete = true;
                                                     break;
                                             }
                                         })) {}
                    if(currentTaskComplete) {
                        ++currentTaskIndex;
                        if(currentTaskIndex < taskList.length) {
                            currentTask = taskList[currentTaskIndex];
                            beginTask(currentTask);
                        }
                        else {
                            if(progressDialog.getWidgetStruct() !is null) {
                                progressDialog.response(ResponseType.ACCEPT);
                            }
                            progressTimeout.destroy();
                        }
                    }

                    return true;
                }
                progressTimeout = new Timeout(cast(uint)(1.0 / progressRefreshRate * 1000),
                                              &onProgressRefresh,
                                              false);

                progressDialog.showAll();
                progressDialog.run();
            }

            if(progressDialog.getWidgetStruct() !is null) {
                progressDialog.destroy();
            }
        }

    void beginProgressTask(ProgressState, ProgressTask, bool cancelButton = true)(ProgressTask task) {
        ProgressTask[] taskList = new ProgressTask[](1);
        taskList[0] = task;
        beginProgressTask!(ProgressState, ProgressTask, cancelButton)(taskList);
    }

    void _createTrackMenu() {
        _trackMenu = new Menu();

        _trackMenu.append(new MenuItem(delegate void(MenuItem) { new RenameTrackDialog(); },
                                       "Rename Track..."));

        _trackMenu.attachToWidget(this, null);
    }

    void _createEditRegionMenu() {
        _editRegionMenu = new Menu();

        _stretchSelectionMenuItem = new MenuItem(delegate void(MenuItem) { new StretchSelectionDialog(); },
                                                 "Stretch Selection...");
        _editRegionMenu.append(_stretchSelectionMenuItem);

        _editRegionMenu.append(new MenuItem(delegate void (MenuItem) { new NormalizeDialog(); },
                                            "Normalize..."));

        _showOnsetsMenuItem = new CheckMenuItem("Show Onsets");
        _showOnsetsMenuItem.addOnToggled(&onShowOnsets);
        _editRegionMenu.append(_showOnsetsMenuItem);

        _onsetDetectionMenuItem = new MenuItem(delegate void(MenuItem) { new OnsetDetectionDialog(); },
                                               "Onset Detection...");
        _editRegionMenu.append(_onsetDetectionMenuItem);

        _linkChannelsMenuItem = new CheckMenuItem("Link Channels");
        _linkChannelsMenuItem.addOnToggled(&onLinkChannels);
        _editRegionMenu.append(_linkChannelsMenuItem);

        _editRegionMenu.attachToWidget(this, null);
    }

    void onShowOnsets(CheckMenuItem showOnsets) {
        _editRegion.showOnsets = showOnsets.getActive();
        _canvas.redraw();
    }

    void onLinkChannels(CheckMenuItem linkChannels) {
        _editRegion.linkChannels = linkChannels.getActive();
        _canvas.redraw();
    }

    void _zoomIn() {
        auto zoomCount = _zoomMultiplier;
        for(auto i = 0; i < zoomCount; ++i) {
            auto step = _zoomStep;
            _samplesPerPixel = max(_samplesPerPixel - step, 10);
        }
        _canvas.redraw();
        _hScroll.reconfigure();
    }
    void _zoomOut() {
        auto zoomCount = _zoomMultiplier;
        for(auto i = 0; i < zoomCount; ++i) {
            auto step = _zoomStep;
            _samplesPerPixel += step;
        }
        _canvas.redraw();
        _hScroll.reconfigure();
    }

    void _zoomInVertical() {
        _verticalScaleFactor = max(_verticalScaleFactor / _verticalZoomFactor, _verticalZoomFactorMin);
        _canvas.redraw();
        _trackStubs.redraw();
        _vScroll.reconfigure();
    }
    void _zoomOutVertical() {
        _verticalScaleFactor = min(_verticalScaleFactor * _verticalZoomFactor, _verticalZoomFactorMax);
        _canvas.redraw();
        _trackStubs.redraw();
        _vScroll.reconfigure();
    }

    void _setCursor() {
        static Cursor cursorMoving;
        static Cursor cursorMovingOnset;

        void setCursorByType(Cursor cursor, CursorType cursorType) {
            if(cursor is null) {
                cursor = new Cursor(Display.getDefault(), cursorType);
            }
            getWindow().setCursor(cursor);
        }
        void setCursorDefault() {
            getWindow().setCursor(null);
        }

        switch(_action) {
            case Action.moveMarker:
            case Action.moveRegion:
                setCursorByType(cursorMoving, CursorType.FLEUR);
                break;

            case Action.shrinkRegionStart:
            case Action.shrinkRegionEnd:
            case Action.moveOnset:
                setCursorByType(cursorMovingOnset, CursorType.SB_H_DOUBLE_ARROW);
                break;

            default:
                setCursorDefault();
                break;
        }
    }

    void _setAction(Action action) {
        _action = action;
        _setCursor();
    }

    void _setMode(Mode mode) {
        switch(mode) {
            case Mode.editRegion:
                // enable edit mode for the first selected region
                _editRegion = null;
                foreach(regionView; _selectedRegions) {
                    regionView.editMode = true;
                    _editRegion = regionView;
                    break;
                }
                if(_editRegion is null) {
                    return;
                }
                break;

            default:
                // if the last mode was editRegion, unset the edit mode flag for the edited region
                if(_mode == Mode.editRegion) {
                    _editRegion.editMode = false;
                    _editRegion = null;
                }
                break;
        }

        _mode = mode;
        _canvas.redraw();
    }

    void _computeEarliestSelectedRegion() {
        _earliestSelectedRegion = null;
        nframes_t minOffset = nframes_t.max;
        foreach(regionView; _selectedRegions) {
            regionView.selectedOffset = regionView.offset;
            if(regionView.offset < minOffset) {
                minOffset = regionView.offset;
                _earliestSelectedRegion = regionView;
            }
        }
    }

    TrackView _mouseOverTrack() {
        foreach(trackView; _trackViews) {
            if(_mouseY >= trackView.boundingBox.y0 && _mouseY < trackView.boundingBox.y1) {
                return trackView;
            }
        }

        return null;
    }

    class ChannelStrip : DrawingArea {
    public:
        this() {
            _channelStripWidth = defaultChannelStripWidth;
            setSizeRequest(_channelStripWidth, 0);

            addOnDraw(&drawCallback);
        }

        void redraw() {
            queueDrawArea(0, 0, getWindow().getWidth(), getWindow().getHeight());
        }

        bool drawCallback(Scoped!Context cr, Widget widget) {
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.paint();

            return true;
        }

    private:
        pixels_t _channelStripWidth;
    }

    class TrackStubs : DrawingArea {
    public:
        enum labelPadding = 5; // general padding for track labels, in pixels
        enum labelFont = "Arial 12"; // font family and size to use for track labels
        enum buttonFont = "Arial 9"; // font family for track stub buttons; e.g., mute/solo

        this() {
            _trackStubWidth = defaultTrackStubWidth;
            setSizeRequest(_trackStubWidth, 0);

            addOnDraw(&drawCallback);
            addOnMotionNotify(&onMotionNotify);
            addOnButtonPress(&onButtonPress);
            addOnButtonRelease(&onButtonRelease);
        }

        void redraw() {
            queueDrawArea(0, 0, getWindow().getWidth(), getWindow().getHeight());
        }

        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(!_trackLabelLayout) {
                PgFontDescription desc;
                _trackLabelLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(TrackStubs.labelFont);
                _trackLabelLayout.setFontDescription(desc);
                desc.free();
            }
            if(!_trackButtonLayout) {
                PgFontDescription desc;
                _trackButtonLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(TrackStubs.buttonFont);
                _trackButtonLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);

            cr.setSourceRgb(0.1, 0.1, 0.1);
            cr.paint();

            // compute the width, in pixels, of the maximum track number
            pixels_t trackNumberWidth;
            {
                _trackLabelLayout.setText(to!string(_trackViews.length));
                int labelWidth, labelHeight;
                _trackLabelLayout.getPixelSize(labelWidth, labelHeight);
                trackNumberWidth = cast(pixels_t)(labelWidth) + labelPadding * 2;
            }

            // draw track stubs
            pixels_t yOffset = _canvas.firstTrackYOffset - _verticalPixelsOffset;
            foreach(trackIndex, trackView; _trackViews) {
                trackView.drawStub(cr, yOffset, trackIndex, trackNumberWidth);

                // increment yOffset for the next track
                yOffset += trackView.heightPixels;
            }

            return true;
        }

        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                pixels_t prevMouseX = _mouseX;
                pixels_t prevMouseY = _mouseY;
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                _mouseY = cast(typeof(_mouseX))(event.motion.y);
            }
            return true;
        }

        bool onButtonPress(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_PRESS) {
                TrackView trackView = _mouseOverTrack();

                if(event.button.button == leftButton) {
                    if(trackView !is null) {
                        // detect if the mouse is over a track button
                        _trackButtonPressed = null;
                        foreach(trackButton; trackView.trackButtons) {
                            if(trackButton.boundingBox.containsPoint(_mouseX, _mouseY)) {
                                trackButton.pressed = true;
                                _trackButtonPressed = trackButton;
                                redraw();
                                break;
                            }
                        }

                        if(_trackButtonPressed is null && trackView !is _selectedTrack) {
                            // deselect the previously selected track
                            if(_selectedTrack !is null) {
                                _selectedTrack.selected = false;
                            }

                            // select the new track
                            trackView.selected = true;
                            _selectedTrack = trackView;

                            redraw();
                        }
                    }
                }
                else if(event.button.button == rightButton && _selectedTrack !is null) {
                    // show a context menu on right-click
                    auto buttonEvent = event.button;

                    if(_trackMenu is null) {
                        _createTrackMenu();
                    }
                    _trackMenu.popup(buttonEvent.button, buttonEvent.time);
                    _trackMenu.showAll();
                }
            }
            return false;
        }

        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == leftButton) {
                if(_trackButtonPressed !is null) {
                    if(_trackButtonPressed.boundingBox.containsPoint(_mouseX, _mouseY)) {
                        // toggle the pressed track button
                        _trackButtonPressed.pressed = false;
                        _trackButtonPressed.enabled = !_trackButtonPressed.enabled;
                    }
                    else {
                        _trackButtonPressed.pressed = false;
                    }
                    _trackButtonPressed = null;
                    redraw();
                }
            }
            return false;
        }
    }

    class Canvas : DrawingArea {
        enum timeStripHeightPixels = 40;

        enum markerHeightPixels = 20;
        enum markerHeadWidthPixels = 16;

        enum timeMarkerFont = "Arial 10";
        enum markerLabelFont = "Arial 10";

        this() {
            setCanFocus(true);

            addOnDraw(&drawCallback);
            addOnSizeAllocate(&onSizeAllocate);
            addOnMotionNotify(&onMotionNotify);
            addOnButtonPress(&onButtonPress);
            addOnButtonRelease(&onButtonRelease);
            addOnScroll(&onScroll);
            addOnKeyPress(&onKeyPress);
        }

        @property pixels_t viewWidthPixels() const {
            return _viewWidthPixels;
        }
        @property pixels_t viewHeightPixels() const {
            return _viewHeightPixels;
        }

        @property pixels_t markerYOffset() {
            return timeStripHeightPixels;
        }

        @property pixels_t firstTrackYOffset() {
            return markerYOffset + markerHeightPixels;
        }

        @property nframes_t smallSeekIncrement() {
            return viewWidthSamples / 10;
        }

        @property nframes_t largeSeekIncrement() {
            return viewWidthSamples / 5;
        }

        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(_refreshTimeout is null) {
                _refreshTimeout = new Timeout(cast(uint)(1.0 / refreshRate * 1000), &onRefresh, false);
            }

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.paint();

            // draw the canvas; i.e., the visible area that contains the timeline and audio regions
            {
                drawBackground(cr);
                drawTracks(cr);
                drawMarkers(cr);
                drawTimeStrip(cr);
                drawTransport(cr);
                drawSelectBox(cr);
            }

            return true;
        }

        void drawBackground(ref Scoped!Context cr) {
            cr.save();

            nframes_t secondsDistanceSamples = _mixer.sampleRate;
            nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timeStripScaleFactor);
            pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;

            // draw all currently visible arrange ticks
            auto firstMarkerOffset = (viewOffset + tickDistanceSamples) % tickDistanceSamples;
            for(auto i = viewOffset - firstMarkerOffset;
                i < viewOffset + viewWidthSamples + tickDistanceSamples; i += tickDistanceSamples) {
                pixels_t xOffset =
                    cast(pixels_t)(((i >= viewOffset) ?
                                    cast(long)(i - viewOffset) : -cast(long)(viewOffset - i)) / samplesPerPixel);
                // draw primary arrange ticks
                cr.moveTo(xOffset, markerYOffset);
                cr.lineTo(xOffset, viewHeightPixels);
                cr.setSourceRgb(0.2, 0.2, 0.2);
                cr.stroke();

                // draw secondary arrange ticks
                cr.moveTo(xOffset + tickDistancePixels / 2, markerYOffset);
                cr.lineTo(xOffset + tickDistancePixels / 2, viewHeightPixels);
                cr.moveTo(xOffset + tickDistancePixels / 4, markerYOffset);
                cr.lineTo(xOffset + tickDistancePixels / 4, viewHeightPixels);
                cr.moveTo(xOffset + (tickDistancePixels / 4) * 3, markerYOffset);
                cr.lineTo(xOffset + (tickDistancePixels / 4) * 3, viewHeightPixels);
                cr.setSourceRgb(0.1, 0.1, 0.1);
                cr.stroke();
            }

            cr.restore();            
        }

        void drawTimeStrip(ref Scoped!Context cr) {
            enum primaryTickHeightFactor = 0.5;
            enum secondaryTickHeightFactor = 0.35;
            enum tertiaryTickHeightFactor = 0.2;

            enum timeStripBackgroundPadding = 2;

            cr.save();

            // draw a black background for the timeStrip
            cr.rectangle(0, 0, viewWidthPixels, timeStripHeightPixels - timeStripBackgroundPadding);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.fill();

            if(!_timeStripMarkerLayout) {
                PgFontDescription desc;
                _timeStripMarkerLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(timeMarkerFont);
                _timeStripMarkerLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setSourceRgb(1.0, 1.0, 1.0);
            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);
            nframes_t secondsDistanceSamples = _mixer.sampleRate;
            pixels_t secondsDistancePixels = secondsDistanceSamples / samplesPerPixel;

            void autoScale() {
                nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timeStripScaleFactor);
                pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;
                if(tickDistancePixels > 200) {
                    _timeStripScaleFactor *= 0.5f;
                }
                else if(tickDistancePixels < 100) {
                    _timeStripScaleFactor *= 2.0f;
                }
            }

            if(secondsDistancePixels > 150) {
                autoScale();
            }
            else if(secondsDistancePixels > 60) {
                _timeStripScaleFactor = 1;
            }
            else if(secondsDistancePixels > 25) {
                _timeStripScaleFactor = 2;
            }
            else if(secondsDistancePixels > 15) {
                _timeStripScaleFactor = 5;
            }
            else if(secondsDistancePixels > 10) {
                _timeStripScaleFactor = 10;
            }
            else if(secondsDistancePixels > 3) {
                _timeStripScaleFactor = 15;
            }
            else {
                autoScale();
            }

            nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timeStripScaleFactor);
            pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;

            auto decDigits = 1;
            if(secondsDistancePixels <= 15) {
                decDigits = 0;
            }
            else if(secondsDistancePixels >= 750) {
                decDigits = clamp(cast(typeof(decDigits))(10 - log(tickDistanceSamples)), 1, 5);
            }

            auto minuteSpec = singleSpec("%.0f");
            auto decDigitsFormat = to!string(decDigits) ~ 'f';
            auto secondsSpec = singleSpec("%." ~ decDigitsFormat);
            auto secondsSpecTwoDigitsString = appender!string();
            secondsSpecTwoDigitsString.put("%0");
            secondsSpecTwoDigitsString.put(to!string(decDigits > 0 ? decDigits + 3 : 2));
            secondsSpecTwoDigitsString.put('.');
            secondsSpecTwoDigitsString.put(decDigitsFormat);
            auto secondsSpecTwoDigits = singleSpec(secondsSpecTwoDigitsString.data);

            // draw all currently visible time ticks and their time labels
            auto firstMarkerOffset = (viewOffset + tickDistanceSamples) % tickDistanceSamples;
            for(auto i = viewOffset - firstMarkerOffset;
                i < viewOffset + viewWidthSamples + tickDistanceSamples; i += tickDistanceSamples) {
                pixels_t xOffset =
                    cast(pixels_t)(((i >= viewOffset) ?
                                    cast(long)(i - viewOffset) : -cast(long)(viewOffset - i)) / samplesPerPixel);

                // draw primary timeStrip tick
                cr.moveTo(xOffset, 0);
                cr.lineTo(xOffset, timeStripHeightPixels * primaryTickHeightFactor);

                // draw one secondary timeStrip tick
                cr.moveTo(xOffset + tickDistancePixels / 2, 0);
                cr.lineTo(xOffset + tickDistancePixels / 2, timeStripHeightPixels * secondaryTickHeightFactor);

                // draw two tertiary timeStrip ticks
                cr.moveTo(xOffset + tickDistancePixels / 4, 0);
                cr.lineTo(xOffset + tickDistancePixels / 4, timeStripHeightPixels * tertiaryTickHeightFactor);
                cr.moveTo(xOffset + (tickDistancePixels / 4) * 3, 0);
                cr.lineTo(xOffset + (tickDistancePixels / 4) * 3, timeStripHeightPixels * tertiaryTickHeightFactor);

                pixels_t timeMarkerXOffset;
                auto timeString = appender!string();
                auto minutes = (i / secondsDistanceSamples) / 60;
                if(i == 0) {
                    timeString.put('0');
                    timeMarkerXOffset = xOffset;
                }
                else {
                    if(minutes > 0) {
                        timeString.put(to!string(minutes));
                        timeString.put(':');
                        formatValue(timeString, float(i) / float(secondsDistanceSamples) - minutes * 60,
                                    secondsSpecTwoDigits);
                    }
                    else {
                        formatValue(timeString, float(i) / float(secondsDistanceSamples), secondsSpec);
                    }

                    int widthPixels, heightPixels;
                    _timeStripMarkerLayout.getPixelSize(widthPixels, heightPixels);
                    timeMarkerXOffset = xOffset - widthPixels / 2;
                }

                cr.setSourceRgb(1.0, 1.0, 1.0);
                cr.stroke();

                _timeStripMarkerLayout.setText(timeString.data);
                cr.moveTo(timeMarkerXOffset, timeStripHeightPixels * 0.5);
                PgCairo.updateLayout(cr, _timeStripMarkerLayout);
                PgCairo.showLayout(cr, _timeStripMarkerLayout);
            }

            cr.restore();
        }

        void drawTracks(ref Scoped!Context cr) {
            pixels_t yOffset = firstTrackYOffset - _verticalPixelsOffset;
            foreach(trackView; _trackViews) {
                trackView.drawRegions(cr, yOffset);
                yOffset += trackView.heightPixels;
            }
        }

        void drawTransport(ref Scoped!Context cr) {
            enum transportHeadWidth = 16;
            enum transportHeadHeight = 10;

            cr.save();

            if(_mode == Mode.editRegion && !_mixer.playing) {
                return;
            }
            else if(_action == Action.moveTransport) {
                _transportPixelsOffset = clamp(_mouseX, 0, (viewOffset + viewWidthSamples > _mixer.lastFrame) ?
                                               ((_mixer.lastFrame - viewOffset) / samplesPerPixel) :
                                               viewWidthPixels);
            }
            else if(viewOffset <= _mixer.transportOffset + (transportHeadWidth / 2) &&
                    _mixer.transportOffset <= viewOffset + viewWidthSamples + (transportHeadWidth / 2)) {
                _transportPixelsOffset = (_mixer.transportOffset - viewOffset) / samplesPerPixel;
            }
            else {
                return;
            }

            cr.setSourceRgb(1.0, 0.0, 0.0);
            cr.setLineWidth(1.0);
            cr.moveTo(_transportPixelsOffset, 0);
            cr.lineTo(_transportPixelsOffset, _viewHeightPixels);
            cr.stroke();

            cr.moveTo(_transportPixelsOffset - transportHeadWidth / 2, 0);
            cr.lineTo(_transportPixelsOffset + transportHeadWidth / 2, 0);
            cr.lineTo(_transportPixelsOffset, transportHeadHeight);
            cr.closePath();
            cr.fill();

            cr.restore();
        }

        void drawSelectBox(ref Scoped!Context cr) {
            if(_action == Action.selectBox) {
                cr.save();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.NONE);

                cr.setLineWidth(1.0);
                cr.rectangle(_selectMouseX, _selectMouseY, _mouseX - _selectMouseX, _mouseY - _selectMouseY);
                cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                cr.fillPreserve();
                cr.setSourceRgb(0.0, 1.0, 0.0);
                cr.stroke();

                cr.restore();
            }
        }

        void drawMarkers(ref Scoped!Context cr) {
            enum taperFactor = 0.75;

            cr.save();

            if(!_markerLabelLayout) {
                PgFontDescription desc;
                _markerLabelLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(markerLabelFont);
                _markerLabelLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);

            // draw the visible user-defined markers
            pixels_t yOffset = markerYOffset - _verticalPixelsOffset;
            foreach(ref marker; _markers) {
                if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples) {
                    pixels_t xOffset = (marker.offset - viewOffset) / samplesPerPixel;

                    cr.setAntialias(cairo_antialias_t.GOOD);
                    cr.moveTo(xOffset, yOffset + markerHeightPixels);
                    cr.lineTo(xOffset - markerHeadWidthPixels / 2, yOffset + markerHeightPixels * taperFactor);
                    cr.lineTo(xOffset - markerHeadWidthPixels / 2, yOffset);
                    cr.lineTo(xOffset + markerHeadWidthPixels / 2, yOffset);
                    cr.lineTo(xOffset + markerHeadWidthPixels / 2, yOffset + markerHeightPixels * taperFactor);
                    cr.closePath();
                    cr.setSourceRgb(1.0, 0.90, 0.0);
                    cr.fillPreserve();
                    cr.setSourceRgb(1.0, 0.65, 0.0);
                    cr.stroke();

                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.moveTo(xOffset, yOffset + markerHeightPixels);
                    cr.lineTo(xOffset, viewHeightPixels);
                    cr.stroke();

                    cr.setSourceRgb(0.0, 0.0, 0.0);
                    _markerLabelLayout.setText(marker.name);
                    int widthPixels, heightPixels;
                    _markerLabelLayout.getPixelSize(widthPixels, heightPixels);
                    cr.moveTo(xOffset - widthPixels / 2, yOffset);
                    PgCairo.updateLayout(cr, _markerLabelLayout);
                    PgCairo.showLayout(cr, _markerLabelLayout);
                }
            }

            // draw a dotted line at the end of the project, if visible
            if(_mixer.lastFrame > viewOffset && _mixer.lastFrame <= viewOffset + viewWidthSamples) {
                enum dottedLinePixels = 15;
                pixels_t xOffset = (_mixer.lastFrame - viewOffset) / samplesPerPixel;

                for(auto y = markerYOffset; y < viewHeightPixels; y += dottedLinePixels * 2) {
                    cr.moveTo(xOffset, y);
                    cr.lineTo(xOffset, y + dottedLinePixels);
                }
                cr.setSourceRgb(1.0, 1.0, 1.0);
                cr.stroke();
            }

            cr.restore();
        }

        void redraw() {
            queueDrawArea(0, 0, getWindow().getWidth(), getWindow().getHeight());
        }

        bool onRefresh() {
            if(_mixer.playing) {
                redraw();
                _mixerPlaying = true;
            }
            else if(_mixerPlaying) {
                _mixerPlaying = false;
                redraw();
            }
            return true;
        }

        void onSizeAllocate(GtkAllocation* allocation, Widget widget) {
            GtkAllocation size;
            getAllocation(size);
            _viewWidthPixels = cast(pixels_t)(size.width);
            _viewHeightPixels = cast(pixels_t)(size.height);

            _hScroll.reconfigure();
            _vScroll.reconfigure();
        }

        void onSelectSubregion() {
            if(_editRegion && _mouseX >= 0 && _mouseX <= viewWidthPixels) {
                immutable nframes_t mouseFrame =
                    clamp(_mouseX, _editRegion.boundingBox.x0, _editRegion.boundingBox.x1) *
                    samplesPerPixel + viewOffset;
                if(mouseFrame < _editRegion.subregionStartFrame + _editRegion.offset) {
                    _editRegion.subregionStartFrame = mouseFrame - _editRegion.offset;
                    _subregionDirection = Direction.left;
                }
                else if(mouseFrame > _editRegion.subregionEndFrame + _editRegion.offset) {
                    _editRegion.subregionEndFrame = mouseFrame - _editRegion.offset;
                    _subregionDirection = Direction.right;
                }
                else {
                    if(_subregionDirection == Direction.left) {
                        _editRegion.subregionStartFrame = mouseFrame - _editRegion.offset;
                    }
                    else {
                        _editRegion.subregionEndFrame = mouseFrame - _editRegion.offset;
                    }
                }

                if(_mixer.looping) {
                    _mixer.enableLoop(_editRegion.subregionStartFrame + _editRegion.offset,
                                      _editRegion.subregionEndFrame + _editRegion.offset);
                }

                redraw();
            }
        }

        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                pixels_t prevMouseX = _mouseX;
                pixels_t prevMouseY = _mouseY;
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                _mouseY = cast(typeof(_mouseX))(event.motion.y);

                switch(_action) {
                    case Action.selectRegion:
                        if(!_selectedRegions.empty) {
                            _setAction(Action.moveRegion);
                            redraw();
                        }
                        break;

                    case Action.shrinkRegionStart:
                        immutable nframes_t mouseFrame = viewOffset + max(_mouseX, 0) * samplesPerPixel;
                        immutable nframes_t minRegionWidth = RegionView.cornerRadius * 2 * samplesPerPixel;
                        _shrinkRegion.region.shrinkStart(
                            min(mouseFrame, _shrinkRegion.offset + _shrinkRegion.nframes - minRegionWidth));
                        redraw();
                        break;

                    case Action.shrinkRegionEnd:
                        immutable nframes_t mouseFrame = viewOffset + max(_mouseX, 0) * samplesPerPixel;
                        _shrinkRegion.region.shrinkEnd(mouseFrame);
                        redraw();
                        break;

                    case Action.selectSubregion:
                        onSelectSubregion();
                        break;

                    case Action.selectBox:
                        redraw();
                        break;

                    case Action.moveRegion:
                        foreach(regionView; _selectedRegions) {
                            immutable nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                            if(_mouseX > prevMouseX) {
                                regionView.selectedOffset += deltaXSamples;
                            }
                            else if(_earliestSelectedRegion.selectedOffset > abs(deltaXSamples)) {
                                regionView.selectedOffset -= deltaXSamples;
                            }
                            else {
                                regionView.selectedOffset =
                                    regionView.offset > _earliestSelectedRegion.offset ?
                                    regionView.offset - _earliestSelectedRegion.offset : 0;
                            }
                        }
                        redraw();
                        break;

                    case Action.moveMarker:
                        immutable nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                        if(_mouseX > prevMouseX) {
                            if(_moveMarker.offset + deltaXSamples >= _mixer.lastFrame) {
                                _moveMarker.offset = _mixer.lastFrame;
                            }
                            else {
                                _moveMarker.offset += deltaXSamples;
                            }
                        }
                        else if(_moveMarker.offset > abs(deltaXSamples)) {
                            _moveMarker.offset -= deltaXSamples;
                        }
                        else {
                            _moveMarker.offset = 0;
                        }
                        redraw();
                        break;

                    case Action.moveOnset:
                        immutable nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                        immutable Direction direction = (_mouseX > prevMouseX) ? Direction.right : Direction.left;
                        _moveOnsetFrameDest = _editRegion.moveOnset(_moveOnsetIndex,
                                                                    _moveOnsetFrameDest,
                                                                    deltaXSamples,
                                                                    direction,
                                                                    _moveOnsetChannel);

                        redraw();
                        break;

                    case Action.moveTransport:
                        redraw();
                        break;

                    case Action.none:
                    default:
                        break;
                }
            }
            return true;
        }

        bool onButtonPress(Event event, Widget widget) {
            GdkModifierType state;
            event.getState(state);
            auto shiftPressed = state & GdkModifierType.SHIFT_MASK;
            auto controlPressed = state & GdkModifierType.CONTROL_MASK;

            if(event.type == EventType.BUTTON_PRESS && event.button.button == leftButton) {
                // if the mouse is over a marker, move that marker
                if(_mouseY >= markerYOffset && _mouseY < markerYOffset + markerHeightPixels) {
                    foreach(ref marker; _markers) {
                        if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples &&
                           (cast(pixels_t)((marker.offset - viewOffset) / samplesPerPixel) -
                            markerHeadWidthPixels / 2 <= _mouseX) &&
                           (cast(pixels_t)((marker.offset - viewOffset) / samplesPerPixel) +
                            markerHeadWidthPixels / 2 >= _mouseX)) {
                            _moveMarker = &marker;
                            _setAction(Action.moveMarker);
                            break;
                        }
                    }
                }

                // if the mouse was not over a marker
                if(_action != Action.moveMarker) {
                    // if the mouse is over the time strip, move the transport
                    if(_mouseY >= 0 && _mouseY < timeStripHeightPixels + markerHeightPixels) {
                        _setAction(Action.moveTransport);
                    }
                    else {
                        bool newAction;
                        switch(_mode) {
                            // implement different behaviors for button presses depending on the current mode
                            case Mode.arrange:
                                TrackView trackView = _mouseOverTrack();
                                if(trackView !is null) {
                                    RegionView mouseOverRegion;
                                    RegionView mouseOverRegionStart;
                                    RegionView mouseOverRegionEnd;

                                    // detect if the mouse is over an audio region
                                    foreach(regionView; trackView.regionViews) {
                                        if(_mouseY >= regionView.boundingBox.y0 + RegionView.headerHeight) {
                                            if(_mouseX >= regionView.boundingBox.x0 - mouseOverThreshold &&
                                               _mouseX <= regionView.boundingBox.x0 + mouseOverThreshold) {
                                                mouseOverRegionStart = regionView;
                                            }
                                            else if(_mouseX >= regionView.boundingBox.x1 - mouseOverThreshold &&
                                                    _mouseX <= regionView.boundingBox.x1 + mouseOverThreshold) {
                                                mouseOverRegionEnd = regionView;
                                            }
                                        }

                                        if(_mouseX >= regionView.boundingBox.x0 &&
                                           _mouseX < regionView.boundingBox.x1) {
                                            mouseOverRegion = regionView;
                                            break;
                                        }
                                    }

                                    // detect if the mouse is near one of the endpoints of a region;
                                    // if so, begin adjusting that endpoint
                                    if(!shiftPressed) {
                                        if(mouseOverRegionStart !is null) {
                                            // select the region
                                            mouseOverRegionStart.selected = true;
                                            _selectedRegionsApp.clear();
                                            _selectedRegionsApp.put(mouseOverRegionStart);
                                            _earliestSelectedRegion = mouseOverRegionStart;

                                            // begin shrinking the start of the region
                                            _shrinkRegion = mouseOverRegionStart;
                                            _setAction(Action.shrinkRegionStart);
                                            newAction = true;
                                        }
                                        else if(mouseOverRegionEnd !is null) {
                                            // select the region
                                            mouseOverRegionEnd.selected = true;
                                            _selectedRegionsApp.clear();
                                            _selectedRegionsApp.put(mouseOverRegionEnd);
                                            _earliestSelectedRegion = mouseOverRegionEnd;

                                            // begin shrinking the end of the region
                                            _shrinkRegion = mouseOverRegionEnd;
                                            _setAction(Action.shrinkRegionEnd);
                                            newAction = true;
                                        }
                                        else if(mouseOverRegion !is null &&
                                                mouseOverRegion.selected &&
                                                !shiftPressed) {
                                            _computeEarliestSelectedRegion();
                                            _setAction(Action.selectRegion);
                                            newAction = true;
                                        }
                                    }
                                }

                                if(!newAction) {
                                    // if shift is not currently pressed, deselect all regions
                                    if(!shiftPressed) {
                                        foreach(regionView; _selectedRegions) {
                                            regionView.selected = false;
                                        }
                                        _earliestSelectedRegion = null;
                                    }

                                    _selectedRegionsApp.clear();
                                    foreach(regionView; _regionViews) {
                                        if(_mouseX >= regionView.boundingBox.x0 &&
                                           _mouseX < regionView.boundingBox.x1 &&
                                           _mouseY >= regionView.boundingBox.y0 &&
                                           _mouseY < regionView.boundingBox.y1) {
                                            // if the region is already selected and shift is pressed, deselect it
                                            regionView.selected = !(regionView.selected && shiftPressed);
                                            newAction = true;
                                            break;
                                        }
                                    }
                                    foreach(regionView; _regionViews) {
                                        if(regionView.selected) {
                                            _selectedRegionsApp.put(regionView);
                                        }
                                    }
                                    _computeEarliestSelectedRegion();
                                    _setAction(Action.selectRegion);

                                    appendArrangeState(currentArrangeState());
                                }
                                break;

                            case Mode.editRegion:
                                if(_editRegion && _editRegion.showOnsets) {
                                    // detect if the mouse is over an onset
                                    _moveOnsetChannel = _editRegion.mouseOverChannel(_mouseY);
                                    if(_editRegion.getOnset(viewOffset + _mouseX * samplesPerPixel -
                                                            _editRegion.offset,
                                                            mouseOverThreshold * samplesPerPixel,
                                                            _moveOnsetFrameSrc,
                                                            _moveOnsetIndex,
                                                            _moveOnsetChannel)) {
                                        _moveOnsetFrameDest = _moveOnsetFrameSrc;
                                        _setAction(Action.moveOnset);
                                        newAction = true;
                                    }
                                }

                                if(!newAction) {
                                    if(_editRegion.boundingBox.containsPoint(_mouseX, _mouseY)) {
                                        if(_editRegion.subregionSelected && shiftPressed) {
                                            // append to the selected subregion
                                            onSelectSubregion();
                                            _setAction(Action.selectSubregion);
                                            newAction = true;
                                        }
                                        else {
                                            // move the edit point and start selecting a subregion
                                            _editRegion.subregionStartFrame =
                                                _editRegion.subregionEndFrame =
                                                _editRegion.editPointOffset =
                                                cast(nframes_t)(_mouseX * samplesPerPixel) + viewOffset -
                                                _editRegion.offset;
                                            _setAction(Action.selectSubregion);
                                            newAction = true;
                                        }
                                    }
                                }
                                break;

                            default:
                                break;
                        }

                        if(!newAction && _mode == Mode.arrange) {
                            _selectMouseX = _mouseX;
                            _selectMouseY = _mouseY;
                            _setAction(Action.selectBox);
                        }
                    }

                    redraw();
                }
            }
            else if(event.type == EventType.BUTTON_PRESS && event.button.button == rightButton) {
                auto buttonEvent = event.button;

                switch(_mode) {
                    case Mode.arrange:
                        if(_arrangeMenu is null) {
                            _createArrangeMenu();
                        }
                        _arrangeMenu.popup(buttonEvent.button, buttonEvent.time);
                        _arrangeMenu.showAll();
                        break;

                    case Mode.editRegion:
                        if(_editRegionMenu is null) {
                            _createEditRegionMenu();
                        }

                        _showOnsetsMenuItem.setActive(_editRegion.showOnsets);

                        _onsetDetectionMenuItem.setSensitive(_editRegion.showOnsets);

                        _linkChannelsMenuItem.setSensitive(_editRegion.nChannels > 1 &&
                                                           _editRegion.showOnsets);
                        _linkChannelsMenuItem.setActive(_editRegion.linkChannels);

                        _stretchSelectionMenuItem.setSensitive(_editRegion.subregionSelected);

                        _editRegionMenu.popup(buttonEvent.button, buttonEvent.time);
                        _editRegionMenu.showAll();
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == leftButton) {
                switch(_action) {
                    // reset the cursor if necessary
                    case Action.selectRegion:
                        _setAction(Action.none);
                        redraw();
                        break;

                    case Action.shrinkRegionStart:
                    case Action.shrinkRegionEnd:
                        _setAction(Action.none);
                        appendArrangeState(currentArrangeState());
                        break;

                    // select a subregion
                    case Action.selectSubregion:
                        _editRegion.subregionSelected =
                            !(_editRegion.subregionStartFrame == _editRegion.subregionEndFrame);

                        _editRegion.appendEditState(_editRegion.currentEditState(false));

                        _setAction(Action.none);
                        redraw();
                        break;

                    // select all regions within the selection box drawn with the mouse
                    case Action.selectBox:
                        if(_mode == Mode.arrange) {
                            BoundingBox selectBox = BoundingBox(_selectMouseX, _selectMouseY, _mouseX, _mouseY);
                            bool regionFound;
                            foreach(regionView; _regionViews) {
                                if(selectBox.intersect(regionView.boundingBox) && !regionView.selected) {
                                    regionFound = true;
                                    regionView.selected = true;
                                    _selectedRegionsApp.put(regionView);
                                }
                            }
                            _computeEarliestSelectedRegion();

                            if(regionFound) {
                                appendArrangeState(currentArrangeState());
                            }
                        }
                        _setAction(Action.none);
                        redraw();
                        break;

                    // move a region by setting its global frame offset
                    case Action.moveRegion:
                        _setAction(Action.none);
                        bool regionModified;
                        foreach(regionView; _selectedRegions) {
                            if(regionView.offset != regionView.selectedOffset) {
                                regionModified = true;
                            }
                            regionView.offset = regionView.selectedOffset;
                            _mixer.resizeIfNecessary(regionView.offset + regionView.nframes);
                        }

                        if(regionModified) {
                            appendArrangeState(currentArrangeState());
                        }

                        redraw();
                        break;

                    // stop moving a marker
                    case Action.moveMarker:
                        _setAction(Action.none);
                        break;

                    // stretch the audio inside a region
                    case Action.moveOnset:
                        immutable nframes_t onsetFrameStart =
                            _editRegion.getPrevOnset(_moveOnsetIndex, _moveOnsetChannel);
                        immutable nframes_t onsetFrameEnd =
                            _editRegion.getNextOnset(_moveOnsetIndex, _moveOnsetChannel);

                        OnsetSequence onsets = _editRegion.linkChannels ?
                            _editRegion._onsetsLinked : _editRegion._onsets[_moveOnsetChannel];
                        if(onsets[_moveOnsetIndex].leftSource && onsets[_moveOnsetIndex].rightSource) {
                            _editRegion.region.stretchThreePoint(onsetFrameStart,
                                                                 _moveOnsetFrameSrc,
                                                                 _moveOnsetFrameDest,
                                                                 onsetFrameEnd,
                                                                 _editRegion.linkChannels,
                                                                 _moveOnsetChannel,
                                                                 onsets[_moveOnsetIndex].leftSource,
                                                                 onsets[_moveOnsetIndex].rightSource);
                        }
                        else {
                            _editRegion.region.stretchThreePoint(onsetFrameStart,
                                                                 _moveOnsetFrameSrc,
                                                                 _moveOnsetFrameDest,
                                                                 onsetFrameEnd,
                                                                 _editRegion.linkChannels,
                                                                 _moveOnsetChannel);
                        }

                        if(_moveOnsetFrameDest == onsetFrameStart) {
                            if(_moveOnsetIndex > 0) {
                                onsets[_moveOnsetIndex - 1].rightSource = onsets[_moveOnsetIndex].rightSource;
                            }
                            onsets.remove(_moveOnsetIndex, _moveOnsetIndex + 1);
                        }
                        else if(_moveOnsetFrameDest == onsetFrameEnd) {
                            if(_moveOnsetIndex + 1 < onsets.length) {
                                onsets[_moveOnsetIndex + 1].leftSource = onsets[_moveOnsetIndex].leftSource;
                            }
                            onsets.remove(_moveOnsetIndex, _moveOnsetIndex + 1);
                        }
                        else {
                            onsets.replace([Onset(_moveOnsetFrameDest,
                                                  onsets[_moveOnsetIndex].leftSource,
                                                  onsets[_moveOnsetIndex].rightSource)],
                                           _moveOnsetIndex, _moveOnsetIndex + 1);
                        }

                        _editRegion.appendEditState(_editRegion.currentEditState(true,
                                                                                 true,
                                                                                 _editRegion.linkChannels,
                                                                                 _moveOnsetChannel));

                        redraw();
                        _setAction(Action.none);
                        break;

                    case Action.moveTransport:
                        _setAction(Action.none);
                        _mixer.transportOffset = viewOffset + (clamp(_mouseX, 0, viewWidthPixels) * samplesPerPixel);
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        bool onScroll(Event event, Widget widget) {
            if(event.type == EventType.SCROLL) {
                GdkModifierType state;
                event.getState(state);
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;

                ScrollDirection direction;
                event.getScrollDirection(direction);
                switch(direction) {
                    case ScrollDirection.LEFT:
                        if(controlPressed) {
                            _zoomOut();
                        }
                        else {
                            if(_hScroll.stepSamples <= viewOffset) {
                                _viewOffset -= _hScroll.stepSamples;
                            }
                            else {
                                _viewOffset = viewMinSamples;
                            }
                            _hScroll.update();
                            if(_action == Action.centerView ||
                               _action == Action.centerViewStart ||
                               _action == Action.centerViewEnd) {
                                _setAction(Action.none);
                            }
                            redraw();
                        }
                        break;

                    case ScrollDirection.RIGHT:
                        if(controlPressed) {
                            _zoomIn();
                        }
                        else {
                            if(_hScroll.stepSamples + viewOffset <= _mixer.lastFrame) {
                                _viewOffset += _hScroll.stepSamples;
                            }
                            else {
                                _viewOffset = _mixer.lastFrame;
                            }
                            _hScroll.update();
                            if(_action == Action.centerView ||
                               _action == Action.centerViewStart ||
                               _action == Action.centerViewEnd) {
                                _setAction(Action.none);
                            }
                            redraw();
                        }
                        break;

                    case ScrollDirection.UP:
                        if(controlPressed) {
                            _zoomOutVertical();
                        }
                        else {
                            _vScroll.pixelsOffset = _vScroll.pixelsOffset - _vScroll.stepIncrement;
                            _verticalPixelsOffset = _vScroll.pixelsOffset;
                            redraw();
                        }
                        break;

                    case ScrollDirection.DOWN:
                        if(controlPressed) {
                            _zoomInVertical();
                        }
                        else {
                            _vScroll.pixelsOffset = _vScroll.pixelsOffset + _vScroll.stepIncrement;
                            _verticalPixelsOffset = cast(pixels_t)(_vScroll.pixelsOffset);
                            redraw();
                        }
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        bool onKeyPress(Event event, Widget widget) {
            if(event.type == EventType.KEY_PRESS) {
                switch(_action) {
                    // insert a new marker
                    case Action.createMarker:
                        _setAction(Action.none);
                        wchar keyval = cast(wchar)(Keymap.keyvalToUnicode(event.key.keyval));
                        if(isAlpha(keyval) || isNumber(keyval)) {
                            _markers[event.key.keyval] = Marker(_mixer.transportOffset, to!string(keyval));
                            redraw();
                        }
                        return false;

                    case Action.jumpToMarker:
                        _setAction(Action.none);
                        try {
                            _mixer.transportOffset = _markers[event.key.keyval].offset;
                            redraw();
                        }
                        catch(RangeError) {
                        }
                        return false;

                    default:
                        break;
                }

                GdkModifierType state;
                event.getState(state);
                auto shiftPressed = state & GdkModifierType.SHIFT_MASK;
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;

                switch(event.key.keyval) {
                    case GdkKeysyms.GDK_space:
                        if(shiftPressed) {
                            if(_mode == Mode.editRegion && _editRegion.subregionSelected) {
                                // loop the selected subregion
                                _mixer.transportOffset =
                                    _editRegion.subregionStartFrame + _editRegion.offset;
                                _mixer.enableLoop(_editRegion.subregionStartFrame + _editRegion.offset,
                                                  _editRegion.subregionEndFrame + _editRegion.offset);
                                _mixer.play();
                            }
                        }
                        else {
                            // toggle play/pause for the mixer
                            if(_mixer.playing) {
                                _mixer.disableLoop();
                                _mixer.pause();
                            }
                            else {
                                if(_mode == Mode.editRegion) {
                                    _mixer.transportOffset = _editRegion.editPointOffset + _editRegion.offset;
                                }
                                _mixer.play();
                            }
                        }
                        redraw();
                        break;

                    case GdkKeysyms.GDK_equal:
                        _zoomIn();
                        break;

                    case GdkKeysyms.GDK_minus:
                        _zoomOut();
                        break;

                    case GdkKeysyms.GDK_Return:
                        // move the transport to the last marker
                        Marker* lastMarker;
                        foreach(ref marker; _markers) {
                            if(!lastMarker ||
                               (marker.offset > lastMarker.offset && marker.offset < _mixer.transportOffset)) {
                                lastMarker = &marker;
                            }
                        }
                        _mixer.transportOffset = lastMarker ? lastMarker.offset : 0;
                        redraw();
                        break;

                    // Shift + Alt + <
                    case GdkKeysyms.GDK_macron:
                        // move the transport and view to the beginning of the project
                        _mixer.transportOffset = 0;
                        _viewOffset = viewMinSamples;
                        redraw();
                        break;

                    // Shift + Alt + >
                    case GdkKeysyms.GDK_breve:
                        // move the transport to end of the project and center the view on the transport
                        _mixer.transportOffset = _mixer.lastFrame;
                        if(viewMaxSamples >= (viewWidthSamples / 2) * 3) {
                            _viewOffset = viewMaxSamples - (viewWidthSamples / 2) * 3;
                        }
                        redraw();
                        break;

                    // Alt + f
                    case GdkKeysyms.GDK_function:
                        // seek the transport forward (large increment)
                        _mixer.transportOffset = min(_mixer.lastFrame,
                                                     _mixer.transportOffset + largeSeekIncrement);
                        redraw();
                        break;

                    // Alt + b
                    case GdkKeysyms.GDK_integral:
                        // seek the transport backward (large increment)
                        _mixer.transportOffset = _mixer.transportOffset > largeSeekIncrement ?
                            _mixer.transportOffset - largeSeekIncrement : 0;
                        redraw();
                        break;

                    case GdkKeysyms.GDK_BackSpace:
                        if(_mode == Mode.editRegion && _editRegion.subregionSelected) {
                            // remove the selected subregion
                            _editRegion.region.removeLocal(_editRegion.subregionStartFrame,
                                                            _editRegion.subregionEndFrame);

                            _editRegion.subregionSelected = false;

                            if(_editRegion.showOnsets) {
                                _editRegion.computeOnsets();
                            }
                            _editRegion.appendEditState(_editRegion.currentEditState(true));

                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_a:
                        if(controlPressed) {
                            // move the transport to the minimum offset of all selected regions
                            if(_earliestSelectedRegion !is null) {
                                _mixer.transportOffset = _earliestSelectedRegion.offset;
                                redraw();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_b:
                        if(controlPressed) {
                            // seek the transport backward (small increment)
                            _mixer.transportOffset = _mixer.transportOffset > smallSeekIncrement ?
                                _mixer.transportOffset - smallSeekIncrement : 0;
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_c:
                        if(controlPressed && _mode == Mode.editRegion && _editRegion.subregionSelected) {
                            // save the selected subregion
                            _copyBuffer = _editRegion.region.getSliceLocal(_editRegion.subregionStartFrame,
                                                                           _editRegion.subregionEndFrame);
                        }
                        break;

                    case GdkKeysyms.GDK_e:
                        if(controlPressed) {
                            // move the transport to the maximum length of all selected regions
                            nframes_t maxOffset = 0;
                            bool foundRegion;
                            foreach(regionView; _selectedRegions) {
                                if(regionView.offset + regionView.nframes > maxOffset) {
                                    maxOffset = regionView.offset + regionView.nframes;
                                    foundRegion = true;
                                }
                            }
                            if(foundRegion) {
                                _mixer.transportOffset = maxOffset;
                                redraw();
                            }
                        }
                        else {
                            // toggle edit mode
                            _setMode(_mode == Mode.editRegion ? Mode.arrange : Mode.editRegion);
                        }
                        break;

                    case GdkKeysyms.GDK_f:
                        if(controlPressed) {
                            // seek the transport forward (small increment)
                            _mixer.transportOffset = min(_mixer.lastFrame,
                                                         _mixer.transportOffset + smallSeekIncrement);
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_h:
                        if(controlPressed) {
                            if(_mode == Mode.arrange) {
                                if(_selectedRegions.length == _regionViews.length) {
                                    // deselect all regions
                                    foreach(regionView; _selectedRegions) {
                                        regionView.selected = false;
                                    }
                                    _earliestSelectedRegion = null;
                                    _selectedRegionsApp.clear();
                                }
                                else {
                                    // select all regions
                                    _selectedRegionsApp.clear();
                                    foreach(regionView; _regionViews) {
                                        regionView.selected = true;
                                        _selectedRegionsApp.put(regionView);
                                    }
                                    _computeEarliestSelectedRegion();
                                }
                            }
                            else if(_mode == Mode.editRegion && _editRegion !is null) {
                                if(_editRegion.subregionSelected &&
                                   _editRegion.subregionStartFrame == 0 &&
                                   _editRegion.subregionEndFrame == _editRegion.nframes) {
                                    // deselect the entire region
                                    _editRegion.subregionSelected = false;
                                }
                                else {
                                    // select the entire region
                                    _editRegion.subregionSelected = true;
                                    _editRegion.subregionStartFrame = 0;
                                    _editRegion.subregionEndFrame = _editRegion.nframes;
                                }
                            }
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_j:
                        // if control is pressed, jump to a marker that is about to be specified
                        if(controlPressed) {
                            _setAction(Action.jumpToMarker);
                        }
                        break;

                    case GdkKeysyms.GDK_l:
                        // center the view on the transport, emacs-style
                        if(_action == Action.centerViewStart) {
                            _viewOffset = _mixer.transportOffset;
                            _setAction(Action.centerViewEnd);
                        }
                        else if(_action == Action.centerViewEnd) {
                            if(_mixer.transportOffset > viewWidthSamples) {
                                _viewOffset = _mixer.transportOffset - viewWidthSamples;
                            }
                            else {
                                _viewOffset = viewMinSamples;
                            }
                            _setAction(Action.centerView);
                        }
                        else {
                            if(_mixer.transportOffset < viewWidthSamples / 2) {
                                _viewOffset = viewMinSamples;
                            }
                            else if(_mixer.transportOffset > viewMaxSamples - viewWidthSamples / 2) {
                                _viewOffset = viewMaxSamples;
                            }
                            else {
                                _viewOffset = _mixer.transportOffset - viewWidthSamples / 2;
                            }
                            _setAction(Action.centerViewStart);
                        }
                        _centeredView = true;
                        redraw();
                        _hScroll.update();
                        break;

                    case GdkKeysyms.GDK_m:
                        // if control is pressed, create a marker at the current transport position
                        if(controlPressed) {
                            _setAction(Action.createMarker);
                        }
                        // otherwise, mute selected regions
                        else if(_mode == Mode.arrange) {
                            foreach(regionView; _selectedRegions) {
                                regionView.region.mute = !regionView.region.mute;
                            }
                            redraw();
                        }
                        else if(_mode == Mode.editRegion) {
                            _editRegion.region.mute = !_editRegion.region.mute;
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_v:
                        if(controlPressed && _mode == Mode.editRegion && _copyBuffer.length > 0) {
                            // paste the copy buffer
                            _editRegion.region.insertLocal(_copyBuffer,
                                                           _editRegion.editPointOffset);

                            // select the pasted region
                            _editRegion.subregionSelected = true;
                            _editRegion.subregionStartFrame = _editRegion.editPointOffset;
                            _editRegion.subregionEndFrame = _editRegion.editPointOffset +
                                cast(nframes_t)(_copyBuffer.length / _editRegion.nChannels);

                            if(_editRegion.showOnsets) {
                                _editRegion.computeOnsets();
                            }
                            _editRegion.appendEditState(_editRegion.currentEditState(true));

                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_x:
                        if(controlPressed && _mode == Mode.editRegion && _editRegion.subregionSelected) {
                            // copy the selected subregion, then remove it
                            _copyBuffer = _editRegion.region.getSliceLocal(_editRegion.subregionStartFrame,
                                                                           _editRegion.subregionEndFrame);
                            _editRegion.region.removeLocal(_editRegion.subregionStartFrame,
                                                           _editRegion.subregionEndFrame);

                            _editRegion.subregionSelected = false;

                            if(_editRegion.showOnsets) {
                                _editRegion.computeOnsets();
                            }
                            _editRegion.appendEditState(_editRegion.currentEditState(true));

                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_y:
                        if(_mode == Mode.arrange) {
                            redoArrange();
                            redraw();
                        }
                        else if(_mode == Mode.editRegion) {
                            // redo the last edit
                            _editRegion.redoEdit();
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_z:
                        if(_mode == Mode.arrange) {
                            undoArrange();
                            redraw();
                        }
                        else if(_mode == Mode.editRegion) {
                            // undo the last edit
                            _editRegion.undoEdit();
                            redraw();
                        }
                        break;

                    default:
                        break;
                }
            }
            return false;
        }
    }

    ArrangeState currentArrangeState() {
        Appender!(RegionViewState[]) regionViewStates;
        foreach(regionView; _selectedRegions) {
            regionViewStates.put(RegionViewState(regionView,
                                                 regionView.offset,
                                                 regionView.sliceStartFrame,
                                                 regionView.sliceEndFrame));
        }
        return ArrangeState(regionViewStates.data.dup);
    }

    void updateCurrentArrangeState() {
        // clear the selection flag for all currently selected regions
        foreach(regionView; _selectedRegions) {
            regionView.selected = false;
        }
        _selectedRegionsApp.clear();

        foreach(regionViewState; _arrangeStateHistory.currentState.selectedRegionStates) {
            regionViewState.regionView.selected = true;
            regionViewState.regionView.offset = regionViewState.offset;
            regionViewState.regionView.sliceStartFrame = regionViewState.sliceStartFrame;
            regionViewState.regionView.sliceEndFrame = regionViewState.sliceEndFrame;
            _selectedRegionsApp.put(regionViewState.regionView);
            _computeEarliestSelectedRegion();
        }
    }

    void appendArrangeState(ArrangeState arrangeState) {
        _arrangeStateHistory.appendState(arrangeState);
    }

    void undoArrange() {
        if(_arrangeStateHistory.queryUndo()) {
            _arrangeStateHistory.undo();
            updateCurrentArrangeState();
        }
    }
    void redoArrange() {
        if(_arrangeStateHistory.queryRedo()) {
            _arrangeStateHistory.redo();
            updateCurrentArrangeState();
        }
    }

    struct RegionViewState {
        RegionView regionView;
        nframes_t offset;
        nframes_t sliceStartFrame;
        nframes_t sliceEndFrame;
    }
    struct ArrangeState {
        RegionViewState[] selectedRegionStates;
    }
    StateHistory!ArrangeState _arrangeStateHistory;

    Window _parentWindow;

    Mixer _mixer;
    TrackView[] _trackViews;
    RegionView[] _regionViews;

    TrackView _selectedTrack;
    Appender!(RegionView[]) _selectedRegionsApp;
    @property RegionView[] _selectedRegions() { return _selectedRegionsApp.data; }
    RegionView _earliestSelectedRegion;
    RegionView _shrinkRegion;
    RegionView _editRegion;

    Marker[uint] _markers;
    Marker* _moveMarker;

    bool _mixerPlaying;
    Direction _subregionDirection;

    PgLayout _trackLabelLayout;
    PgLayout _trackButtonLayout;
    PgLayout _regionHeaderLabelLayout;
    PgLayout _markerLabelLayout;
    PgLayout _timeStripMarkerLayout;
    float _timeStripScaleFactor = 1;

    nframes_t _samplesPerPixel;
    nframes_t _viewOffset;

    ChannelStrip _channelStrip;

    TrackStubs _trackStubs;
    pixels_t _trackStubWidth;
    TrackView.TrackButton _trackButtonPressed;

    Canvas _canvas;
    ArrangeHScroll _hScroll;
    ArrangeVScroll _vScroll;
    Timeout _refreshTimeout;

    Menu _arrangeMenu;
    FileChooserDialog _importFileChooser;

    Menu _trackMenu;
    Menu _editRegionMenu;
    MenuItem _stretchSelectionMenuItem;
    CheckMenuItem _showOnsetsMenuItem;
    MenuItem _onsetDetectionMenuItem;
    CheckMenuItem _linkChannelsMenuItem;

    pixels_t _viewWidthPixels;
    pixels_t _viewHeightPixels;
    pixels_t _transportPixelsOffset;
    pixels_t _verticalPixelsOffset;
    float _verticalScaleFactor = 1;

    Mode _mode;
    Action _action;
    bool _centeredView;
    pixels_t _mouseX;
    pixels_t _mouseY;
    pixels_t _selectMouseX;
    pixels_t _selectMouseY;

    size_t _moveOnsetIndex;
    channels_t _moveOnsetChannel;
    nframes_t _moveOnsetFrameSrc; // locally indexed for region
    nframes_t _moveOnsetFrameDest; // locally indexed for region

    AudioSequence.PieceTable _copyBuffer;
}

class AppMainWindow : MainWindow {
public:
    this(string title, Mixer mixer) {
        _mixer = mixer;
        super(title);
    }

protected:
    override bool windowDelete(Event event, Widget widget) {
        _cleanupMixer();
        return super.windowDelete(event, widget);
    }

    override bool exit(int code, bool force) {
        _cleanupMixer();
        return super.exit(code, force);
    }

private:
    void _cleanupMixer() {
        _mixer.destroy();
    }

    Mixer _mixer;
}

void main(string[] args) {
    string appName = "dseq";

    string[] availableAudioDrivers;
    version(HAVE_JACK) {
        availableAudioDrivers ~= "JACK";
    }
    version(HAVE_COREAUDIO) {
        availableAudioDrivers ~= "CoreAudio";
    }
    assert(availableAudioDrivers.length > 0);
    string audioDriver;

    GetoptResult opts;
    try {
        opts = getopt(args,
                      "driver|d", "Available audio drivers: " ~ reduce!((string x, y) => x ~ ", " ~ y)
                      (availableAudioDrivers[0], availableAudioDrivers[1 .. $]), &audioDriver);
    }
    catch(Exception e) {
        writeln("Error: " ~ e.msg);
        return;
    }

    if(opts.helpWanted) {
        defaultGetoptPrinter(appName ~ " command line options:", opts.options);
        return;
    }

    try {
        Mixer mixer;
        switch(audioDriver.toUpper()) {
            version(HAVE_JACK) {
                case "JACK":
                    mixer = new JackMixer(appName);
                    break;
            }

            version(HAVE_COREAUDIO) {
                case "COREAUDIO":
                    mixer = new CoreAudioMixer(appName);
                    break;
            }

            default:
                version(OSX) {
                    version(HAVE_COREAUDIO) {
                        mixer = new CoreAudioMixer(appName);
                    }
                    else {
                        mixer = new JackMixer(appName);
                    }
                }
                else {
                    mixer = new JackMixer(appName);
                }
        }
        assert(mixer !is null);

        Main.init(args);
        AppMainWindow mainWindow = new AppMainWindow(appName, mixer);
        mainWindow.setDefaultSize(960, 600);

        ArrangeView arrangeView = new ArrangeView(appName, mainWindow, mixer);
        mainWindow.add(arrangeView);
        mainWindow.showAll();

        if(!args[1 .. $].empty) {
            arrangeView.loadRegionsFromFiles(args[1 .. $]);
        }
        Main.run();
    }
    catch(AudioError e) {
        writeln("Fatal audio error: ", e.msg);
        return;
    }
}
