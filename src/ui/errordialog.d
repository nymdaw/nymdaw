module ui.errordialog;

public import gtk.MessageDialog;
private import gtk.Window;

class ErrorDialog : MessageDialog {
public:
    static display(Window parentWindow, string errorMessage) {
        auto dialog = new ErrorDialog(parentWindow, errorMessage);
        dialog.run();
        dialog.destroy();
    }

protected:
    this(Window parentWindow, string errorMessage) {
        super(parentWindow,
              DialogFlags.MODAL,
              MessageType.ERROR,
              ButtonsType.OK,
              "Error: " ~ errorMessage);
    }
}
