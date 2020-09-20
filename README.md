# nymdaw
nymdaw is an audio editor/workstation hybrid implemented in the D programming language.
It supports editing audio in two modes: "arrange" and "edit". Arrange mode allows the user to move audio regions across time; this is the conventional mode of operation for most audio workstations. Edit mode allows the user to modify an individual region at the sample-level; some examples of edit operations include copy/cut/paste arbitrary sections of audio, time-stretch, and normalization.

Operations such as play/pause and copy/cut/paste work intuitively in both arrange and edit modes. Additionally, basic channel strips (including a gain fader and peak meters) are available, along with conventional track-wide operations such as mute/solo. The leftmost channel strip visible in the main window corresponds to the currently selected track, and the rightmost channel strip corresponds to the master stereo bus.

When in edit mode, nymdaw can detect the onsets (i.e., attacks) of the current region, with adjustable detection parameters. The user can then click and drag onsets to move them across time, and nymdaw will stretch the surrounding audio accordingly.

Audio regions can be copied in "hard" mode or "soft" mode. A hard copy makes an independent copy of the audio data for the copied regions. A soft copy keeps a link between the copied region and its source region; all edits made in one are reflected in the other. These links, along with full undo history information for each region, can be viewed in the "Sequence Browser" window.

# Implementation
The basic unit of audio in nymdaw is referred to as a "sequence". This is an implementation of the eponymous data structure described in-depth by Charles Crowley in "Data Structures For Text Sequences" (available at https://www.cs.unm.edu/~crowley/papers/sds/sds.html), specialized for digital audio instead of textual data. This data structure yields excellent performance when editing audio data, and also facilitates the undo/redo system.

Currently, nymdaw performs all operations in-memory. Since most modern machines have in excess of 4-8 GB of RAM, the need to stream audio from disk, especially for smaller projects, is almost completely mitigated. Import/export are currently supported via libsndfile; a native project format has not yet been implemented.

When the user imports an audio file, nymdaw first creates a new sequence from an in-memory copy of the file's raw audio data. Next, it will create a new track and region linked to that sequence. All edits made in edit mode to that region are stored in the audio sequence. Soft copies of that region (made in arrange mode) will be linked to the same sequence, whereas hard copies will clone the sequence.

Three audio backends are currently supported: JACK, PortAudio, and CoreAudio (OSX only).

Most of the UI rendering code makes heavy use of cairo. To render the waveforms, a multi-level cache is constructed, where each level bins a successively larger quantity of audio samples. This minimizes the amount of binning the rendering code has to do on-the-fly, and seems to provide acceptable levels of performance overall.

The application code is located in the "src" directory, and the D wrappers around the necessary 3rd-party libraries are located in the "deps" directory.
The application code is separated into "ui" and "audio" modules. The UI module depends on the audio module, but there is no UI dependency within the audio module itself. Various generic types are located in the "util" module, such as the generic sequence and state history classes.

# Compiling on Linux (Ubuntu 20.04)

Install the dependencies, then build via waf:

    sudo snap install dmd --classic
    sudo apt-get install libgtkd-3-dev libgtk-3-dev librsvg2-dev portaudio19-dev libsndfile-dev libsamplerate-dev librubberband-dev libaubio-dev libmpg123-dev
    export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig
    git clone https://github.com/nymdaw/nymdaw
    cd nymdaw
    ./waf configure
    ./waf build
    ./build/nymdaw

# Compiling on OSX

Install brew from https://brew.sh.

Install GTK (without X11, sourced from http://balintreczey.hu/blog/beautiful-wireshark-on-os-x-using-homebrew-and-gtk3quartz/):

    # install Homebrew, you will also need XCode with Command Line Tools installed
    ruby -e "$(curl -fsSL https://raw.github.com/Homebrew/homebrew/go/install)"
    # install packages we don't have to recompile to use Quartz
    brew install ccache d-bus fontconfig freetype gettext glib gmp icu4c libffi libpng libtasn1 libtiff pkg-config xz hicolor-icon-theme gsettings-desktop-schemas c-ares lua portaudio geoip gnutls libgcrypt atk pixman
    # install XQuartz from http://xquartz.macosforge.org
    # Well, some builds will need the header files/libs, but you don't have to re-login
    # and actually use XQuartz
    # this may be needed by gtk+3 install (at least on my system with a previous installation) brew link --overwrite gsettings-desktop-schemas
    # compile the rest of GTK+ 3 related libraries
    brew install --build-from-source at-spi2-core at-spi2-atk cairo harfbuzz pango gtk+3 gtk+ librsvg gnome-icon-theme --without-x --without-x11 --with-gtk+3

Install the nymdaw dependencies:

    brew install dmd libsndfile libsamplerate aubio mpg123
    brew install http://tuohela.net/irc/vamp-plugin-sdk.rb http://tuohela.net/irc/rubberband.rb

Build nymdaw:

    git clone https://github.com/nymdaw/nymdaw
    cd nymdaw
    ./waf configure
    ./waf build
    ./build/nymdaw
