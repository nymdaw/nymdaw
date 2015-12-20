module main;

private import std.algorithm;
private import std.getopt;
private import std.stdio;
private import std.uni;

private import gtk.Main;

private import audio.mixer;

private import ui.mainwindow;

/// Applicatin entry point
void main(string[] args) {
    string appName = "nymdaw";

    // populate a list of all available audio drivers
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

    // construct the mixer from the audio driver specified at the command line
    // if no driver is specified, try to pick a reasonable default
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

        // destroy any audio threads when exiting this scope
        // this helps prevent segmentation faults when the application exits
        scope(exit) mixer.cleanup();

        // initialize gtk
        Main.init(args);

        // construct the main window
        auto mainWindow = new AppMainWindow(appName, mixer, args);

        // run the application
        Main.run();
    }
    catch(Exception e) {
        writeln("Fatal exception caught: ", e.msg);
        return;
    }
}
