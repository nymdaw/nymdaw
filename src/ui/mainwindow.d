module ui.mainwindow;

private import std.array;
private import std.concurrency;

private import gdk.Event;

private import gtk.MainWindow;
private import gtk.Widget;

private import audio.mixer;

private import ui.arrangeview;
private import ui.types;

/// A `MainWindow` subclass that properly handles destruction of the mixer.
/// This class will construct a single window containing the arrange view.
final class AppMainWindow : MainWindow {
public:
    /// The mixer should already be constructed before it is passed to this constructor.
    /// This constructor will parse the command line arguments and load any specified audio files.
    this(string appName, Mixer mixer, string[] args) {
        super(appName);

        register(uiThreadName, thisTid);

        _arrangeView = new ArrangeView(this, mixer);
        add(_arrangeView);

        setDefaultSize(1200, 700);
        showAll();

        if(!args.empty && !args[1 .. $].empty) {
            _arrangeView.loadRegionsFromFiles(args[1 .. $]);
        }
    }

private:
    ArrangeView _arrangeView;
}
