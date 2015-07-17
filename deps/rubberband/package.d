/* -*- c-basic-offset: 4 indent-tabs-mode: nil -*-  vi:set ts=8 sts=4 sw=4: */

/*
    Rubber Band Library
    An audio time-stretching and pitch-shifting library.
    Copyright 2007-2012 Particular Programs Ltd.

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License as
    published by the Free Software Foundation; either version 2 of the
    License, or (at your option) any later version.  See the file
    COPYING included with this distribution for more information.

    Alternatively, if you have a valid commercial licence for the
    Rubber Band Library obtained by agreement with the copyright
    holders, you may redistribute and/or modify it under the terms
    described in that licence.

    If you wish to distribute code using the Rubber Band Library
    under terms other than those of the GNU General Public License,
    you must obtain a valid commercial licence before doing so.
*/

module rubberband;

extern(C) @nogc nothrow
{

enum RUBBERBAND_VERSION = "1.8.1";
enum RUBBERBAND_API_MAJOR_VERSION = 2;
enum RUBBERBAND_API_MINOR_VERSION = 5;

/**
 * This is a C-linkage interface to the Rubber Band time stretcher.
 * 
 * This is a wrapper interface: the primary interface is in C++ and is
 * defined and documented in RubberBandStretcher.h.  The library
 * itself is implemented in C++, and requires C++ standard library
 * support even when using the C-linkage API.
 *
 * Please see RubberBandStretcher.h for documentation.
 *
 * If you are writing to the C++ API, do not include this header.
 */

enum RubberBandOption {

    RubberBandOptionProcessOffline       = 0x00000000,
    RubberBandOptionProcessRealTime      = 0x00000001,

    RubberBandOptionStretchElastic       = 0x00000000,
    RubberBandOptionStretchPrecise       = 0x00000010,
    
    RubberBandOptionTransientsCrisp      = 0x00000000,
    RubberBandOptionTransientsMixed      = 0x00000100,
    RubberBandOptionTransientsSmooth     = 0x00000200,

    RubberBandOptionDetectorCompound     = 0x00000000,
    RubberBandOptionDetectorPercussive   = 0x00000400,
    RubberBandOptionDetectorSoft         = 0x00000800,

    RubberBandOptionPhaseLaminar         = 0x00000000,
    RubberBandOptionPhaseIndependent     = 0x00002000,
    
    RubberBandOptionThreadingAuto        = 0x00000000,
    RubberBandOptionThreadingNever       = 0x00010000,
    RubberBandOptionThreadingAlways      = 0x00020000,

    RubberBandOptionWindowStandard       = 0x00000000,
    RubberBandOptionWindowShort          = 0x00100000,
    RubberBandOptionWindowLong           = 0x00200000,

    RubberBandOptionSmoothingOff         = 0x00000000,
    RubberBandOptionSmoothingOn          = 0x00800000,

    RubberBandOptionFormantShifted       = 0x00000000,
    RubberBandOptionFormantPreserved     = 0x01000000,

    RubberBandOptionPitchHighQuality     = 0x00000000,
    RubberBandOptionPitchHighSpeed       = 0x02000000,
    RubberBandOptionPitchHighConsistency = 0x04000000,

    RubberBandOptionChannelsApart        = 0x00000000,
    RubberBandOptionChannelsTogether     = 0x10000000,
};

alias RubberBandOptions = int;

struct RubberBandState_;
alias RubberBandState = RubberBandState_ *;

RubberBandState rubberband_new(uint sampleRate,
                                      uint channels,
                                      RubberBandOptions options,
                                      double initialTimeRatio,
                                      double initialPitchScale);

void rubberband_delete(RubberBandState);

void rubberband_reset(RubberBandState);

void rubberband_set_time_ratio(RubberBandState, double ratio);
void rubberband_set_pitch_scale(RubberBandState, double scale);

double rubberband_get_time_ratio(const(RubberBandState));
double rubberband_get_pitch_scale(const(RubberBandState));

uint rubberband_get_latency(const(RubberBandState));

void rubberband_set_transients_option(RubberBandState, RubberBandOptions options);
void rubberband_set_detector_option(RubberBandState, RubberBandOptions options);
void rubberband_set_phase_option(RubberBandState, RubberBandOptions options);
void rubberband_set_formant_option(RubberBandState, RubberBandOptions options);
void rubberband_set_pitch_option(RubberBandState, RubberBandOptions options);

void rubberband_set_expected_input_duration(RubberBandState, uint samples);

uint rubberband_get_samples_required(const(RubberBandState));

void rubberband_set_max_process_size(RubberBandState, uint samples);
void rubberband_set_key_frame_map(RubberBandState, uint keyframecount, uint *from, uint *to);

void rubberband_study(RubberBandState, const(float **)input, uint samples, int final_);
void rubberband_process(RubberBandState, const(float **)input, uint samples, int final_);

int rubberband_available(const(RubberBandState));
uint rubberband_retrieve(const(RubberBandState), const(float **)output, uint samples);

uint rubberband_get_channel_count(const(RubberBandState));

void rubberband_calculate_stretch(RubberBandState);

void rubberband_set_debug_level(RubberBandState, int level);
void rubberband_set_default_debug_level(int level);

}
