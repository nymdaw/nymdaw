# dhippo
An audio editor/workstation hybrid implemented in the D programming language.

# Compiling on Linux (Ubuntu)

Install the D apt repository (as described at http://d-apt.sourceforge.net/):

    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
    sudo apt-get update && sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring && sudo apt-get update

Install the dependencies, then build via waf:

    sudo apt-get install dmd-bin libphobos2-dev libgtkd3-dev portaudio19-dev libjack-jackd2-dev libmpg123-dev libncurses-dev libsndfile-dev libsamplerate-dev librubberband-dev libaubio-dev
    git clone https://github.com/dhippo/dhippo
    cd dseq
    ./waf configure
    ./waf build
    ./build/dhippo
