# dhippo
dhippo is an audio editor/workstation hybrid implemented in the D programming language.
It supports editing audio in two modes: "arrange" and "edit". Arrange mode allows the user to move audio regions across time; this is the conventional mode of operation for most audio workstations. Edit mode allows the user to modify an individual region at the sample-level; some examples of edit operations include copy/cut/paste arbitrary sections of audio, time-stretch, and normalization.

Operations such as play/pause and copy/cut/paste work intuitively in both arrange and edit modes. Additionally, basic channel strips (including a gain fader and peak meters) are available, along with conventional track-wide operations such as mute/solo. The leftmost channel strip visible in the main window corresponds to the currently selected track, and the rightmost channel strip corresponds to the master stereo bus.

When in edit mode, dhippo can detect the onsets (i.e., attacks) of the current region, with adjustable detection parameters. The user can then click and drag onsets to move them across time, and dhippo will stretch the surrounding audio accordingly.

Audio regions can be copied in "hard" mode or "soft" mode. A hard copy makes an independent copy of the audio data for the copied regions. A soft copy keeps a link between the copied region and its source region; all edits made in one are reflected in the other. These links, along with full undo history information for each region, can be viewed in the "Sequence Browser" window.

# Implementation
The basic unit of audio in dhippo is referred to as a "sequence". This is an implementation of the eponymous data structure described in-depth by Charles Crowley in "Data Structures For Text Sequences" (available at https://www.cs.unm.edu/~crowley/papers/sds/sds.html), specialized for digital audio instead of textual data. This data structure yields excellent performance when editing audio data, and also facilitates the undo/redo system.

Currently, dhippo performs all operations in-memory. Since most modern machines have in excess of 4-8 GB of RAM, the need to stream audio from disk, especially for smaller projects, is almost completely mitigated. Import/export are currently supported via libsndfile; a native project format has not yet been implemented.

When the user imports an audio file, dhippo first creates a new sequence from an in-memory copy of the file's raw audio data. Next, it will create a new track and region linked to that sequence. All edits made in edit mode to that region are stored in the audio sequence. Soft copies of that region (made in arrange mode) will be linked to the same sequence, whereas hard copies will clone the sequence.

Three audio backends are currently supported: JACK, PortAudio, and CoreAudio (OSX only).

Most of the UI rendering code makes heavy use of cairo. To render the waveforms, a multi-level cache is constructed, where each level bins a successively larger quantity of audio samples. This minimizes the amount of binning the rendering code has to do on-the-fly, and seems to provide acceptable levels of performance overall.

The application code is located in the "src" directory, and the D wrappers around the necessary 3rd-party libraries are located in the "deps" directory.
The application code is separated into "ui" and "audio" modules. The UI module depends on the audio module, but there is no UI dependency within the audio module itself. Various generic types are located in the "util" module, such as the generic sequence and state history classes.

# Compiling on Linux (Ubuntu)

Install the D apt repository (as described at http://d-apt.sourceforge.net/):

    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
    sudo apt-get update && sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring && sudo apt-get update

Install the dependencies, then build via waf:

    sudo apt-get install dmd-bin libphobos2-dev libgtkd3-dev portaudio19-dev libsndfile-dev libsamplerate-dev librubberband-dev libaubio-dev
    git clone https://github.com/dhippo/dhippo
    cd dhippo
    ./waf configure
    ./waf build
    ./build/dhippo

# Compiling on OSX

Build and install Gtk-OSX following the guide here: https://wiki.gnome.org/Projects/GTK+/OSX/Building

Build and install DMD from http://dlang.org/download.html#dmd

Build and install libsndfile from http://www.mega-nerd.com/libsndfile/

Build and install libsamplerate from http://www.mega-nerd.com/libsndfile/

Build and install aubio from http://aubio.org/

Download rubberband from http://breakfastquay.com/rubberband/

Apply the macports patches from https://trac.macports.org/browser/trunk/dports/audio/rubberband/files/

      tar -jxf rubberband-1.8.1.tar.bz2
      cd rubberband-1.8.1
      curl https://trac.macports.org/export/139798/trunk/dports/audio/rubberband/files/patch-Accelerate.diff > patch-Accelerate.diff
      curl https://trac.macports.org/export/139798/trunk/dports/audio/rubberband/files/patch-Makefile.osx.diff > patch-Makefile.osx.diff
      cat patch-Accelerate.diff | patch -p0
      cat patch-Makefile.osx.diff | patch -p0
      ./configure
      make
      sudo make install

Build dhippo:
    git clone https://github.com/dhippo/dhippo
    cd dhippo
    ./waf configure
    ./waf build
    ./build/dhippo
