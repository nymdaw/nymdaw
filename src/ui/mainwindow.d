module ui.mainwindow;

private import std.array;

private import gdk.Event;

private import gtk.MainWindow;
private import gtk.Widget;

private import audio.mixer;

private import ui.arrangeview;

/// A `MainWindow` subclass that properly handles destruction of the mixer.
/// This class will construct a single window containing the arrange view.
final class AppMainWindow : MainWindow {
public:
    /// The mixer should already be constructed before being passed to this constructor.
    /// This constructor will parse the command line arguments and load any specified audio files.
    this(string appName, Mixer mixer, string[] args) {
        super(appName);

        _mixer = mixer;

        _arrangeView = new ArrangeView(this, mixer);
        add(_arrangeView);

        setDefaultSize(1200, 700);
        showAll();

        if(!args.empty && !args[1 .. $].empty) {
            _arrangeView.loadRegionsFromFiles(args[1 .. $]);
        }
    }

protected:
    override bool windowDelete(Event event, Widget widget) {
        _cleanupMixer();
        return super.windowDelete(event, widget);
    }

    override bool exit(int code, bool force) {
        _cleanupMixer();
        return super.exit(code, force);
    }

private:
    /// This function will destroy the audio thread and clean up the mixer.
    /// It must be called when the application exits to avoid segmentation faults,
    /// since the mixer's destructor is not guaranteed to run.
    void _cleanupMixer() {
        _mixer.cleanupMixer();
    }

    Mixer _mixer;

    ArrangeView _arrangeView;
}
