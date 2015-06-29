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

    # Find jack
    ctx.check_cfg( package = "jack",
                   args = [ "jack >= 0.120.0", "--cflags", "--libs" ],
                   uselib_store = "JACK",
                   mandatory = True )

    # Find libsndfile
    ctx.check_cfg( package = "sndfile",
                   args = [ "sndfile >= 1.0.18", "--cflags", "--libs" ],
                   uselib_store = "SNDFILE",
                   mandatory = True )

def build( ctx ):
    deps_dir = "deps"

    # Build JACK wrapper
    dlang_jack_dir = os.path.join( deps_dir, "jack" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_jack_dir, "**", "*.d" ) ),
               includes = deps_dir,
               target = "DLANG-JACK" )

    # Build libsndfile wrapper
    dlang_sndfile_dir = os.path.join( deps_dir, "sndfile" )
    ctx.stlib( source = ctx.path.ant_glob( os.path.join( dlang_sndfile_dir, "**", "*.d" ) ),
               includes = deps_dir,
               target = "DLANG-SNDFILE" )

    # Build the executable
    ctx.program( name = APPNAME,
                 target = APPNAME.lower(),
                 source = ctx.path.ant_glob( "src/**/*.d" ),
                 includes = [ "src", deps_dir ],
                 use = [ "JACK", "DLANG-JACK", "SNDFILE", "DLANG-SNDFILE" ] )
