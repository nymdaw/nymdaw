#!/usr/bin/env python

from waflib import Options
import sys, os

APPNAME = "dseq"
VERSION = "0.0.1"

top = "."
out = "build"

def options( ctx ):
    ctx.load( "compiler_d" )
    ctx.load( "compiler_c" )

    ctx.add_option( "--debug",
                    action = "store_true",
                    help = ( "disable optimizations and compile with debug symbols" ),
                    default = False,
                    dest = "debug" )

    ctx.add_option( "--release",
                    action = "store_true",
                    help = ( "enable optimizations and compile without debug symbols" ),
                    default = False,
                    dest = "release" )

def configure( ctx ):
    opts = Options.options

    ctx.load( "compiler_d" )
    ctx.load( "compiler_c" )
    if opts.debug :
        ctx.env.append_value( "DFLAGS", [ "-gc", "-debug" ] )
    else:
        ctx.env.append_value( "DFLAGS", [ "-O", "-release", "-inline", "-boundscheck=off" ] )

    # Check for jack
    ctx.check_cfg( package = "jack",
                   args = [ "jack >= 0.120.0", "--cflags", "--libs" ],
                   uselib_store = "jack",
                   mandatory = True )

    # Check for libsndfile
    ctx.check_cfg( package = "sndfile",
                   args = [ "sndfile >= 1.0.18", "--cflags", "--libs" ],
                   uselib_store = "sndfile",
                   mandatory = True )

    # Check for libsamplerate
    ctx.check_cfg( package = "samplerate",
                   args = [ "samplerate >= 0.1.0", "--cflags", "--libs" ],
                   uselib_store = "samplerate",
                   mandatory = True )

    # Check for rubberband
    ctx.check_cc( lib = "rubberband", use = "rubberband" )

    # Check for aubio
    ctx.check_cfg( package = "aubio",
                   args = [ "aubio >= 0.4.1", "--cflags", "--libs" ],
                   uselib_store = "aubio",
                   mandatory = True )

    # Check for GtkD
    ctx.check_cfg( package = "gtkd-3",
                   args = [ "gtkd-3 >= 3.1.3", "--cflags", "--libs" ],
                   uselib_store = "gtkd",
                   mandatory = True )

    # Configure GtkD on OSX
    if sys.platform == "darwin":
        # Try to fix the output from the gtkd-3 pkg-config entry on OSX
        ctx.env.LIB_gtkd = map(lambda x: x[2:], filter(lambda x: x[:2] == "-l", ctx.env.LIBPATH_gtkd))
        ctx.env.LIBPATH_gtkd = map(lambda x: x[2:], filter(lambda x: x[:2] == "-L", ctx.env.LIBPATH_gtkd))

        # Add flags for GTK-OSX
        home = os.getenv("HOME")
        ctx.env.LIBPATH_gtkd = [ home + "/gtk/inst/lib" ]
        ctx.env.append_value( "LIB_gtkd", [ "gtk-3", "gdk-3", "atk-1.0", "gio-2.0",
                                            "pangocairo-1.0", "gdk_pixbuf-2.0", "cairo-gobject",
                                            "pango-1.0", "cairo", "gobject-2.0", "glib-2.0" ] )

def build( ctx ):
    deps_dir = "deps"

    # Build JACK wrapper
    dlang_jack_dir = os.path.join( deps_dir, "jack" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_jack_dir, "**", "*.d" ) ),
               includes = deps_dir,
               target = "dlang_jack" )

    # Build libsndfile wrapper
    dlang_sndfile_dir = os.path.join( deps_dir, "sndfile" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_sndfile_dir, "**", "*.d" ) ),
               includes = deps_dir,
               target = "dlang_sndfile" )

    # Build libsamplerate wrapper
    dlang_samplerate_dir = os.path.join( deps_dir, "samplerate" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_samplerate_dir, "**", "*.d" ) ),
               includes = deps_dir,
               target = "dlang_samplerate" )

    # Build rubberband wrapper
    dlang_rubberband_dir = os.path.join( deps_dir, "rubberband" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_rubberband_dir, "**", "*.d" ) ),
               includes = deps_dir,
               target = "dlang_rubberband" )

    # Build aubio wrapper
    dlang_aubio_dir = os.path.join( deps_dir, "aubio" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_aubio_dir, "**", "*.d" ) ),
               includes = [ deps_dir, dlang_aubio_dir ],
               target = "dlang_aubio" )

    # Build the executable
    ctx.program( name = APPNAME,
                 target = APPNAME.lower(),
                 source = ctx.path.ant_glob( "src/**/*.d" ),
                 includes = [ "src", deps_dir ],
                 use = [ "jack", "dlang_jack",
                         "sndfile", "dlang_sndfile",
                         "samplerate", "dlang_samplerate",
                         "rubberband", "dlang_rubberband",
                         "aubio", "dlang_aubio",
                         "gtkd" ] )
