// ----------------------------------------------------------------------------
//
//  Copyright (C) 2006-2012 Fons Adriaensen <fons@linuxaudio.org>
//    
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ----------------------------------------------------------------------------

module meters.resampler;

import std.math;
import core.sync.mutex;
import core.stdc.stdlib;
import core.stdc.stdio;
import core.stdc.string;

private uint gcd(uint a, uint b) @nogc nothrow {
    if(a == 0) return b;
    if(b == 0) return a;
    while(true) {
        if(a > b) {
            a = a % b;
            if(a == 0) return b;
            if(a == 1) return 1;
        }
        else {
            b = b % a;
            if(b == 0) return a;
            if(b == 1) return 1;
        }
    }    
}

private double sinc(double x) @nogc nothrow {
    x = fabs(x);
    if(x < 1e-6) return 1.0;
    x *= PI;
    return sin(x) / x;
}


private double wind(double x) @nogc nothrow {
    x = fabs (x);
    if(x >= 1.0) return 0.0f;
    x *= PI;
    return 0.384 + 0.500 * cos(x) + 0.116 * cos(2 * x);
}

private class ResamplerTable {
public:
    static void print_list() {
        ResamplerTable P;

        printf("Resampler table\n----\n");
        for(P = _list; P; P = P._next) {
            printf("refc = %3d   fr = %10.6lf  hl = %4d  np = %4d\n", P._refc, P._fr, P._hl, P._np);
        }
        printf("----\n\n");
    }

private:
    static this() {
        _mutex = new Mutex;
    }

    this(double fr, uint hl, uint np) {
        _fr = fr;
        _hl = hl;
        _np = np;

        uint i, j;
        double t;
        float* p;

        _ctab = new float[](hl * (np + 1));
        p = _ctab.ptr;
        for(j = 0; j <= np; j++) {
            t = cast(double)(j) / cast(double)(np);
            for(i = 0; i < hl; i++) {
                p [hl - i - 1] = cast(float)(fr * sinc(t * fr) * wind(t / hl));
                t += 1;
            }
            p += hl;
        }
    }

    ResamplerTable _next;
    uint _refc;
    float[] _ctab;
    double _fr;
    uint _hl;
    uint _np;

    static ResamplerTable createTable(double fr, uint hl, uint np) {
        ResamplerTable P;

        synchronized(_mutex) {
            P = _list;
            while(P) {
                if((fr >= P._fr * 0.999) && (fr <= P._fr * 1.001) && (hl == P._hl) && (np == P._np)) {
                    P._refc++;
                    return P;
                }
                P = P._next;
            }
            P = new ResamplerTable(fr, hl, np);
            P._refc = 1;
            P._next = _list;
            _list = P;
        }
        return P;
    }

    static void destroyTable(ResamplerTable T) {
        ResamplerTable P, Q;

        synchronized(_mutex) {
            if(T) {
                T._refc--;
                if(T._refc == 0) {
                    P = _list;
                    Q = null;
                    while(P) {
                        if(P == T) {
                            if(Q) Q._next = T._next;
                            else _list = T._next;
                            break;
                        }
                        Q = P;
                        P = P._next;
                    }
                    T.destroy();
                }
            }
        }
    }

    static ResamplerTable _list;

    static Mutex _mutex;
}

class Resampler {
public:
    this() {
        reset();
    }

    int setup(uint fs_inp,
              uint fs_out,
              int nchan,
              uint hlen) {
        if ((hlen < 8) || (hlen > 96)) return 1;
        return setup (fs_inp, fs_out, nchan, hlen, 1.0 - 2.6 / hlen);
    }

    int setup(uint fs_inp,
              uint fs_out,
              uint nchan,
              uint hlen,
              double frel) {
        uint g, h, k, n, s;
        double r;
        float[] B;
        ResamplerTable T;

        k = s = 0;
        if(fs_inp && fs_out && nchan)
        {
            r = cast(double)(fs_out) / cast(double)(fs_inp);
            g = gcd(fs_out, fs_inp);
            n = fs_out / g;
            s = fs_inp / g;
            if((16 * r >= 1) && (n <= 1000))
            {
                h = hlen;
                k = 250;
                if(r < 1) 
                {
                    frel *= r;
                    h = cast(uint)(ceil (h / r));
                    k = cast(uint)(ceil (k / r));
                }
                T = ResamplerTable.createTable(frel, h, n);
                B = new float[](nchan * (2 * h - 1 + k));
            }
        }
        clear();
        if(T)
        {
            _table = T;
            _buff = B.ptr;
            _nchan = nchan;
            _inmax = k;
            _pstep = s;
            return reset();
        }
        else return 1;
    }

    void clear() {
        ResamplerTable.destroyTable(_table);
        _buff.destroy();
        _buff = null;
        _table = null;
        _nchan = 0;
        _inmax = 0;
        _pstep = 0;
        reset();
    }

    int reset() @nogc nothrow {
        if(!_table) return 1;

        inp_count = 0;
        out_count = 0;
        inp_data = null;
        out_data = null;
        _index = 0;
        _nread = 0;
        _nzero = 0;
        _phase = 0; 
        if(_table) {
            _nread = 2 * _table._hl;
            return 0;
        }
        return 1;
    }

    int nchan() const @nogc nothrow { return _nchan; }

    int inpsize() const @nogc nothrow {
        if(!_table) return 0;
        return 2 * _table._hl;
    }

    double inpdist() const @nogc nothrow {
        if(!_table) return 0;
        return cast(int)(_table._hl + 1 - _nread) - cast(double)(_phase) / _table._np;
    }

    int process() @nogc nothrow {
        uint hl, ph, np, dp, index, nr, nz, i, n, c;
        float* p1, p2;

        if(!_table) return 1;

        hl = _table._hl;
        np = _table._np;
        dp = _pstep;
        index = _index;
        nr = _nread;
        ph = _phase;
        nz = _nzero;
        n = (2 * hl - nr) * _nchan;
        p1 = _buff + index * _nchan;
        p2 = p1 + n;

        while(out_count) {
            if(nr) {
                if(inp_count == 0) break;
                if(inp_data) {
                    for(c = 0; c < _nchan; c++) p2 [c] = inp_data [c];
                    inp_data += _nchan;
                    nz = 0;
                }
                else {
                    for(c = 0; c < _nchan; c++) p2 [c] = 0;
                    if(nz < 2 * hl) nz++;
                }
                nr--;
                p2 += _nchan;
                inp_count--;
            }
            else {
                if(out_data) {
                    if(nz < 2 * hl) {
                        float* c1 = _table._ctab.ptr + hl * ph;
                        float* c2 = _table._ctab.ptr + hl * (np - ph);
                        for(c = 0; c < _nchan; c++) {
                            float* q1 = p1 + c;
                            float* q2 = p2 + c;
                            float s = 1e-20f;
                            for (i = 0; i < hl; i++) {
                                q2 -= _nchan;
                                s += *q1 * c1 [i] + *q2 * c2 [i];
                                q1 += _nchan;
                            }
                            *out_data++ = s - 1e-20f;
                        }
                    }
                    else {
                        for(c = 0; c < _nchan; c++) *out_data++ = 0;
                    }
                }
                out_count--;

                ph += dp;
                if(ph >= np) {
                    nr = ph / np;
                    ph -= nr * np;
                    index += nr;
                    p1 += nr * _nchan;
                    if(index >= _inmax) {
                        n = (2 * hl - nr) * _nchan;
                        memcpy(_buff, p1, n * float.sizeof);
                        index = 0;
                        p1 = _buff;
                        p2 = p1 + n;
                    }
                }
            }
        }
        _index = index;
        _nread = nr;
        _phase = ph;
        _nzero = nz;

        return 0;
    }

    uint inp_count;
    uint out_count;
    float* inp_data;
    float* out_data;
    void* inp_list;
    void* out_list;

private:
    ResamplerTable _table;
    uint _nchan;
    uint _inmax;
    uint _index;
    uint _nread;
    uint _nzero;
    uint _phase;
    uint _pstep;
    float* _buff;
    void*[8] _dummy;
}
