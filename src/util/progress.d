module util.progress;

public import std.concurrency;
public import std.parallelism;
private import std.traits;
private import std.typetuple;

private import core.time;

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

    alias Callback = bool delegate(Stage stage, double stageFraction);

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

struct ProgressTaskCallback(ProgressState) if(__traits(isSame, TemplateOf!ProgressState, .ProgressState)) {
    this(Tid callbackTid) {
        this.callbackTid = callbackTid;
    }

    @disable this();

    @property ProgressState.Callback callback() {
        return delegate(ProgressState.Stage stage, double stageFraction) {
            if(!registeredThread) {
                register(ProgressState.mangleof, thisTid);
            }

            send(callbackTid, ProgressState(stage, stageFraction));

            if(!cancelled) {
                receiveTimeout(0.msecs, (bool cancel) { cancelled = cancel; });
            }
            return !cancelled;
        };
    }
    alias callback this;

    Tid callbackTid;
    bool registeredThread;
    bool cancelled;
}
