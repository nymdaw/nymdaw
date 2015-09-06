module util.statehistory;

private import std.container.dlist;
private import std.range;

private import core.sync.mutex;
private import core.atomic;

/// Generic class that implements undo/redo history via a "state" template parameter.
/// Undo/redo operations are thread-safe.
/// Updating the current state reference is guaranteed to be atomic.
final class StateHistory(T) {
public:
    /// The state history should always contain at least one state
    this(T initialState) {
        _mutex = new Mutex;

        _undoHistory.insertFront(initialState);
        _updateCurrentState();
    }

    /// Returns: `true` if and only if an undo operation is currently possible
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

    /// Returns: `true` if and only if a redo operation is currently possible
    bool queryRedo() {
        synchronized(_mutex) {
            auto redoRange = _redoHistory[];
            return !redoRange.empty;
        }
    }

    /// Undo the last operation, if possible.
    /// This function will clear the redo history if the user subsequently appends a new operation.
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

    /// Redo the last operation, if possible.
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

    /// Execute this function when the user effects a new undo-able state.
    /// This function will clear the current redo history.
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

    /// Returns: The current user-modifiable state
    @property ref T currentState() @nogc nothrow {
        return _currentState.state;
    }

    /// Returns: A range of state objects comprising the undo history.
    /// The back element is the most recently appended operation.
    @property auto undoHistory() {
        synchronized(_mutex) {
            return _undoHistory[];
        }
    }

    /// Returns: A range of state objects comprising the redo history.
    /// The front element is the next operation to redo.
    @property auto redoHistory() {
        synchronized(_mutex) {
            return _redoHistory[];
        }
    }

private:
    /// Atomically update the current state from the back of the undo history
    void _updateCurrentState() {
        atomicStore(*cast(shared)(&_currentState), cast(shared)(new CurrentState(_undoHistory.back)));
    }

    /// Convenience class to wrap the state into a reference object
    static final class CurrentState {
        this(T state) {
            this.state = state;
        }

        T state;
    }

    /// Reference to the current state of the undo/redo history
    CurrentState _currentState;

    Mutex _mutex;

    alias HistoryContainer = DList!T;
    HistoryContainer _undoHistory;
    HistoryContainer _redoHistory;

    bool _clearRedoHistory;
}
