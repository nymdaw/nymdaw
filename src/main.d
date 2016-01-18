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

    static string[] getAvailableAudioDrivers() {
        string[] availableAudioDrivers;
        version(HAVE_COREAUDIO) {
            availableAudioDrivers ~= "CoreAudio";
        }
        version(HAVE_PORTAUDIO) {
            availableAudioDrivers ~= "PortAudio";
        }
        version(HAVE_JACK) {
            availableAudioDrivers ~= "Jack";
        }
        return availableAudioDrivers;
    }

    // populate a list of all available audio drivers
    static immutable string[] availableAudioDrivers = getAvailableAudioDrivers();
    static assert(availableAudioDrivers.length > 0, "No audio drivers found");

    string requestedAudioDriver;

    GetoptResult opts;
    try {
        opts = getopt(args,
                      "driver|d", "Available audio drivers: " ~ reduce!((x, y) => x ~ ", " ~ y)
                      (availableAudioDrivers[0], availableAudioDrivers[1 .. $]), &requestedAudioDriver);
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
    // if no driver is specified, try to pick a reasonable default (the first available driver)
    try {
        Mixer mixer;
        switch(requestedAudioDriver.toUpper()) {
            mixin(reduce!((selectorResult, driverName) =>
                          selectorResult ~= "version(HAVE_" ~ driverName.toUpper() ~ ") {\n"
                          ~ "    case \"" ~ driverName.toUpper() ~ "\":\n"
                          ~ "    mixer = new " ~ driverName ~ "Mixer(appName);\n"
                          ~ "    break;\n"
                          ~ "}\n")(string.init, availableAudioDrivers));

            default:
                mixin("mixer = new " ~ availableAudioDrivers[0] ~ "Mixer(appName);");
        }

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
