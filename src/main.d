module main;

private import std.algorithm;
private import std.getopt;
private import std.stdio;
private import std.uni;

private import gtk.Main;

private import audio.mixer;

private import ui.mainwindow;

void main(string[] args) {
    string appName = "dseq";

    string[] availableAudioDrivers;
    version(HAVE_JACK) {
        availableAudioDrivers ~= "JACK";
    }
    version(HAVE_COREAUDIO) {
        availableAudioDrivers ~= "CoreAudio";
    }
    version(HAVE_PORTAUDIO) {
        availableAudioDrivers ~= "PortAudio";
    }
    assert(availableAudioDrivers.length > 0);
    string audioDriver;

    GetoptResult opts;
    try {
        opts = getopt(args,
                      "driver|d", "Available audio drivers: " ~ reduce!((string x, y) => x ~ ", " ~ y)
                      (availableAudioDrivers[0], availableAudioDrivers[1 .. $]), &audioDriver);
    }
    catch(Exception e) {
        writeln("Error: " ~ e.msg);
        return;
    }

    if(opts.helpWanted) {
        defaultGetoptPrinter(appName ~ " command line options:", opts.options);
        return;
    }

    try {
        Mixer mixer;
        switch(audioDriver.toUpper()) {
            version(HAVE_JACK) {
                case "JACK":
                    mixer = new JackMixer(appName);
                    break;
            }

            version(HAVE_COREAUDIO) {
                case "COREAUDIO":
                    mixer = new CoreAudioMixer(appName);
                    break;
            }

            version(HAVE_PORTAUDIO) {
                case "PORTAUDIO":
                    mixer = new PortAudioMixer(appName);
                    break;
            }

            default:
                version(OSX) {
                    version(HAVE_COREAUDIO) {
                        mixer = new CoreAudioMixer(appName);
                    }
                    else {
                        mixer = new PortAudioMixer(appName);
                    }
                }
                else {
                    version(HAVE_PORTAUDIO) {
                        mixer = new PortAudioMixer(appName);
                    }
                    else {
                        static assert(0, "Could not find a default audio driver");
                    }
                }
        }
        assert(mixer !is null);

        Main.init(args);

        auto mainWindow = new AppMainWindow(appName, mixer, args);

        Main.run();
    }
    catch(Exception e) {
        writeln("Fatal exception caught: ", e.msg);
        return;
    }
}
