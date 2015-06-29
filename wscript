#!/usr/bin/env python

from waflib import Options
import sys, os

APPNAME = "dseq"
VERSION = "0.0.1"

top = "."
out = "build"

def options( ctx ):
    ctx.load( "compiler_d" )

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
    if opts.debug :
        ctx.env.append_value( "DFLAGS", ["-gc", "-debug"] )
    else:
        ctx.env.append_value( "DFLAGS", "-O2" )
    ctx.env.append_value( "DFLAGS", "-I/usr/local/include" )

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

    # Build the executable
    ctx.program( name = APPNAME,
                 target = APPNAME.lower(),
                 source = ctx.path.ant_glob( "src/**/*.d" ),
                 includes = [ "src", deps_dir ],
                 use = [ "jack", "dlang_jack",
                         "sndfile", "dlang_sndfile",
                         "samplerate", "dlang_samplerate" ] )
