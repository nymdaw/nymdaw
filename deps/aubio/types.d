/*
  Copyright (C) 2003-2013 Paul Brossier <piem@aubio.org>

  This file is part of aubio.

  aubio is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  aubio is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with aubio.  If not, see <http://www.gnu.org/licenses/>.

*/

/** \file
 
  Definition of data types used in aubio
 
*/

extern(C) @nogc nothrow
{

/** defined to 1 if aubio is compiled in double precision */
enum HAVE_AUBIO_DOUBLE = 0;

/** short sample format (32 or 64 bits) */
static if(!HAVE_AUBIO_DOUBLE) {
    alias smpl_t = float;
    /** print format for sample in single precision */
    enum AUBIO_SMPL_FMT = "%f";
}
else {
    alias smpl_t = double;
    /** print format for double in single precision */
    enum AUBIO_SMPL_FMT = "%lf";
    /** long sample format (64 bits or more) */
}
static if(!HAVE_AUBIO_DOUBLE) {
    alias lsmp_t = double;
    /** print format for sample in double precision */
    enum AUBIO_LSMP_FMT = "%lf";
}
else {
    alias lsmp_t = real;
    /** print format for double in double precision */
    enum AUBIO_LSMP_FMT = "%Lf";
}
/** unsigned integer */
alias uint_t = uint;
/** signed integer */
alias sint_t = int;
/** character */
alias char_t = char;

}
