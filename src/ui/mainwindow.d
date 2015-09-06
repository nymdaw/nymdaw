module ui.mainwindow;

private import std.array;

private import gdk.Event;

private import gtk.MainWindow;
private import gtk.Widget;

private import audio.mixer;

private import ui.arrangeview;

final class AppMainWindow : MainWindow {
public:
    this(string appName, Mixer mixer, string[] args) {
        super(appName);

        _mixer = mixer;

        _arrangeView = new ArrangeView(appName, this, mixer);
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
    void _cleanupMixer() {
        _mixer.destroy();
    }

    Mixer _mixer;
    ArrangeView _arrangeView;
}
