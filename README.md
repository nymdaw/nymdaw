# dseq
experimental audio sequencer implemented in D

# Compiling on Linux

Install the D apt repository (as described at http://d-apt.sourceforge.net/):

    sudo wget http://master.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
    sudo apt-get update && sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring && sudo apt-get update

Install the dependencies and build via waf:

    sudo apt-get install dmd-bin libphobos2-dev libgtkd3-dev portaudio19-dev libjack-jackd2-dev libmpg123-dev libncurses-dev libsndfile-dev libsamplerate-dev librubberband-dev libaubio-dev
    git clone https://github.com/irrelevelephant/dseq
    cd dseq
    ./waf configure
    ./waf build
    ./build/dseq
