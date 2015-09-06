module util.scopedarray;

private import std.conv;

private import core.memory;

/// Scoped container for array types.
/// Destroys and frees an array when it goes out of scope.
/// Also recursively destroys every dimension for multi-dimensional arrays.
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
