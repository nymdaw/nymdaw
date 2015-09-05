module ui.types;

private import std.algorithm;
private import std.traits;
private import std.uni;

alias pixels_t = int;

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

    Color opBinary(string op, T)(T rhs) if(isNumeric!T) {
        static if(op == "+" || op == "-" || op == "*" || op == "/") {
            return mixin("Color(r " ~ op ~ " rhs, g " ~ op ~ " rhs, b " ~ op ~ " rhs)");
        }
        else {
            static assert(0, "Operator " ~ op ~ " not implemented");
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
