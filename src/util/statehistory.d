module util.statehistory;

private import std.container.dlist;
private import std.range;

private import core.sync.mutex;
private import core.atomic;

final class StateHistory(T) {
public:
    this(T initialState) {
        _mutex = new Mutex;

        _undoHistory.insertFront(initialState);
        _updateCurrentState();
    }

    // returns true if an undo operation is currently possible
    bool queryUndo() {
        synchronized(_mutex) {
            auto undoRange = _undoHistory[];
            if(!undoRange.empty) {
                // the undo history must always contain at least one element
                undoRange.popFront();
                return !undoRange.empty();
            }
            return false;
        }
    }

    // returns true if a redo operation is currently possible
    bool queryRedo() {
        synchronized(_mutex) {
            auto redoRange = _redoHistory[];
            return !redoRange.empty;
        }
    }

    // undo the last operation, if possible
    // this function will clear the redo history if the user subsequently appends a new operation
    void undo() {
        synchronized(_mutex) {
            auto operation = takeOne(retro(_undoHistory[]));
            // never remove the last element in the undo history
            if(!operation.empty) {
                auto newUndoHistory = _undoHistory[];
                newUndoHistory.popFront();
                if(!newUndoHistory.empty) {
                    _undoHistory.removeBack(1);
                    _redoHistory.insertFront(operation);
                    _clearRedoHistory = true;
                }
                _updateCurrentState();
            }
        }
    }

    // redo the last operation, if possible
    void redo() {
        synchronized(_mutex) {
            auto operation = takeOne(_redoHistory[]);
            if(!operation.empty) {
                _redoHistory.removeFront(1);
                _undoHistory.insertBack(operation);
                _updateCurrentState();
            }
        }
    }

    // execute this function when the user effects a new undo-able state
    void appendState(T t) {
        synchronized(_mutex) {
            _undoHistory.insertBack(t);

            if(_clearRedoHistory) {
                _clearRedoHistory = false;
                _redoHistory.clear();
            }

            _updateCurrentState();
        }
    }

    // returns the current user-modifiable state
    @property ref T currentState() @nogc nothrow {
        return _currentState.state;
    }

    @property auto undoHistory() {
        synchronized(_mutex) {
            return _undoHistory[];
        }
    }
    @property auto redoHistory() {
        synchronized(_mutex) {
            return _redoHistory[];
        }
    }

private:
    void _updateCurrentState() {
        atomicStore(*cast(shared)(&_currentState), cast(shared)(new CurrentState(_undoHistory.back)));
    }

    static final class CurrentState {
        this(T state) {
            this.state = state;
        }

        T state;
    }
    CurrentState _currentState;

    Mutex _mutex;

    alias HistoryContainer = DList!T;
    HistoryContainer _undoHistory;
    HistoryContainer _redoHistory;

    bool _clearRedoHistory;
}
