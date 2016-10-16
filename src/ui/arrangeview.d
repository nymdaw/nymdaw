/// The main ArrangeView widget and its associated classes.

module ui.arrangeview;

private import std.algorithm;
private import std.array;
private import std.concurrency;
private import std.conv;
private import std.file;
private import std.format;
private import std.math;
private import std.parallelism;
private import std.path;
private import std.random;
private import std.range;
private import std.traits;
private import std.typecons;
private import std.uni;

private import core.time;
private import core.exception;

private import cairo.Context;
private import cairo.Pattern;
private import cairo.Surface;

private import gdk.Cursor;
private import gdk.Display;
private import gdk.Event;
private import gdk.Keymap;
private import gdk.Keysyms;
private import gdk.Screen;

private import glib.ListSG;
private import glib.Str;
private import glib.Timeout;
private import glib.URI;

private import gobject.Value;

private import gtk.AccelGroup;
private import gtk.Adjustment;
private import gtk.Box;
private import gtk.Button;
private import gtk.ButtonBox;
private import gtk.CellRendererText;
private import gtk.CheckMenuItem;
private import gtk.ComboBoxText;
private import gtk.Dialog;
private import gtk.DrawingArea;
private import gtk.Entry;
private import gtk.FileChooserDialog;
private import gtk.FileFilter;
private import gtk.Label;
private import gtk.ListStore;
private import gtk.Main;
private import gtk.MainWindow;
private import gtk.Menu;
private import gtk.MenuBar;
private import gtk.MenuItem;
private import gtk.MessageDialog;
private import gtk.ProgressBar;
private import gtk.RadioButton;
private import gtk.Scale;
private import gtk.Scrollbar;
private import gtk.ScrolledWindow;
private import gtk.TreeIter;
private import gtk.TreeNode;
private import gtk.TreeSelection;
private import gtk.TreeStore;
private import gtk.TreeView;
private import gtk.TreeViewColumn;
private import gtk.Widget;
private import gtk.Window;

private import gtkc.gtktypes;

private import pango.PgCairo;
private import pango.PgFontDescription;
private import pango.PgLayout;

private import util.progress;
private import util.statehistory;

private import audio;

private import ui.errordialog;
private import ui.types;

/// This widget draws a canvas that allows the user to manipulate tracks/regions.
/// It also renders track stubs for all visible tracks, and channel strips for tracks/busses.
final class ArrangeView : Box {
public:
    enum defaultSamplesPerPixel = 500; /// Default zoom level, in samples per pixel
    enum defaultTrackHeightPixels = 200; /// Default height in pixels of new tracks in the arrange view
    enum defaultTrackStubWidth = 200; /// Default width in pixels for all track stubs
    enum defaultChannelStripWidth = 100; /// Default width in pixels for the channel strip
    enum refreshRate = 50; /// Rate in hertz at which to redraw the view when the transport is playing
    enum mouseOverThreshold = 2; /// Threshold number of pixels in one direction for mouse over events
    enum doubleClickMsecs = 500; /// Amount of time between two button clicks considered as a double click

    /// Convenience constant for the left mouse button
    enum leftButton = 1;

    /// Convenience constant for the right mouse button
    enum rightButton = 3;

    /// Operation mode for the arrange view
    enum Mode {
        arrange, /// Perform operations on regions such as move, copy, or shrink
        editRegion /// Edit a single region
    }

    /// Mode for copying regions
    enum CopyMode {
        soft, /// Link pasted regions to the their source sequence
        hard /// Clone the source sequence for pasted regions
    }

    /// Various actions the user may perform
    enum Action {
        none,
        selectRegion,
        mouseOverRegionStart,
        mouseOverRegionEnd,
        shrinkRegionStart,
        shrinkRegionEnd,
        selectSubregion,
        mouseOverSubregionStart,
        mouseOverSubregionEnd,
        shrinkSubregionStart,
        shrinkSubregionEnd,
        selectBox,
        moveOnset,
        moveRegion,
        moveTransport,
        createMarker,
        jumpToMarker,
        centerView,
        centerViewStart,
        centerViewEnd,
        moveMarker
    }

    /// The mixer should already be initialized prior to calling this constructor
    this(Window parentWindow, Mixer mixer) {
        _parentWindow = parentWindow;
        _accelGroup = new AccelGroup();

        _mixer = mixer;
        _masterBusView = new MasterBusView();
        _samplesPerPixel = defaultSamplesPerPixel;

        _arrangeStateHistory = new StateHistory!ArrangeState(ArrangeState());

        _menuBar = new ArrangeMenuBar();
        _canvas = new Canvas();
        _arrangeChannelStrip = new ArrangeChannelStrip();
        _trackStubs = new TrackStubs();
        _hScroll = new ArrangeHScroll();
        _vScroll = new ArrangeVScroll();

        super(Orientation.VERTICAL, 0);

        auto vBox = new Box(Orientation.VERTICAL, 0);
        vBox.packStart(_canvas, true, true, 0);
        vBox.packEnd(_hScroll, false, false, 0);

        auto channelStripBox = new Box(Orientation.VERTICAL, 0);
        channelStripBox.packStart(_arrangeChannelStrip, true, true, 0);

        auto trackStubsBox = new Box(Orientation.VERTICAL, 0);
        trackStubsBox.packStart(_trackStubs, true, true, 0);

        auto hBox = new Box(Orientation.HORIZONTAL, 0);
        hBox.packStart(channelStripBox, false, false, 0);
        hBox.packStart(trackStubsBox, false, false, 0);
        hBox.packEnd(vBox, true, true, 0);

        auto vBox2 = new Box(Orientation.HORIZONTAL, 0);
        vBox2.packStart(hBox, true, true, 0);
        vBox2.packEnd(_vScroll, false, false, 0);

        auto menuBarBox = new Box(Orientation.VERTICAL, 0);
        menuBarBox.packStart(_menuBar, true, true, 0);

        packStart(menuBarBox, false, false, 0);
        packEnd(vBox2, true, true, 0);

        showAll();
    }

    /// Menu bar to display at the top of the window
    final class ArrangeMenuBar : MenuBar {
    public:
        this() {
            super();

            Menu fileMenu = append("_File");
            fileMenu.append(new MenuItem(delegate void(MenuItem menuItem) { onNew(); },
                                         "_New...", "file.new", true,
                                         _accelGroup, 'n', GdkModifierType.CONTROL_MASK));
            fileMenu.append(new MenuItem(delegate void(MenuItem menuItem) { onImportFile(); },
                                         "_Import Audio...", "file.import", true,
                                         _accelGroup, 'i', GdkModifierType.CONTROL_MASK));
            fileMenu.append(new MenuItem(delegate void(MenuItem menuItem) { onExportSession(); },
                                         "_Export Session...", "file.export", true));
            fileMenu.append(new MenuItem(delegate void(MenuItem menuItem) { onQuit(); },
                                         "_Quit", "file.quit", true,
                                         _accelGroup, 'q', GdkModifierType.CONTROL_MASK));

            Menu mixerMenu = append("_Mixer");
            _playMenuItem = new MenuItem(&onPlay, "_Play", "mixer.play", true,
                                         _accelGroup, ' ', cast(GdkModifierType)(0));
            mixerMenu.append(_playMenuItem);
            _pauseMenuItem = new MenuItem(&onPause, "_Pause", "mixer.pause", true,
                                          _accelGroup, ' ', cast(GdkModifierType)(0));
            mixerMenu.append(_pauseMenuItem);
            _viewFollowTransportMenuItem = new CheckMenuItem("Follow Transport");
            _viewFollowTransportMenuItem.addOnToggled(delegate void(CheckMenuItem checkMenuItem) {
                    _viewFollowTransport = _viewFollowTransportMenuItem.getActive();
                });
            _viewFollowTransportMenuItem.setActive(false);
            mixerMenu.append(_viewFollowTransportMenuItem);
            updateMixerMenu();

            Menu editMenu = append("_Edit");
            _undoMenuItem = new MenuItem(&onUndo, "_Undo", "edit.undo", true,
                                         _accelGroup, 'z', GdkModifierType.CONTROL_MASK);
            editMenu.append(_undoMenuItem);
            _redoMenuItem = new MenuItem(&onRedo, "_Redo", "edit.redo", true,
                                         _accelGroup, 'y', GdkModifierType.CONTROL_MASK);
            editMenu.append(_redoMenuItem);
            editMenu.append(new MenuItem(&onCopy, "_Copy", "edit.copy", true,
                                         _accelGroup, 'c', GdkModifierType.CONTROL_MASK));
            editMenu.append(new MenuItem(&onCut, "_Cut", "edit.cut", true,
                                         _accelGroup, 'x', GdkModifierType.CONTROL_MASK));
            editMenu.append(new MenuItem(&onPaste, "_Paste", "edit.paste", true,
                                         _accelGroup, 'v', GdkModifierType.CONTROL_MASK));
            Menu copyModeMenu = editMenu.appendSubmenu("_Copy Mode");
            _softCopyMenuItem = new CheckMenuItem("Soft Copy");
            _softCopyMenuItem.setDrawAsRadio(true);
            _softCopyMenuItem.setActive(true);
            copyModeMenu.append(_softCopyMenuItem);
            _hardCopyMenuItem = new CheckMenuItem("Hard Copy");
            _hardCopyMenuItem.setDrawAsRadio(true);
            _hardCopyMenuItem.setActive(false);
            copyModeMenu.append(_hardCopyMenuItem);
            _softCopyMenuItem.addOnToggled(delegate void(CheckMenuItem checkMenuItem) {
                    if(_softCopyMenuItem.getActive() && _copyMode == CopyMode.hard) {
                        _copyMode = CopyMode.soft;
                        _hardCopyMenuItem.setActive(false);
                    }
                    else if(!_softCopyMenuItem.getActive() && _copyMode == CopyMode.soft) {
                        _softCopyMenuItem.setActive(true);
                    }
                });
            _hardCopyMenuItem.addOnToggled(delegate void(CheckMenuItem checkMenuItem) {
                    if(_hardCopyMenuItem.getActive() && _copyMode == CopyMode.soft) {
                        _copyMode = CopyMode.hard;
                        _softCopyMenuItem.setActive(false);
                    }
                    else if(!_hardCopyMenuItem.getActive() && _copyMode == CopyMode.hard) {
                        _hardCopyMenuItem.setActive(true);
                    }
                });
            updateEditMenu();

            Menu trackMenu = append("_Track");
            trackMenu.append(new MenuItem(&onNewTrack, "_New Track", "track.new", true));
            _deleteTrackMenuItem = new MenuItem(&onDeleteTrack,
                                                "_Delete Track", "track.delete", true);
            trackMenu.append(_deleteTrackMenuItem);
            _renameTrackMenuItem = new MenuItem(delegate void(MenuItem) { new RenameTrackDialog(); },
                                                    "_Rename Track...", "track.rename", true);
            trackMenu.append(_renameTrackMenuItem);
            updateTrackMenu();

            Menu regionMenu = append("_Region");
            _createEditRegionMenu(regionMenu,
                                  _gainMenuItem,
                                  _normalizeMenuItem,
                                  _reverseMenuItem,
                                  _fadeInMenuItem,
                                  _fadeOutMenuItem,
                                  _stretchSelectionMenuItem,
                                  _showOnsetsMenuItem,
                                  _onsetDetectionMenuItem,
                                  _linkChannelsMenuItem);
            updateRegionMenu();

            Menu windowMenu = append("_Window");
            _sequenceBrowserMenuItem = new CheckMenuItem("_Sequence Browser", true);
            _sequenceBrowserMenuItem.addOnToggled(&onSequenceBrowser);
            windowMenu.append(_sequenceBrowserMenuItem);
            updateSequenceBrowserMenu();
        }

        void onNew() {
            if(!_savedState) {
                auto dialog = new MessageDialog(_parentWindow,
                                                GtkDialogFlags.MODAL,
                                                MessageType.QUESTION,
                                                ButtonsType.OK_CANCEL,
                                                "Are you sure? All unsaved changes will be lost.");

                auto response = dialog.run();
                if(response == ResponseType.OK) {
                    _resetArrangeView();
                }

                dialog.destroy();
            }
            else {
                _resetArrangeView();
            }
        }

        void onQuit() {
            auto dialog = new MessageDialog(_parentWindow,
                                            GtkDialogFlags.MODAL,
                                            MessageType.QUESTION,
                                            ButtonsType.OK_CANCEL,
                                            "Are you sure? All unsaved changes will be lost.");

            auto response = dialog.run();
            if(response == ResponseType.OK) {
                Main.quit();
            }

            dialog.destroy();
        }

        void onPlay(MenuItem menuItem) {
            _mixer.play();
            updateMixerMenu();
        }

        void onPause(MenuItem menuItem) {
            _mixer.pause();
            updateMixerMenu();
        }

        void onUndo(MenuItem menuItem) {
            if(_mode == Mode.arrange) {
                undoArrange();
            }
            else if(_mode == Mode.editRegion) {
                _editRegion.undoEdit();
                _canvas.redraw();
            }
        }

        void onRedo(MenuItem menuItem) {
            if(_mode == Mode.arrange) {
                redoArrange();
            }
            else if(_mode == Mode.editRegion) {
                editRegionRedo();
            }
        }

        void onCopy(MenuItem menuItem) {
            if(_mode == Mode.arrange) {
                arrangeCopy();
            }
            else if(_mode == Mode.editRegion) {
                editRegionCopy();
            }
        }

        void onCut(MenuItem menuItem) {
            if(_mode == Mode.arrange) {
                arrangeCut();
            }
            else if(_mode == Mode.editRegion) {
                editRegionCut();
            }
        }

        void onPaste(MenuItem menuItem) {
            if(_mode == Mode.arrange) {
                arrangePaste();
            }
            else if(_mode == Mode.editRegion) {
                editRegionPaste();
            }
        }

        void onNewTrack(MenuItem menuItem) {
            immutable string prefix = "New Track ";
            static assert(prefix.length > 0);

            int trackNumber;
            foreach(trackView; _trackViews) {
                if(trackView.name.length > prefix.length &&
                   trackView.name[0 .. prefix.length] == prefix) {
                    try {
                        auto currentTrackNumber = to!int(trackView.name[prefix.length .. $]);
                        if(currentTrackNumber > trackNumber) {
                            trackNumber = currentTrackNumber;
                        }
                    }
                    catch(ConvException) {
                    }
                }
            }

            createTrackView(prefix ~ to!string(trackNumber + 1));
        }

        void onDeleteTrack(MenuItem menuItem) {
            auto tempTrack = _selectedTrack;
            _selectedTrack = null;
            deleteTrackView(tempTrack);
        }

        void onSequenceBrowser(CheckMenuItem sequenceBrowserMenuItem) {
            if(sequenceBrowserMenuItem.getActive()) {
                if(_sequenceBrowser is null) {
                    _sequenceBrowser = new SequenceBrowser();
                }
                else {
                    _sequenceBrowser.show();
                }
            }
            else {
                _sequenceBrowser.hide();
            }

            _menuBar.updateSequenceBrowserMenu();
        }

        /// Updates the mixer menu in the main menu bar.
        /// This should be called whenever the mixer state changes between play/pause
        void updateMixerMenu() {
            _playMenuItem.setSensitive(!_mixer.playing);
            _pauseMenuItem.setSensitive(_mixer.playing);
        }

        /// Updates the region menu in the main menu bar.
        /// This should be called whenever the mode changes.
        void updateEditMenu() {
            if(_mode == Mode.arrange) {
                _undoMenuItem.setSensitive(queryUndoArrange());
                _redoMenuItem.setSensitive(queryRedoArrange());
            }
            else if(_mode == Mode.editRegion && _editRegion !is null) {
                _undoMenuItem.setSensitive(_editRegion.queryUndoEdit());
                _redoMenuItem.setSensitive(_editRegion.queryRedoEdit());
            }
        }

        /// Updates the track menu in the main menu bar.
        /// This should be called whenver the track selection changes.
        void updateTrackMenu() {
            _deleteTrackMenuItem.setSensitive(_selectedTrack !is null);
            _renameTrackMenuItem.setSensitive(_selectedTrack !is null);
        }

        /// Updates the region menu in the main menu bar.
        /// This should be called whenever the mode changes.
        void updateRegionMenu() {
            _updateEditRegionMenu(_gainMenuItem,
                                  _normalizeMenuItem,
                                  _reverseMenuItem,
                                  _fadeInMenuItem,
                                  _fadeOutMenuItem,
                                  _stretchSelectionMenuItem,
                                  _showOnsetsMenuItem,
                                  _onsetDetectionMenuItem,
                                  _linkChannelsMenuItem);

            immutable bool editMode = _mode == Mode.editRegion;
            _gainMenuItem.setSensitive(editMode && _gainMenuItem.getSensitive());
            _normalizeMenuItem.setSensitive(editMode && _normalizeMenuItem.getSensitive());
            _reverseMenuItem.setSensitive(editMode && _reverseMenuItem.getSensitive());
            _fadeInMenuItem.setSensitive(editMode && _fadeInMenuItem.getSensitive());
            _fadeOutMenuItem.setSensitive(editMode && _fadeOutMenuItem.getSensitive());
            _stretchSelectionMenuItem.setSensitive(editMode && _stretchSelectionMenuItem.getSensitive());
            _showOnsetsMenuItem.setSensitive(editMode && _showOnsetsMenuItem.getSensitive());
            _onsetDetectionMenuItem.setSensitive(editMode && _onsetDetectionMenuItem.getSensitive());
            _linkChannelsMenuItem.setSensitive(editMode && _linkChannelsMenuItem.getSensitive());
        }

        /// Updates the sequence browser menu in the main menu bar.
        /// This should be called whenever the sequence browser is opened or closed.
        void updateSequenceBrowserMenu() {
            if(_sequenceBrowserMenuItem.getActive() && !_sequenceBrowser.isVisible()) {
                _sequenceBrowserMenuItem.setActive(false);
            }
        }

    private:
        MenuItem _playMenuItem;
        MenuItem _pauseMenuItem;
        CheckMenuItem _viewFollowTransportMenuItem;

        MenuItem _undoMenuItem;
        MenuItem _redoMenuItem;
        CheckMenuItem _softCopyMenuItem;
        CheckMenuItem _hardCopyMenuItem;

        MenuItem _deleteTrackMenuItem;
        MenuItem _renameTrackMenuItem;

        MenuItem _gainMenuItem;
        MenuItem _normalizeMenuItem;
        MenuItem _reverseMenuItem;
        MenuItem _fadeInMenuItem;
        MenuItem _fadeOutMenuItem;
        MenuItem _stretchSelectionMenuItem;
        CheckMenuItem _showOnsetsMenuItem;
        MenuItem _onsetDetectionMenuItem;
        CheckMenuItem _linkChannelsMenuItem;

        CheckMenuItem _sequenceBrowserMenuItem;
    }

    /// Horizontal scrollbar for the arrange view.
    /// This scrollbar moves the canvas view left/right along the time axis.
    final class ArrangeHScroll : Scrollbar {
    public:
        this() {
            _hAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
            reconfigure();
            _hAdjust.addOnValueChanged(&onHScrollChanged);
            super(Orientation.HORIZONTAL, _hAdjust);
        }

        void onHScrollChanged(Adjustment adjustment) {
            if(_centeredView) {
                _centeredView = false;
            }
            else if(_action == Action.centerView ||
                    _action == Action.centerViewStart ||
                    _action == Action.centerViewEnd) {
                _setAction(Action.none);
            }
            _viewOffset = cast(nframes_t)(adjustment.getValue());
            _canvas.redraw();
        }

        void reconfigure() {
            if(viewMaxSamples > 0) {
                _hAdjust.configure(_viewOffset, // scroll bar position
                                   viewMinSamples, // min position
                                   viewMaxSamples, // max position
                                   stepSamples, // small step size
                                   stepSamples * 5, // large step size
                                   viewWidthSamples); // scroll bar size
            }
        }
        void update() {
            _hAdjust.setValue(_viewOffset);
        }

        @property nframes_t stepSamples() {
            enum stepDivisor = 20;

            return cast(nframes_t)(viewWidthSamples / stepDivisor);
        }

    private:
        Adjustment _hAdjust;
    }

    /// Vertical scrollbar for the arrange view.
    /// This scrollbar moves the canvas view up/down, allowing the user to view different tracks.
    final class ArrangeVScroll : Scrollbar {
    public:
        this() {
            _vAdjust = new Adjustment(0, 0, 0, 0, 0, 0);
            reconfigure();
            _vAdjust.addOnValueChanged(&onVScrollChanged);
            super(Orientation.VERTICAL, _vAdjust);
        }

        void onVScrollChanged(Adjustment adjustment) {
            _verticalPixelsOffset = cast(pixels_t)(_vAdjust.getValue());
            _canvas.redraw();
            _trackStubs.redraw();
        }

        void reconfigure() {
            // add some padding to the bottom of the visible canvas
            pixels_t totalHeightPixels = _canvas.firstTrackYOffset + (defaultTrackHeightPixels / 2);

            // determine the total height of all tracks in pixels
            foreach(track; _trackViews) {
                totalHeightPixels += track.heightPixels;
            }

            _vAdjust.configure(_verticalPixelsOffset, // scroll bar position
                               0, // min position
                               totalHeightPixels, // max position
                               totalHeightPixels / 20, // small step size
                               totalHeightPixels / 10, // large step size
                               _canvas.viewHeightPixels); // scroll bar size
        }

        @property void pixelsOffset(pixels_t newValue) {
            _vAdjust.setValue(cast(pixels_t)(newValue));
        }

        @property pixels_t pixelsOffset() {
            return cast(pixels_t)(_vAdjust.getValue());
        }

        @property pixels_t stepIncrement() {
            return cast(pixels_t)(_vAdjust.getStepIncrement());
        }

    private:
        Adjustment _vAdjust;
    }

    /// A browser window that shows all audio sequences in a tree view.
    /// All regions associated with an audio sequence are displayed as children of that
    /// sequence in the tree view. Additionally, when a region is selected,
    /// the complete undo history for that region is displayed in a list view.
    final class SequenceBrowser {
    public:
        this() {
            _init();
        }

        bool isVisible() {
            return (_dialog !is null && _dialog.isVisible());
        }

        void show() {
            if(_dialog is null) {
                _init();
            }
            else {
                _dialog.showAll();
            }
        }

        void hide() {
            if(_dialog !is null) {
                _dialog.hide();
            }
        }

        void onDialogResponse(int response, Dialog dialog) {
            _dialog.destroy();
            _dialog = null;
            _menuBar.updateSequenceBrowserMenu();
        }

        /// A tree view, where the outer level is comprised of every audio sequence in the session.
        /// Each sequence has children corresponding to every region associated with that sequence.
        /// The children's names are rendered as "track.region", where "track" is the parent track
        /// of that region.
        final class SequenceTreeView : ScrolledWindow {
        public:
            this() {
                super(null, null);

                sequenceTreeStore = new SequenceTreeStore();
                treeView = new TreeView(sequenceTreeStore);
                treeView.setRulesHint(true);
                treeView.addOnCursorChanged(&onRegionSelected);

                TreeSelection treeSelection = treeView.getSelection();
                treeSelection.setMode(SelectionMode.SINGLE);

                TreeViewColumn column = new TreeViewColumn("Audio Sequence", new CellRendererText(), "text", 0);
                treeView.appendColumn(column);
                column.setResizable(true);
                column.setReorderable(true);
                column.setSortColumnId(0);
                column.setSortIndicator(true);

                column = new TreeViewColumn("Is Region", new CellRendererText(), "text", 1);
                treeView.appendColumn(column);
                column.setResizable(true);
                column.setReorderable(true);
                column.setSortColumnId(1);
                column.setSortIndicator(true);
                column.setVisible(false);

                column = new TreeViewColumn("Region Index", new CellRendererText(), "text", 2);
                treeView.appendColumn(column);
                column.setResizable(true);
                column.setReorderable(true);
                column.setSortColumnId(2);
                column.setSortIndicator(true);
                column.setVisible(false);

                update();

                addWithViewport(treeView);
            }

            final class SequenceTreeStore : TreeStore {
            public:
                this() {
                    static GType[] columns = [GType.STRING, GType.BOOLEAN, GType.ULONG];
                    super(columns);
                }
            }

            void update() {
                Nullable!size_t getRegionViewIndex(RegionView searchRegionView) {
                    Nullable!size_t result;
                    foreach(index, regionView; _regionViews) {
                        if(regionView is searchRegionView) {
                            result = index;
                            break;
                        }
                    }
                    return result;
                }

                sequenceTreeStore.clear();

                Value isRegion = new Value(true);
                Value isNotRegion = new Value(false);
                Value zeroIndex = new Value();
                zeroIndex.init(GType.ULONG);
                zeroIndex.setUlong(0);

                TreeIter iterTop, iterChild;
                foreach(i, audioSeq; _audioSequences) {
                    iterTop = sequenceTreeStore.createIter(null);
                    Value sequenceName = new Value(audioSeq.name);
                    sequenceTreeStore.setValue(iterTop, 0, sequenceName);
                    sequenceTreeStore.setValue(iterTop, 1, isNotRegion);
                    sequenceTreeStore.setValue(iterTop, 2, zeroIndex);
                    foreach(j, link; audioSeq.softLinks.enumerate) {
                        auto regionViewLink = cast(RegionView.RegionViewLink)(link);
                        if(regionViewLink !is null) {
                            bool foundRegion;
                            foreach(regionView; regionViewLink.regionView.trackView.regionViews) {
                                if(regionView is regionViewLink.regionView) {
                                    foundRegion = true;
                                    break;
                                }
                            }

                            if(foundRegion) {
                                iterChild = sequenceTreeStore.append(iterTop);

                                Value regionName = new Value(regionViewLink.name);
                                Value regionViewIndexValue = new Value();
                                regionViewIndexValue.init(GType.ULONG);
                                auto regionViewIndex = getRegionViewIndex(regionViewLink.regionView);
                                if(!regionViewIndex.isNull()) {
                                    regionViewIndexValue.setUlong(regionViewIndex);
                                }
                                sequenceTreeStore.setValue(iterChild, 0, regionName);
                                sequenceTreeStore.setValue(iterChild, 1, isRegion);
                                sequenceTreeStore.setValue(iterChild, 2, regionViewIndexValue);
                            }
                        }
                    }
                }
            }

            SequenceTreeStore sequenceTreeStore;
            TreeView treeView;
            alias treeView this;
        }

        /// A list view displaying the complete undo history for a region selected in the sequence tree view.
        final class RegionHistoryTreeView : ScrolledWindow {
        public:
            this() {
                super(null, null);

                regionListStore = new RegionListStore();
                treeView = new TreeView(regionListStore);
                treeView.setRulesHint(true);

                TreeViewColumn column = new TreeViewColumn("Index", new CellRendererText(), "text", 0);
                treeView.appendColumn(column);
                column.setResizable(true);
                column.setReorderable(true);
                column.setSortColumnId(0);
                column.setSortIndicator(true);

                column = new TreeViewColumn("Operation", new CellRendererText(), "text", 1);
                treeView.appendColumn(column);
                column.setResizable(true);
                column.setReorderable(true);
                column.setSortColumnId(1);
                column.setSortIndicator(true);

                update();

                addWithViewport(treeView);
            }

            final class RegionListStore : ListStore {
                this() {
                    static GType[] columns = [GType.ULONG, GType.STRING];
                    super(columns);
                }
            }

            void update() {
                regionListStore.clear();

                TreeIter selectedIter = _sequenceTreeView.getSelectedIter();
                if(selectedIter !is null) {
                    Value name = new Value();
                    selectedIter.getValue(0, name);

                    Value isRegion = new Value();
                    selectedIter.getValue(1, isRegion);

                    if(isRegion.getBoolean()) {
                        Value regionViewIndexValue = new Value();
                        selectedIter.getValue(2, regionViewIndexValue);

                        size_t regionViewIndex = regionViewIndexValue.getUlong();
                        RegionView selectedRegion;
                        if(regionViewIndex >= 0 &&
                           regionViewIndex < _regionViews.length &&
                           (selectedRegion = _regionViews[regionViewIndex]) !is null) {
                            _trackLabel.setText("Track: " ~ selectedRegion.trackView.name);
                            _regionLabel.setText("Region: " ~ selectedRegion.name);

                            TreeIter iterTop;
                            foreach(index, editState; selectedRegion.undoHistory.enumerate) {
                                if(index > 0) {
                                    if(index == 1) {
                                        iterTop = regionListStore.createIter();
                                    }
                                    else {
                                        regionListStore.append(iterTop);
                                    }
                                    Value stateIndex = new Value();
                                    stateIndex.init(GType.ULONG);
                                    stateIndex.setUlong(index);

                                    regionListStore.setValue(iterTop, 0, stateIndex);
                                    regionListStore.setValue(iterTop, 1, editState.description);
                                }
                            }
                        }
                    }
                }
            }

            RegionListStore regionListStore;
            TreeView treeView;
            alias treeView this;
        }

        void onRegionSelected(TreeView treeView) {
            resetLabels();
            _regionHistoryTreeView.update();
        }

        void updateSequenceTreeView() {
            resetLabels();
            _sequenceTreeView.update();
        }

        void updateRegionHistoryTreeView() {
            resetLabels();
            _regionHistoryTreeView.update();
        }

        void resetLabels() {
            _trackLabel.setText(string.init);
            _regionLabel.setText(string.init);
        }

    private:
        void _init() {
            _dialog = new Dialog();
            _dialog.setDefaultSize(400, 500);
            _dialog.setTransientFor(_parentWindow);
            _dialog.addOnResponse(&onDialogResponse);
            auto content = _dialog.getContentArea();

            auto hBox = new Box(Orientation.HORIZONTAL, 0);
            _sequenceTreeView = new SequenceTreeView();
            hBox.packStart(_sequenceTreeView, true, true, 0);

            auto vBox = new Box(Orientation.VERTICAL, 10);
            _trackLabel = new Label(string.init);
            vBox.packStart(_trackLabel, false, false, 0);
            _regionLabel = new Label(string.init);
            vBox.packStart(_regionLabel, false, false, 0);
            _regionHistoryTreeView = new RegionHistoryTreeView();
            _regionHistoryTreeView.setBorderWidth(15);
            vBox.packEnd(_regionHistoryTreeView, true, true, 0);
            hBox.packStart(vBox, true, true, 0);

            content.packStart(hBox, true, true, 0);

            show();
        }

        SequenceTreeView _sequenceTreeView;
        RegionHistoryTreeView _regionHistoryTreeView;
        Label _trackLabel;
        Label _regionLabel;
        Dialog _dialog;
    }

    /// An abstract class for drawing a dialog window.
    /// These dialogs are typically used to configure arrange operations.
    /// Most of these dialogs will have OK/Cancel buttons.
    abstract class ArrangeDialog {
    public:
        this(bool okButton = true) {
            _dialog = new Dialog();
            _dialog.setDefaultSize(250, 150);
            _dialog.setTransientFor(_parentWindow);
            auto content = _dialog.getContentArea();
            populate(content);

            if(okButton) {
                content.packEnd(createOKCancelButtons(&_onOKImpl, &_onCancelImpl), false, false, 10);
            }
            else {
                content.packEnd(createCancelButton(&_onCancelImpl), false, false, 10);
            }
            _dialog.showAll();
        }

        auto run() {
            return _dialog.run();
        }

        static ButtonBox createCancelButton(void delegate(Button) onCancel) {
            auto buttonBox = new ButtonBox(Orientation.HORIZONTAL);
            buttonBox.setLayout(ButtonBoxStyle.END);
            buttonBox.setBorderWidth(5);
            buttonBox.setSpacing(7);
            buttonBox.add(new Button("Cancel", onCancel));
            return buttonBox;
        }
        static ButtonBox createOKCancelButtons(void delegate(Button) onOK, void delegate(Button) onCancel) {
            auto buttonBox = new ButtonBox(Orientation.HORIZONTAL);
            buttonBox.setLayout(ButtonBoxStyle.END);
            buttonBox.setBorderWidth(5);
            buttonBox.setSpacing(7);
            buttonBox.add(new Button("OK", onOK));
            buttonBox.add(new Button("Cancel", onCancel));
            return buttonBox;
        }

    protected:
        /// Abstract member function called on dialog construction
        void populate(Box content);

        /// Abstract member function called when the "OK" button is pressed
        void onOK(Button button) {}

        /// Abstract member function called when the "Cancel" button is pressed
        void onCancel(Button button) {}

    private:
        final void _destroyDialog() {
            if(_dialog !is null) {
                _dialog.destroy();
                _dialog = null;
            }
        }

        final void _onOKImpl(Button button) {
            _dialog.response(ResponseType.OK);
            onOK(button);
            _destroyDialog();
        }

        final void _onCancelImpl(Button button) {
            _dialog.response(ResponseType.CANCEL);
            onCancel(button);
            _destroyDialog();
        }

        Dialog _dialog;
    }

    /// Dialog for resampling an audio file.
    /// Allows the user to select confirm the resample operation and select a preferred resampling algorithm.
    final class SampleRateDialog : ArrangeDialog {
    public:
        this(nframes_t originalSampleRate, nframes_t newSampleRate) {
            _originalSampleRate = originalSampleRate;
            _newSampleRate = newSampleRate;

            super();
        }

        @property SampleRateConverter selectedSampleRateConverter() const { return _selectedSampleRateConverter; }

    protected:
        override void populate(Box content) {
            auto box = new Box(Orientation.VERTICAL, 5);
            box.packStart(new Label("This audio file has a sample rate of " ~
                                    to!string(_originalSampleRate) ~ "Hz."), false, false, 0);
            box.packStart(new Label("Resample to " ~
                                    to!string(_newSampleRate) ~ " Hz?"), false, false, 0);
            _resampleQualityComboBox = new ComboBoxText();
            foreach(index, resampleQualityString; _resampleQualityStrings) {
                _resampleQualityComboBox.insertText(index, resampleQualityString);
            }
            _resampleQualityComboBox.setActive(0);
            box.packEnd(_resampleQualityComboBox, false, false, 0);
            content.packStart(box, false, false, 10);
        }

        override void onOK(Button button) {
            foreach(sampleRateConverter, resampleQualityString; _resampleQualityStrings) {
                if(resampleQualityString == _resampleQualityComboBox.getActiveText()) {
                    _selectedSampleRateConverter = sampleRateConverter;
                    break;
                }
            }
        }

    private:
        static this() {
            _resampleQualityStrings = [SampleRateConverter.best : "Best",
                                       SampleRateConverter.medium : "Medium",
                                       SampleRateConverter.fastest : "Fastest"];
            assert(_resampleQualityStrings.length > 0);
        }

        nframes_t _originalSampleRate;
        nframes_t _newSampleRate;

        static immutable string[SampleRateConverter] _resampleQualityStrings;
        SampleRateConverter _selectedSampleRateConverter;
        ComboBoxText _resampleQualityComboBox;
    }

    /// Dialog for selecting the bit depth, when exporting an audio file (either 16-bit or 24-bit).
    final class BitDepthDialog : ArrangeDialog {
    public:
        @property AudioBitDepth selectedBitDepth() const { return _selectedBitDepth; }

    protected:
        override void populate(Box content) {
            auto box = new Box(Orientation.VERTICAL, 5);
            box.packStart(new Label("Bit Depth"), false, false, 0);
            _bitDepthComboBox = new ComboBoxText();
            foreach(index, bitDepthString; _bitDepthStrings) {
                _bitDepthComboBox.insertText(index, bitDepthString);
            }
            _bitDepthComboBox.setActive(0);
            box.packEnd(_bitDepthComboBox, false, false, 0);
            content.packStart(box, false, false, 10);
        }

        override void onOK(Button button) {
            foreach(audioBitDepth, bitDepthString; _bitDepthStrings) {
                if(bitDepthString == _bitDepthComboBox.getActiveText()) {
                    _selectedBitDepth = audioBitDepth;
                    break;
                }
            }
        }

    private:
        static this() {
            _bitDepthStrings = [AudioBitDepth.pcm16Bit : "16-bit PCM",
                                AudioBitDepth.pcm24Bit : "24-bit PCM"];
            assert(_bitDepthStrings.length > 0);
        }

        static immutable string[AudioBitDepth] _bitDepthStrings;
        AudioBitDepth _selectedBitDepth;
        ComboBoxText _bitDepthComboBox;
    }

    /// Dialog for renaming the currently selected track.
    final class RenameTrackDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            if(_selectedTrack !is null) {
                _trackView = _selectedTrack;

                auto box = new Box(Orientation.VERTICAL, 5);
                box.packStart(new Label("Track Name"), false, false, 0);
                _nameEntry = new Entry(_trackView.name);
                box.packStart(_nameEntry, false, false, 0);
                content.packStart(box, false, false, 10);
            }
        }

        override void onOK(Button button) {
            if(_trackView !is null) {
                _trackView.name = _nameEntry.getText();

                _trackStubs.redraw();
                _arrangeChannelStrip.redraw();
            }
        }

    private:
        TrackView _trackView;

        Entry _nameEntry;
    }

    /// Dialog for configuring parameters for the onset detection algorithm.
    /// Applies only to the region currently being edited.
    final class OnsetDetectionDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            auto box1 = new Box(Orientation.VERTICAL, 5);
            box1.packStart(new Label("Onset Threshold"), false, false, 0);
            _onsetThresholdAdjustment = new Adjustment(_region.onsetParams.onsetThreshold,
                                                       OnsetParams.onsetThresholdMin,
                                                       OnsetParams.onsetThresholdMax,
                                                       0.01,
                                                       0.1,
                                                       0);
            auto onsetThresholdScale = new Scale(Orientation.HORIZONTAL, _onsetThresholdAdjustment);
            onsetThresholdScale.setDigits(3);
            box1.packStart(onsetThresholdScale, false, false, 0);
            content.packStart(box1, false, false, 10);

            auto box2 = new Box(Orientation.VERTICAL, 5);
            box2.packStart(new Label("Silence Threshold (dbFS)"), false, false, 0);
            _silenceThresholdAdjustment = new Adjustment(_region.onsetParams.silenceThreshold,
                                                         OnsetParams.silenceThresholdMin,
                                                         OnsetParams.silenceThresholdMax,
                                                         0.1,
                                                         1,
                                                         0);
            auto silenceThresholdScale = new Scale(Orientation.HORIZONTAL, _silenceThresholdAdjustment);
            silenceThresholdScale.setDigits(3);
            box2.packStart(silenceThresholdScale, false, false, 0);
            content.packStart(box2, false, false, 10);
        }

        override void onOK(Button button) {
            if(_region !is null) {
                _region.onsetParams.onsetThreshold = _onsetThresholdAdjustment.getValue();
                _region.onsetParams.silenceThreshold = _silenceThresholdAdjustment.getValue();

                _region.computeOnsets();
                _canvas.redraw();
            }
        }

    private:
        RegionView _region;
        Adjustment _onsetThresholdAdjustment;
        Adjustment _silenceThresholdAdjustment;
    }

    /// Dialog for stretching a selected section of the region currently being edited.
    final class StretchSelectionDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            content.packStart(new Label("Stretch factor"), false, false, 0);
            _stretchSelectionFactorAdjustment = new Adjustment(0,
                                                               -10,
                                                               10,
                                                               0.1,
                                                               0.5,
                                                               0);
            auto stretchSelectionRatioScale = new Scale(Orientation.HORIZONTAL, _stretchSelectionFactorAdjustment);
            stretchSelectionRatioScale.setDigits(2);
            content.packStart(stretchSelectionRatioScale, false, false, 10);
        }

        override void onOK(Button button) {
            if(_region !is null) {
                auto stretchRatio = _stretchSelectionFactorAdjustment.getValue();
                if(stretchRatio < 0) {
                    stretchRatio = 1.0 / (-stretchRatio);
                }
                else if(stretchRatio == 0) {
                    stretchRatio = 1;
                }

                _region.subregionEndFrame =
                    _region.region.stretchSubregion(_editRegion.subregionStartFrame,
                                                    _editRegion.subregionEndFrame,
                                                    stretchRatio);
                if(_region.showOnsets) {
                    _region.computeOnsets();
                }
                _region.appendEditState(_region.currentEditState(true, true), "Stretch subregion");

                _canvas.redraw();
            }
        }

    private:
        RegionView _region;
        Adjustment _stretchSelectionFactorAdjustment;
    }

    /// Dialog for adjusting the gain of a section of the region currently being edited, or the entire region.
    final class GainDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            _gainEntireRegion = new RadioButton(cast(ListSG)(null), "Entire Region");
            _gainSelectionOnly = new RadioButton(_gainEntireRegion, "Selection Only");
            _gainSelectionOnly.setSensitive(_editRegion.subregionSelected);
            if(_editRegion.subregionSelected) {
                _gainSelectionOnly.setActive(true);
            }
            else {
                _gainEntireRegion.setActive(true);
            }

            auto hBox = new Box(Orientation.HORIZONTAL, 10);
            hBox.add(_gainEntireRegion);
            hBox.add(_gainSelectionOnly);
            content.packStart(hBox, false, false, 10);

            content.packStart(new Label("Gain (dbFS)"), false, false, 0);
            _gainAdjustment = new Adjustment(0, -70, 10, 0.01, 0.5, 0);
            auto gainScale = new Scale(Orientation.HORIZONTAL, _gainAdjustment);
            gainScale.setDigits(3);
            content.packStart(gainScale, false, false, 10);
        }

        override void onOK(Button button) {
            bool selectionOnly = _gainSelectionOnly.getActive();
            bool entireRegion = _gainEntireRegion.getActive();

            if(_region !is null) {
                auto newProgressTask =
                    progressTask(_region.name,
                                 delegate void(GainState.Callback progressCallback) {
                                     if(_region.subregionSelected && selectionOnly) {
                                         _region.region.gain(_region.subregionStartFrame,
                                                             _region.subregionEndFrame,
                                                             cast(sample_t)(_gainAdjustment.getValue()),
                                                             progressCallback);
                                         if(_editRegion.showOnsets) {
                                             _editRegion.computeOnsets();
                                         }
                                         _region.appendEditState(_region.currentEditState(true),
                                                                 "Adjust subregion gain");
                                     }
                                     else if(entireRegion) {
                                         _region.region.gain(cast(sample_t)(_gainAdjustment.getValue()),
                                                             progressCallback);
                                         if(_editRegion.showOnsets) {
                                             _editRegion.computeOnsets();
                                         }
                                         _region.appendEditState(_region.currentEditState(true),
                                                                 "Adjust region gain");
                                     }
                                 });
                beginProgressTask!(GainState)(newProgressTask);
                _canvas.redraw();
            }
        }

    private:
        RegionView _region;
        RadioButton _gainEntireRegion;
        RadioButton _gainSelectionOnly;
        Adjustment _gainAdjustment;
    }

    /// Dialog for normalizing a section of the region currently being edited, or the entire region.
    final class NormalizeDialog : ArrangeDialog {
    protected:
        override void populate(Box content) {
            _region = _editRegion;

            _normalizeEntireRegion = new RadioButton(cast(ListSG)(null), "Entire Region");
            _normalizeSelectionOnly = new RadioButton(_normalizeEntireRegion, "Selection Only");
            _normalizeSelectionOnly.setSensitive(_editRegion.subregionSelected);
            if(_editRegion.subregionSelected) {
                _normalizeSelectionOnly.setActive(true);
            }
            else {
                _normalizeEntireRegion.setActive(true);
            }

            auto hBox = new Box(Orientation.HORIZONTAL, 10);
            hBox.add(_normalizeEntireRegion);
            hBox.add(_normalizeSelectionOnly);
            content.packStart(hBox, false, false, 10);

            content.packStart(new Label("Normalize gain (dbFS)"), false, false, 0);
            _normalizeGainAdjustment = new Adjustment(-0.1, -20, 0, 0.01, 0.5, 0);
            auto normalizeGainScale = new Scale(Orientation.HORIZONTAL, _normalizeGainAdjustment);
            normalizeGainScale.setDigits(3);
            content.packStart(normalizeGainScale, false, false, 10);
        }

        override void onOK(Button button) {
            bool selectionOnly = _normalizeSelectionOnly.getActive();
            bool entireRegion = _normalizeEntireRegion.getActive();

            if(_region !is null) {
                auto progressTask =
                    progressTask(_region.name,
                                 delegate void(NormalizeState.Callback progressCallback) {
                                     if(_region.subregionSelected && selectionOnly) {
                                         _region.region.normalize(_region.subregionStartFrame,
                                                                  _region.subregionEndFrame,
                                                                  cast(sample_t)(
                                                                      _normalizeGainAdjustment.getValue()),
                                                                  progressCallback);
                                         if(_editRegion.showOnsets) {
                                             _editRegion.computeOnsets();
                                         }
                                         _region.appendEditState(_region.currentEditState(true),
                                                                 "Normalize subregion");
                                     }
                                     else if(entireRegion) {
                                         _region.region.normalize(cast(sample_t)(
                                                                      _normalizeGainAdjustment.getValue()),
                                                                  progressCallback);
                                         if(_editRegion.showOnsets) {
                                             _editRegion.computeOnsets();
                                         }
                                         _region.appendEditState(_region.currentEditState(true),
                                                                 "Normalize region");
                                     }
                                 });
                beginProgressTask!(NormalizeState)(progressTask);
                _canvas.redraw();
            }
        }

    private:
        RegionView _region;
        RadioButton _normalizeEntireRegion;
        RadioButton _normalizeSelectionOnly;
        Adjustment _normalizeGainAdjustment;
    }

    /// Abstraction of a region object to facilitate rendering and edit operations.
    final class RegionView {
    public:
        enum cornerRadius = 4; /// Radius of the rounded corners of the region, in pixels
        enum borderWidth = 1; /// Width of the edges of the region, in pixels
        enum headerHeight = 15; /// Height of the region's label, in pixels
        enum headerFont = "Arial 10"; /// Font family and size to use for the region's label

        /// Subclass the audio sequence link class, adding a `RegionView` member to the link data members
        static class RegionViewLink : AudioSequence.Link {
            this(RegionView regionView) {
                this.regionView = regionView;
                super(regionView.region);
            }

            override string name() {
                return regionView.trackView.name ~ '.' ~ regionView.name();
            }

            RegionView regionView;
        }

        /// Add this region view to its source sequence as a soft link
        void addSoftLinkToSequence() {
            region.audioSequence.addSoftLink(new RegionViewLink(this));
        }

        /// Draw the region to the given cairo context
        void drawRegion(ref Scoped!Context cr, pixels_t yOffset) {
            _drawRegion(cr, _trackView, yOffset, _trackView.heightPixels, region.offset, 1.0);
        }

        /// Draw the region in the case that the user is currently moving the region with the mouse
        void drawRegionMoving(ref Scoped!Context cr, pixels_t yOffset) {
            TrackView trackView;
            if(previewTrackIndex >= 0 && previewTrackIndex < _trackViews.length) {
                trackView = _trackViews[previewTrackIndex];
                yOffset = trackView.stubBox.y0;
            }
            else {
                trackView = _trackView;
            }
            _drawRegion(cr, trackView, yOffset, trackView.heightPixels, previewOffset, 0.5);
        }

        /// Compute onsets independently for each channel in the region
        void computeOnsetsIndependentChannels() {
            auto progressTask =
                progressTask(region.name,
                             delegate void(ComputeOnsetsState.Callback progressCallback) {
                                 progressCallback(ComputeOnsetsState.computeOnsets, 0);

                                 if(_onsets !is null) {
                                     _onsets.destroy();
                                 }
                                 _onsets = [];
                                 _onsets.reserve(region.nChannels);
                                 for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                                     _onsets ~= new OnsetSequence(cast(immutable)(
                                         region.computeOnsetsSingleChannel(onsetParams,
                                                                           channelIndex,
                                                                           progressCallback)));
                                 }

                                 progressCallback(ComputeOnsetsState.complete, 1);
                             });
            beginProgressTask!(ComputeOnsetsState)(progressTask);
            _canvas.redraw();
        }

        /// Compute onsets for all (summed) channels
        void computeOnsetsLinkedChannels() {
            auto progressTask =
                progressTask(region.name,
                             delegate void(ComputeOnsetsState.Callback progressCallback) {
                                 progressCallback(ComputeOnsetsState.computeOnsets, 0);

                                 if(region.nChannels > 1) {
                                     _onsetsLinked = new OnsetSequence(cast(immutable)(
                                         region.computeOnsetsLinkedChannels(onsetParams,
                                                                            progressCallback)));
                                 }

                                 progressCallback(ComputeOnsetsState.complete, 1);
                             });
            beginProgressTask!(ComputeOnsetsState)(progressTask);
            _canvas.redraw();
        }

        /// Compute onsets according to the `linkChannels` flag
        void computeOnsets() {
            if(linkChannels) {
                computeOnsetsLinkedChannels();
            }
            else {
                computeOnsetsIndependentChannels();
            }
        }

        /// Find the index of any onset between `(searchFrame - searchRadius)` and `(searchFrame + searchRadius)`
        /// Returns: `true` if successful, and stores the index in the `searchIndex` output argument
        bool getOnset(nframes_t searchFrame,
                      nframes_t searchRadius,
                      out nframes_t foundFrame,
                      out size_t foundIndex,
                      channels_t channelIndex = 0) {
            OnsetSequence onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];

            // recursive binary search helper function
            bool getOnsetRec(nframes_t searchFrame,
                             nframes_t searchRadius,
                             out nframes_t foundFrame,
                             out size_t foundIndex,
                             size_t leftIndex,
                             size_t rightIndex) {
                foundIndex = (leftIndex + rightIndex) / 2;
                if(foundIndex >= onsets.length) {
                    return false;
                }

                foundFrame = onsets[foundIndex].onsetFrame;
                if(foundFrame >= searchFrame - searchRadius && foundFrame <= searchFrame + searchRadius) {
                    return true;
                }
                else if(leftIndex >= rightIndex) {
                    return false;
                }

                if(foundFrame < searchFrame) {
                    return getOnsetRec(searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       foundIndex + 1,
                                       rightIndex);
                }
                else {
                    return getOnsetRec(searchFrame,
                                       searchRadius,
                                       foundFrame,
                                       foundIndex,
                                       leftIndex,
                                       foundIndex - 1);
                }
            }

            return getOnsetRec(searchFrame,
                               searchRadius,
                               foundFrame,
                               foundIndex,
                               0,
                               onsets.length - 1);
        }

        /// Move a specific onset given by `onsetIndex`, with the current position at `currentOnsetFrame`
        /// Returns: The new onset value (locally indexed for this region)
        nframes_t moveOnset(size_t onsetIndex,
                            nframes_t currentOnsetFrame,
                            nframes_t relativeSamples,
                            Direction direction,
                            channels_t channelIndex = 0) {
            OnsetSequence onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            switch(direction) {
                case Direction.left:
                    nframes_t leftBound = (onsetIndex > 0) ? onsets[onsetIndex - 1].onsetFrame : 0;
                    if(onsets[onsetIndex].onsetFrame > relativeSamples &&
                       currentOnsetFrame - relativeSamples > leftBound) {
                        return currentOnsetFrame - relativeSamples;
                    }
                    else {
                        return leftBound;
                    }

                case Direction.right:
                    nframes_t rightBound = (onsetIndex < onsets.length - 1) ?
                        onsets[onsetIndex + 1].onsetFrame : region.nframes - 1;
                    if(currentOnsetFrame + relativeSamples < rightBound) {
                        return currentOnsetFrame + relativeSamples;
                    }
                    else {
                        return rightBound;
                    }

                default:
                    break;
            }
            return 0;
        }

        /// Returns: The latest onset frame before the onset specified by `onsetIndex`,
        ///          locally indexed for this region
        nframes_t getPrevOnset(size_t onsetIndex, channels_t channelIndex = 0) {
            auto onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            return (onsetIndex > 0) ? onsets[onsetIndex - 1].onsetFrame : 0;
        }

        /// Returns: The earliest onset frame after the onset specified by `onsetIndex`,
        ///          locally indexed for this region
        nframes_t getNextOnset(size_t onsetIndex, channels_t channelIndex = 0) {
            auto onsets = linkChannels ? _onsetsLinked : _onsets[channelIndex];
            return (onsetIndex < onsets.length - 1) ? onsets[onsetIndex + 1].onsetFrame : region.nframes - 1;
        }

        /// This function assumes that the mouse is actually over region view.
        /// Returns: The channel index corresponding to the channel the mouse is currently over
        channels_t mouseOverChannel(pixels_t mouseY) const {
            immutable pixels_t trackHeight = (boundingBox.y1 - boundingBox.y0) - headerHeight;
            immutable pixels_t channelHeight = trackHeight / region.nChannels;
            return clamp((mouseY - (boundingBox.y0 + headerHeight)) / channelHeight, 0, region.nChannels - 1);
        }

        /// State structure of edit operations that the user can undo/redo
        static struct EditState {
            this(bool audioEdited,
                 bool recomputeOnsets,
                 bool onsetsEdited,
                 bool onsetsLinkChannels,
                 channels_t onsetsChannelIndex,
                 bool subregionSelected,
                 nframes_t subregionStartFrame = 0,
                 nframes_t subregionEndFrame = 0) {
                this.audioEdited = audioEdited;

                this.recomputeOnsets = recomputeOnsets;
                this.onsetsEdited = onsetsEdited;
                this.onsetsLinkChannels = onsetsLinkChannels;
                this.onsetsChannelIndex = onsetsChannelIndex;

                this.subregionSelected = subregionSelected;
                this.subregionStartFrame = subregionStartFrame;
                this.subregionEndFrame = subregionEndFrame;
            }

            /// Whether the sequence's audio data was edited
            const(bool) audioEdited;

            /// Whether the region view should recompute the onsets for this state
            const(bool) recomputeOnsets;

            /// Whether an onset was edited
            const(bool) onsetsEdited;

            /// Whether the link channels flag was enabled
            const(bool) onsetsLinkChannels;

            /// The channel index of the edited onset, if applicable
            const(channels_t) onsetsChannelIndex;

            /// Whether a subregion was selected
            const(bool) subregionSelected;

            /// The relative start frame of the selected subregion, if applicable
            const(nframes_t) subregionStartFrame;

            /// The relative end frame of the selected subregion, if applicable
            const(nframes_t) subregionEndFrame;

            /// A textual description of the edit operation
            string description;
        }

        /// Retrieve the current edit state.
        /// Params:
        /// audioEdited = Whether the sequence's audio data was edited
        /// recomputeOnsets = Whether the region view should recompute onsets for this state
        /// onsetsEdited = Whether an onset was edited
        /// onsetsChannelIndex = The channel index of the edited onset, if applicable
        /// Returns: The current edit state
        EditState currentEditState(bool audioEdited,
                                   bool recomputeOnsets = false,
                                   bool onsetsEdited = false,
                                   channels_t onsetsChannelIndex = 0) {
            return EditState(audioEdited,
                             recomputeOnsets,
                             onsetsEdited,
                             linkChannels,
                             onsetsChannelIndex,
                             subregionSelected,
                             _subregionStartFrame,
                             _subregionEndFrame);
        }

        /// Update the region view according to the current edit state.
        /// This function should be called after an undo/redo operation to
        /// effect the changes of the new edit state.
        void updateCurrentEditState() {
            subregionSelected = _editStateHistory.currentState.subregionSelected;

            _subregionStartFrame = clamp(_editStateHistory.currentState.subregionStartFrame,
                                         sliceStartFrame, sliceEndFrame);
            _subregionEndFrame = clamp(_editStateHistory.currentState.subregionEndFrame,
                                       _subregionStartFrame, sliceEndFrame);

            editPointOffset = subregionStartFrame;

            if(_subregionStartFrame == _subregionEndFrame) {
                subregionSelected = false;
            }
        }

        /// Append an edit state to the undo history
        /// Params:
        /// editState = The state of the last edit operation
        /// description = A textual description of the last edit operation
        void appendEditState(EditState editState, string description) {
            editState.description = description;
            _editStateHistory.appendState(editState);
            if(_sequenceBrowser !is null && _sequenceBrowser.isVisible()) {
                _sequenceBrowser.updateRegionHistoryTreeView();
            }
        }

        /// Returns: `true` if and only if an undo operation is possible
        bool queryUndoEdit() {
            return _editStateHistory.queryUndo();
        }

        /// Returns: `true` if and only if a redo operation is possible
        bool queryRedoEdit() {
            return _editStateHistory.queryRedo();
        }

        /// Undo the last edit operation, if possible.
        /// This function will clear the redo history if the user subsequently executes a new operation.
        void undoEdit() {
            if(queryUndoEdit()) {
                if(_editStateHistory.currentState.audioEdited) {
                    region.undoEdit();
                }

                if(_editStateHistory.currentState.onsetsEdited) {
                    OnsetSequence onsets = _editStateHistory.currentState.onsetsLinkChannels ?
                        _onsetsLinked : _onsets[_editStateHistory.currentState.onsetsChannelIndex];
                    if(showOnsets && !onsets.queryUndo()) {
                        computeOnsets();
                    }
                    else {
                        onsets.undo();
                    }
                }
                else if(showOnsets && _editStateHistory.currentState.recomputeOnsets) {
                    computeOnsets();
                }

                _editStateHistory.undo();
                updateCurrentEditState();

                if(_sequenceBrowser !is null && _sequenceBrowser.isVisible()) {
                    _sequenceBrowser.updateRegionHistoryTreeView();
                }
            }
        }

        /// Redo the last edit operation, if possible.
        void redoEdit() {
            if(queryRedoEdit()) {
                _editStateHistory.redo();
                if(_editStateHistory.currentState.audioEdited) {
                    region.redoEdit();
                }

                if(_editStateHistory.currentState.onsetsEdited) {
                    OnsetSequence onsets = _editStateHistory.currentState.onsetsLinkChannels ?
                        _onsetsLinked : _onsets[_editStateHistory.currentState.onsetsChannelIndex];
                    if(showOnsets && !onsets.queryRedo()) {
                        computeOnsets();
                    }
                    else {
                        onsets.redo();
                    }
                }
                else if(showOnsets && _editStateHistory.currentState.recomputeOnsets) {
                    computeOnsets();
                }

                updateCurrentEditState();

                if(_sequenceBrowser !is null && _sequenceBrowser.isVisible()) {
                    _sequenceBrowser.updateRegionHistoryTreeView();
                }
            }
        }

        /// Modifies (within limits) the start of the region, in terms of global frames.
        /// Returns: A `Region.ShrinkResult` object indicating whether the shrink operation was successful
        auto shrinkStart(nframes_t newStartFrameGlobal) {
            auto result = region.shrinkStart(newStartFrameGlobal);
            if(result.success) {
                _sliceChanged = true;
            }
            return result;
        }

        /// Modifies (within limits) the end of the region, in terms of global frames
        /// Returns: A `Region.ShrinkResult` object indicating whether the shrink operation was successful
        auto shrinkEnd(nframes_t newEndFrameGlobal) {
            auto result = region.shrinkEnd(newEndFrameGlobal);
            if(result.success) {
                _sliceChanged = true;
            }
            return result;
        }

        /// The `TrackView` object representing the parent track of this region
        @property TrackView trackView() { return _trackView; }

        /// Move this region to another track, handling all requisite registering/unregistering
        void moveToTrack(TrackView trackView) {
            _trackView.unregisterRegion(this);
            trackView.registerRegion(this);

            _trackView = trackView;
        }

        /// Slice start frame, relative to start of sequence
        @property nframes_t sliceStartFrame() const { return region.sliceStartFrame; }
        /// ditto
        @property nframes_t sliceStartFrame(nframes_t newSliceStartFrame) {
            return (region.sliceStartFrame = newSliceStartFrame);
        }

        /// Slice end frame, relative to the start of the sequence
        @property nframes_t sliceEndFrame() const { return region.sliceEndFrame; }
        /// ditto
        @property nframes_t sliceEndFrame(nframes_t newSliceEndFrame) {
            return (region.sliceEndFrame = newSliceEndFrame);
        }

        /// Number of frames in the audio data, where 1 frame contains 1 sample for each channel
        @property nframes_t nframes() const @nogc nothrow { return region.nframes; }

        /// Number of channels of the region, typically either one or two (mono or stereo)
        @property channels_t nChannels() const @nogc nothrow { return region.nChannels; }

        /// The offset, in global frames, of this region from the beginning of the session
        @property nframes_t offset() const @nogc nothrow { return region.offset; }
        /// ditto
        @property nframes_t offset(nframes_t newOffset) { return (region.offset = newOffset); }

        /// The name of this region. This will be rendered at the top of the region view.
        @property string name() const { return region.name; }

        /// Returns: A range of state objects comprising the undo history.
        ///          The back element is the most recently appended operation.
        @property auto undoHistory() { return _editStateHistory.undoHistory; }

        /// Returns: A range of state objects comprising the redo history.
        ///          The front element is the next operation to redo.
        @property auto redoHistory() { return _editStateHistory.redoHistory; }

        /// Whether this region view is currently selected by the user
        bool selected;

        /// A temporary offset value, utilized when the user is dragging the region with the mouse
        nframes_t previewOffset;

        /// An index to a temporary track, utilized when the user is dragging the region with the mouse
        size_t previewTrackIndex;

        /// Parameters for detecting the onsets in an audio sequence, specific to this region view
        OnsetParams onsetParams;

        // The edit point frame, locally indexed for this region
        nframes_t editPointOffset;

        /// Flag indiciating whether a subregion is currently selected within this region
        bool subregionSelected;

        /// The relative start frame of the selected subregion, if applicable
        @property nframes_t subregionStartFrame() const {
            return (_subregionStartFrame > sliceStartFrame) ? _subregionStartFrame - sliceStartFrame : 0;
        }
        /// ditto
        @property nframes_t subregionStartFrame(nframes_t newSubregionStartFrame) {
            return (_subregionStartFrame = newSubregionStartFrame + sliceStartFrame);
        }

        /// The relative end frame of the selected subregion, if applicable
        @property nframes_t subregionEndFrame() const {
            return _subregionEndFrame - sliceStartFrame;
        }
        /// ditto
        @property nframes_t subregionEndFrame(nframes_t newSubregionEndFrame) {
            return (_subregionEndFrame = newSubregionEndFrame + sliceStartFrame);
        }

        /// Flag indicating whether this region is currently being edited by the user.
        /// This should be true if and only if this class is referenced by the
        /// `_editRegion` member of the outer class.
        @property bool editMode() const { return _editMode; }
        /// ditto
        @property bool editMode(bool enable) {
            if(!enable) {
                _sliceChanged = false;
            }
            else if(_sliceChanged) {
                if(showOnsets) {
                    computeOnsets();
                }
                updateCurrentEditState();
            }
            return (_editMode = enable);
        }

        /// Flag indicating whether the onsets should be drawn in the region view
        @property bool showOnsets() const { return _showOnsets; }
        /// ditto
        @property bool showOnsets(bool enable) {
            if(enable) {
                if(linkChannels && _onsetsLinked is null) {
                    computeOnsetsLinkedChannels();
                }
                else if(_onsets is null) {
                    computeOnsetsIndependentChannels();
                }
            }
            return (_showOnsets = enable);
        }

        /// Flag indicating whether to display the onsets for the linked channels, or the individual channels
        @property bool linkChannels() const { return _linkChannels; }
        /// ditto
        @property bool linkChannels(bool enable) {
            if(enable) {
                computeOnsetsLinkedChannels();
            }
            else {
                computeOnsetsIndependentChannels();
            }
            return (_linkChannels = enable);
        }

        /// Returns: The bounding box for the entire region view
        @property ref const(BoundingBox) boundingBox() const { return _boundingBox; }

        /// Returns: The bounding box for the currently selected subregion, if applicable
        @property ref const(BoundingBox) subregionBox() const { return _subregionBox; }

        /// Returns: The region name
        override string toString() {
            return name;
        }

    protected:
        Region region;

    private:
        /// This constructor should only be called by a parent track when registering a new region
        this(TrackView trackView, Region region) {
            this.region = region;

            _trackView = trackView;
            _recomputeRegionGradient = true;

            _arrangeStateHistory = new StateHistory!ArrangeState(ArrangeState.emptyState());
            _editStateHistory = new StateHistory!EditState(EditState());
        }

        /// Region rendering implementation
        void _drawRegion(ref Scoped!Context cr,
                         TrackView trackView,
                         pixels_t yOffset,
                         pixels_t heightPixels,
                         nframes_t regionOffset,
                         double alpha) {
            enum degrees = PI / 180.0;

            cr.save();
            scope(exit) cr.restore();

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setAntialias(cairo_antialias_t.FAST);

            // check that this region is in the visible area of the arrange view
            if((regionOffset >= viewOffset && regionOffset < viewOffset + viewWidthSamples) ||
               (regionOffset < viewOffset &&
                (regionOffset + region.nframes >= viewOffset ||
                 regionOffset + region.nframes <= viewOffset + viewWidthSamples))) {
                // xOffset is the number of horizontal pixels, if any, to skip before the start of the waveform
                immutable pixels_t xOffset =
                    (viewOffset < regionOffset) ? (regionOffset - viewOffset) / samplesPerPixel : 0;
                pixels_t height = heightPixels;

                // calculate the width, in pixels, of the visible area of the given region
                pixels_t width;
                if(regionOffset >= viewOffset) {
                    // the region begins after the view offset, and ends within the view
                    if(regionOffset + region.nframes <= viewOffset + viewWidthSamples) {
                        width = max(region.nframes / samplesPerPixel, 2 * cornerRadius);
                    }
                    // the region begins after the view offset, and ends past the end of the view
                    else {
                        width = (viewWidthSamples - (regionOffset - viewOffset)) / samplesPerPixel;
                    }
                }
                else if(regionOffset + region.nframes >= viewOffset) {
                    // the region begins before the view offset, and ends within the view
                    if(regionOffset + region.nframes < viewOffset + viewWidthSamples) {
                        width = (regionOffset + region.nframes - viewOffset) / samplesPerPixel;
                    }
                    // the region begins before the view offset, and ends past the end of the view
                    else {
                        width = viewWidthSamples / samplesPerPixel;
                    }
                }
                else {
                    // the region is not visible
                    return;
                }

                // get the bounding box for this region
                _boundingBox.x0 = xOffset;
                _boundingBox.y0 = yOffset;
                _boundingBox.x1 = xOffset + width;
                _boundingBox.y1 = yOffset + height;

                // these variables designate whether the left and right endpoints of the given region are visible
                bool lCorners = regionOffset + (cornerRadius * samplesPerPixel) >= viewOffset;
                bool rCorners = (regionOffset + region.nframes) - (cornerRadius * samplesPerPixel) <=
                    viewOffset + viewWidthSamples;

                cr.newSubPath();
                // top left corner
                if(lCorners) {
                    cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                           cornerRadius, 180 * degrees, 270 * degrees);
                }
                else {
                    cr.moveTo(xOffset - borderWidth, yOffset);
                    cr.lineTo(xOffset + width + (rCorners ? -cornerRadius : borderWidth), yOffset);
                }

                // right corners
                if(rCorners) {
                    cr.arc(xOffset + width - cornerRadius, yOffset + cornerRadius,
                           cornerRadius, -90 * degrees, 0 * degrees);
                    cr.arc(xOffset + width - cornerRadius, yOffset + height - cornerRadius,
                           cornerRadius, 0 * degrees, 90 * degrees);
                }
                else {
                    cr.lineTo(xOffset + width + borderWidth, yOffset);
                    cr.lineTo(xOffset + width + borderWidth, yOffset + height);
                }

                // bottom left corner
                if(lCorners) {
                    cr.arc(xOffset + cornerRadius, yOffset + height - cornerRadius,
                           cornerRadius, 90 * degrees, 180 * degrees);
                }
                else {
                    cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + height);
                }
                cr.closePath();

                // if the region is muted, save the border path for later rendering operations
                cairo_path_t* borderPath;
                if(region.mute) {
                    borderPath = cr.copyPath();
                }

                // fill the region background with a gradient
                if(yOffset != _prevYOffset || height != _prevHeight || _recomputeRegionGradient) {
                    _recomputeRegionGradient = false;

                    enum gradientScale1 = 0.80;
                    enum gradientScale2 = 0.65;

                    if(_regionGradient) {
                        _regionGradient.destroy();
                    }
                    _regionGradient = Pattern.createLinear(0, yOffset, 0, yOffset + height);
                    _regionGradient.addColorStopRgba(0,
                                                     trackView.color.r * gradientScale1,
                                                     trackView.color.g * gradientScale1,
                                                     trackView.color.b * gradientScale1,
                                                     alpha);
                    _regionGradient.addColorStopRgba(1,
                                                     trackView.color.r - gradientScale2,
                                                     trackView.color.g - gradientScale2,
                                                     trackView.color.b - gradientScale2,
                                                     alpha);
                }
                _prevYOffset = yOffset;
                _prevHeight = height;
                cr.setSource(_regionGradient);
                cr.fillPreserve();

                // if this region is in edit mode or selected, highlight the borders and region header
                cr.setLineWidth(borderWidth);
                if(editMode) {
                    cr.setSourceRgba(1.0, 1.0, 0.0, alpha);
                }
                else if(selected) {
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                }
                else {
                    cr.setSourceRgba(0.5, 0.5, 0.5, alpha);
                }
                cr.stroke();
                if(selected) {
                    cr.newSubPath();
                    // left corner
                    if(lCorners) {
                        cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                               cornerRadius, 180 * degrees, 270 * degrees);
                    }
                    else {
                        cr.moveTo(xOffset - borderWidth, yOffset);
                        cr.lineTo(xOffset + width + (rCorners ? -cornerRadius : borderWidth), yOffset);
                    }

                    // right corner
                    if(rCorners) {
                        cr.arc(xOffset + width - cornerRadius, yOffset + cornerRadius,
                               cornerRadius, -90 * degrees, 0 * degrees);
                    }
                    else {
                        cr.lineTo(xOffset + width + borderWidth, yOffset);
                    }

                    // bottom
                    cr.lineTo(xOffset + width + (rCorners ? 0 : borderWidth), yOffset + headerHeight);
                    cr.lineTo(xOffset - (lCorners ? 0 : borderWidth), yOffset + headerHeight);
                    cr.closePath();
                    cr.fill();
                }

                // draw the region's label
                if(!_regionHeaderLabelLayout) {
                    PgFontDescription desc;
                    _regionHeaderLabelLayout = PgCairo.createLayout(cr);
                    desc = PgFontDescription.fromString(headerFont);
                    _regionHeaderLabelLayout.setFontDescription(desc);
                    desc.free();
                }

                void drawRegionLabel() {
                    if(selected) {
                        enum labelColorScale = 0.5;
                        cr.setSourceRgba(trackView.color.r * labelColorScale,
                                         trackView.color.g * labelColorScale,
                                         trackView.color.b * labelColorScale, alpha);
                    }
                    else {
                        cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    }
                    PgCairo.updateLayout(cr, _regionHeaderLabelLayout);
                    PgCairo.showLayout(cr, _regionHeaderLabelLayout);
                }

                {
                    cr.save();
                    scope(exit) cr.restore();

                    enum labelPadding = borderWidth + 1;
                    int labelWidth, labelHeight;
                    labelWidth += labelPadding;
                    _regionHeaderLabelLayout.setText(region.mute ? region.name ~ " (muted)" : region.name);
                    _regionHeaderLabelLayout.getPixelSize(labelWidth, labelHeight);
                    if(xOffset == 0 && regionOffset < viewOffset && labelWidth + labelPadding > width) {
                        cr.translate(xOffset - (labelWidth - width), yOffset);
                        drawRegionLabel();
                    }
                    else if(labelWidth <= width || regionOffset + region.nframes > viewOffset + viewWidthSamples) {
                        cr.translate(xOffset + labelPadding, yOffset);
                        drawRegionLabel();
                    }
                }

                // height of the area containing the waveform, in pixels
                height = heightPixels - headerHeight;
                // y-coordinate in pixels where the waveform rendering begins
                pixels_t bodyYOffset = yOffset + headerHeight;
                // pixelsOffset is the screen-space x-coordinate at which to begin rendering the waveform
                pixels_t pixelsOffset =
                    (viewOffset > regionOffset) ? (viewOffset - regionOffset) / samplesPerPixel : 0;
                // height of each channel in pixels
                pixels_t channelHeight = height / region.nChannels;

                // prepare to render audio that the user is currently stretching (by moving an onset)
                bool moveOnset;                
                pixels_t onsetPixelsStart,
                    onsetPixelsCenterSrc,
                    onsetPixelsCenterDest,
                    onsetPixelsEnd;
                double firstScaleFactor, secondScaleFactor;
                if(editMode && _editRegion == this && _action == Action.moveOnset) {
                    moveOnset = true;
                    long onsetViewOffset = (viewOffset > regionOffset) ? cast(long)(viewOffset) : 0;
                    long onsetRegionOffset = (viewOffset > regionOffset) ? cast(long)(regionOffset) : 0;
                    long onsetFrameStart, onsetFrameEnd, onsetFrameSrc, onsetFrameDest;

                    onsetFrameStart = onsetRegionOffset + getPrevOnset(_moveOnsetIndex, _moveOnsetChannel);
                    onsetFrameEnd = onsetRegionOffset + getNextOnset(_moveOnsetIndex, _moveOnsetChannel);
                    onsetFrameSrc = onsetRegionOffset + _moveOnsetFrameSrc;
                    onsetFrameDest = onsetRegionOffset + _moveOnsetFrameDest;
                    onsetPixelsStart =
                        cast(pixels_t)((onsetFrameStart - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsCenterSrc =
                        cast(pixels_t)((onsetFrameSrc - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsCenterDest =
                        cast(pixels_t)((onsetFrameDest - onsetViewOffset) / samplesPerPixel);
                    onsetPixelsEnd =
                        cast(pixels_t)((onsetFrameEnd - onsetViewOffset) / samplesPerPixel);
                    firstScaleFactor = (onsetFrameSrc > onsetFrameStart) ?
                        (cast(double)(onsetFrameDest - onsetFrameStart) /
                         cast(double)(onsetFrameSrc - onsetFrameStart)) : 0;
                    secondScaleFactor = (onsetFrameEnd > onsetFrameSrc) ?
                        (cast(double)(onsetFrameEnd - onsetFrameDest) /
                         cast(double)(onsetFrameEnd - onsetFrameSrc)) : 0;
                }

                enum OnsetDrawState { init, firstHalf, secondHalf, complete }
                OnsetDrawState onsetDrawState;

                // precompute the cache index for the current zoom level
                auto cacheIndex = Region.getCacheIndex(_zoomBinSize());
                if(cacheIndex.isNull()) {
                    // TODO implement a logger
                    //derr.writefln("Warning: invalid cache index for bin size " ~ to!string(_zoomBinSize()));
                    return;
                }

                // draw the region's waveform
                auto channelYOffset = bodyYOffset + (channelHeight / 2);
                for(channels_t channelIndex = 0; channelIndex < region.nChannels; ++channelIndex) {
                    pixels_t startPixel = (moveOnset && onsetPixelsStart < 0 && firstScaleFactor != 0) ?
                        max(cast(pixels_t)(onsetPixelsStart / firstScaleFactor), onsetPixelsStart) : 0;
                    pixels_t endPixel = (moveOnset && onsetPixelsEnd > width && secondScaleFactor != 0) ?
                        min(cast(pixels_t)((onsetPixelsEnd - width) / secondScaleFactor),
                            onsetPixelsEnd - width) : 0;

                    cr.newSubPath();
                    try {
                        cr.moveTo(xOffset, channelYOffset +
                                  region.getMax(channelIndex,
                                                cacheIndex,
                                                samplesPerPixel,
                                                pixelsOffset + startPixel) * (channelHeight / 2));
                    }
                    catch(RangeError) {
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1 + startPixel; i < width + endPixel; ++i) {
                        pixels_t scaledI = i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || linkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(i >= onsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                        goto case;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(i >= onsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                        goto case;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(onsetPixelsStart +
                                                                 (i - onsetPixelsStart) * firstScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(i >= onsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)(onsetPixelsCenterDest +
                                                                 (i - onsetPixelsCenterSrc) * secondScaleFactor);

                                    }
                                    break;

                                default:
                                    break;
                            }
                        }
                        try {
                            cr.lineTo(xOffset + scaledI, channelYOffset -
                                      clamp(region.getMax(channelIndex,
                                                          cacheIndex,
                                                          samplesPerPixel,
                                                          pixelsOffset + i), 0, 1) * (channelHeight / 2));
                        }
                        catch(RangeError) {
                        }
                    }
                    if(moveOnset) {
                        onsetDrawState = OnsetDrawState.init;
                    }
                    for(auto i = 1 - endPixel; i <= width - startPixel; ++i) {
                        pixels_t scaledI = width - i;
                        if(moveOnset && (channelIndex == _moveOnsetChannel || linkChannels)) {
                            switch(onsetDrawState) {
                                case OnsetDrawState.init:
                                    if(width - i <= onsetPixelsEnd) {
                                        onsetDrawState = OnsetDrawState.secondHalf;
                                        goto case;
                                    }
                                    else {
                                        break;
                                    }

                                case OnsetDrawState.secondHalf:
                                    if(width - i <= onsetPixelsCenterSrc) {
                                        onsetDrawState = OnsetDrawState.firstHalf;
                                        goto case;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (onsetPixelsCenterDest +
                                             ((width - i) - onsetPixelsCenterSrc) * secondScaleFactor);
                                        break;
                                    }

                                case OnsetDrawState.firstHalf:
                                    if(width - i <= onsetPixelsStart) {
                                        onsetDrawState = OnsetDrawState.complete;
                                    }
                                    else {
                                        scaledI = cast(pixels_t)
                                            (onsetPixelsStart +
                                             ((width - i) - onsetPixelsStart) * firstScaleFactor);
                                    }
                                    break;

                                default:
                                    break;
                            }
                        }
                        try {
                            cr.lineTo(xOffset + scaledI, channelYOffset -
                                      clamp(region.getMin(channelIndex,
                                                          cacheIndex,
                                                          samplesPerPixel,
                                                          pixelsOffset + width - i), -1, 0) * (channelHeight / 2));
                        }
                        catch(RangeError) {
                        }
                    }
                    cr.closePath();
                    cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                    cr.fill();
                    channelYOffset += channelHeight;
                }

                if(editMode) {
                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.setLineWidth(1.0);

                    // draw the onsets
                    if(showOnsets) {
                        if(linkChannels) {
                            foreach(onsetIndex, onset; _onsetsLinked[].enumerate) {
                                auto onsetFrame = (_action == Action.moveOnset && onsetIndex == _moveOnsetIndex) ?
                                    _moveOnsetFrameDest : onset.onsetFrame;
                                if(onsetFrame + regionOffset >= viewOffset &&
                                   onsetFrame + regionOffset < viewOffset + viewWidthSamples) {
                                    cr.moveTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                              bodyYOffset);
                                    cr.lineTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                              bodyYOffset + height);
                                }
                            }
                        }
                        else {
                            foreach(channelIndex, channel; _onsets) {
                                foreach(onsetIndex, onset; channel[].enumerate) {
                                    auto onsetFrame = (_action == Action.moveOnset &&
                                                       channelIndex == _moveOnsetChannel &&
                                                       onsetIndex == _moveOnsetIndex) ?
                                        _moveOnsetFrameDest : onset.onsetFrame;
                                    if(onsetFrame + regionOffset >= viewOffset &&
                                       onsetFrame + regionOffset < viewOffset + viewWidthSamples) {
                                        cr.moveTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                                  bodyYOffset +
                                                  cast(pixels_t)((channelIndex * channelHeight)));
                                        cr.lineTo(xOffset + onsetFrame / samplesPerPixel - pixelsOffset,
                                                  bodyYOffset +
                                                  cast(pixels_t)(((channelIndex + 1) * channelHeight)));
                                    }
                                }
                            }
                        }

                        cr.setSourceRgba(1.0, 1.0, 1.0, alpha);
                        cr.stroke();
                    }

                    // draw the subregion selection box
                    if(subregionSelected || _action == Action.selectSubregion) {
                        cr.setOperator(cairo_operator_t.OVER);
                        cr.setAntialias(cairo_antialias_t.NONE);

                        immutable pixels_t x0 = xOffset + subregionStartFrame / samplesPerPixel - pixelsOffset;
                        immutable pixels_t x1 = xOffset + subregionEndFrame / samplesPerPixel - pixelsOffset;
                        cr.rectangle(x0, yOffset, x1 - x0, headerHeight + height);
                        cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                        cr.fill();

                        // compute the bounding box for the selected subregion
                        _subregionBox.x0 = x0;
                        _subregionBox.y0 = yOffset;
                        _subregionBox.x1 = x1;
                        _subregionBox.y1 = yOffset + headerHeight + height;
                    }

                    // draw the edit point
                    if(editPointOffset + regionOffset >= viewOffset &&
                       editPointOffset + regionOffset < viewOffset + viewWidthSamples) {
                        enum editPointLineWidth = 1;
                        enum editPointWidth = 16;

                        cr.setLineWidth(editPointLineWidth);
                        cr.setSourceRgba(0.0, 1.0, 0.5, alpha);

                        immutable pixels_t editPointXPixel =
                            xOffset + editPointOffset / samplesPerPixel - pixelsOffset;

                        cr.moveTo(editPointXPixel - editPointWidth / 2, yOffset);
                        cr.lineTo(editPointXPixel - editPointWidth / 2, yOffset + headerHeight);
                        cr.lineTo(editPointXPixel, yOffset + headerHeight / 2);
                        cr.closePath();
                        cr.fill();

                        cr.moveTo(editPointXPixel + editPointLineWidth + editPointWidth / 2, yOffset);
                        cr.lineTo(editPointXPixel + editPointLineWidth + editPointWidth / 2, yOffset + headerHeight);
                        cr.lineTo(editPointXPixel + editPointLineWidth, yOffset + headerHeight / 2);
                        cr.closePath();
                        cr.fill();

                        cr.moveTo(editPointXPixel, yOffset);
                        cr.lineTo(editPointXPixel, yOffset + headerHeight + height);

                        cr.stroke();
                    }
                }

                // if the region is muted, gray it out
                if(region.mute) {
                    cr.setOperator(cairo_operator_t.OVER);
                    cr.appendPath(borderPath);
                    cr.setSourceRgba(0.5, 0.5, 0.5, 0.6);
                    cr.fill();
                    Context.pathDestroy(borderPath);
                }
            }
        }

        StateHistory!ArrangeState _arrangeStateHistory;
        StateHistory!EditState _editStateHistory;

        TrackView _trackView;
        bool _recomputeRegionGradient;

        bool _editMode;
        bool _sliceChanged;
        bool _showOnsets;
        bool _linkChannels;

        nframes_t _subregionStartFrame; /// Start frame when sliceStart == 0
        nframes_t _subregionEndFrame; /// End frame when sliceStart == 0

        OnsetSequence[] _onsets; /// Indexed as [channel][onset]
        OnsetSequence _onsetsLinked; /// Indexed as [onset]

        Pattern _regionGradient;
        pixels_t _prevYOffset;
        pixels_t _prevHeight;

        BoundingBox _boundingBox;
        BoundingBox _subregionBox;
    }

    /// Generic button that can be drawn on a track stub.
    /// This is useful for functions such as mute/solo.
    abstract class TrackButton {
    public:
        enum buttonWidth = 20;
        enum buttonHeight = 20;
        enum cornerRadius = 4;

        this(Track track, bool roundedLeftEdges = true, bool roundedRightEdges = true) {
            _track = track;
            this.roundedLeftEdges = roundedLeftEdges;
            this.roundedRightEdges = roundedRightEdges;
        }

        final void draw(ref Scoped!Context cr, pixels_t xOffset, pixels_t yOffset) {
            alias labelPadding = TrackStubs.labelPadding;

            enum degrees = PI / 180.0;

            immutable Color gradientTop = Color(0.5, 0.5, 0.5);
            immutable Color gradientBottom = Color(0.2, 0.2, 0.2);
            immutable Color pressedGradientTop = Color(0.4, 0.4, 0.4);
            immutable Color pressedGradientBottom = Color(0.6, 0.6, 0.6);

            _boundingBox.x0 = xOffset;
            _boundingBox.y0 = yOffset;
            _boundingBox.x1 = xOffset + buttonWidth;
            _boundingBox.y1 = yOffset + buttonHeight;

            cr.save();
            scope(exit) cr.restore();

            cr.setAntialias(cairo_antialias_t.GRAY);
            cr.setLineWidth(1.0);

            // draw the button
            cr.newSubPath();
            // top left corner
            if(roundedLeftEdges) {
                cr.arc(xOffset + cornerRadius, yOffset + cornerRadius,
                       cornerRadius, 180 * degrees, 270 * degrees);
            }
            else {
                cr.moveTo(xOffset, yOffset);
                cr.lineTo(xOffset + buttonWidth + (roundedRightEdges ? -cornerRadius : 0), yOffset);
            }

            // right corners
            if(roundedRightEdges) {
                cr.arc(xOffset + buttonWidth - cornerRadius, yOffset + cornerRadius,
                       cornerRadius, -90 * degrees, 0 * degrees);
                cr.arc(xOffset + buttonWidth - cornerRadius, yOffset + buttonHeight - cornerRadius,
                       cornerRadius, 0 * degrees, 90 * degrees);
            }
            else {
                cr.lineTo(xOffset + buttonWidth, yOffset);
                cr.lineTo(xOffset + buttonWidth, yOffset + buttonHeight);
            }

            // bottom left corner
            if(roundedLeftEdges) {
                cr.arc(xOffset + cornerRadius, yOffset + buttonHeight - cornerRadius,
                       cornerRadius, 90 * degrees, 180 * degrees);
            }
            else {
                cr.lineTo(xOffset, yOffset + buttonHeight);
            }
            cr.closePath();

            // if the button is inactive, save the border path for later rendering operations
            cairo_path_t* borderPath;
            if(!active) {
                borderPath = cr.copyPath();
            }

            Pattern buttonGradient = Pattern.createLinear(0, yOffset, 0, yOffset + buttonHeight);
            scope(exit) buttonGradient.destroy();
            Color processedGradientTop = (pressed || enabled) ? pressedGradientTop : gradientTop;
            Color processedGradientBottom = (pressed || enabled) ? pressedGradientBottom : gradientBottom;
            if(pressed || enabled) {
                processedGradientTop = processedGradientTop * enabledColor;
                processedGradientBottom = processedGradientBottom * enabledColor;
            }
            buttonGradient.addColorStopRgb(0,
                                           processedGradientTop.r,
                                           processedGradientTop.g,
                                           processedGradientTop.b);
            buttonGradient.addColorStopRgb(1,
                                           processedGradientBottom.r,
                                           processedGradientBottom.g,
                                           processedGradientBottom.b);
            cr.setSource(buttonGradient);
            cr.fillPreserve();

            cr.setSourceRgb(0.15, 0.15, 0.15);
            cr.stroke();

            // draw the button's text
            if(!_trackButtonLayout) {
                PgFontDescription desc;
                _trackButtonLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(TrackStubs.buttonFont);
                _trackButtonLayout.setFontDescription(desc);
                desc.free();
            }

            _trackButtonLayout.setText(buttonText);
            int widthPixels, heightPixels;
            _trackButtonLayout.getPixelSize(widthPixels, heightPixels);
            cr.moveTo(xOffset + buttonWidth / 2 - widthPixels / 2,
                      yOffset + buttonHeight / 2 - heightPixels / 2);
            cr.setSourceRgb(1.0, 1.0, 1.0);
            PgCairo.updateLayout(cr, _trackButtonLayout);
            PgCairo.showLayout(cr, _trackButtonLayout);

            // if the button is inactive, gray it out
            if(!active) {
                cr.setOperator(cairo_operator_t.OVER);
                cr.appendPath(borderPath);
                cr.setSourceRgba(0.5, 0.5, 0.5, 0.6);
                cr.fill();
                Context.pathDestroy(borderPath);
            }
        }

        /// The track object associated with this button
        @property Track track() { return _track; }
        /// ditto
        @property Track track(Track newTrack) { return (_track = newTrack); }

        /// Whether this button is accepting input from the user
        @property bool active() const { return _active; }
        /// ditto
        @property bool active(bool setActive) { return (_active = setActive); }

        /// Whether the user has the mouse button pressed while hovering over this button.
        @property bool pressed() const { return _pressed; }
        /// ditto
        @property bool pressed(bool setPressed) { return (_pressed = setPressed); }

        /// Whether this button should enable its function
        @property bool enabled() const { return _enabled; }
        /// ditto
        @property bool enabled(bool setEnabled) {
            _enabled = setEnabled;
            onEnabled(setEnabled);
            return _enabled;
        }

        /// Call this function when the user enables a button contrary to this button.
        /// An example of this would be left/right solo buttons.
        /// This function avoids starting a circular call chain.
        final void otherEnabled() {
            _enabled = false;
            onOtherEnabled();
        }

        /// Returns: A bounding box for this button
        @property ref const(BoundingBox) boundingBox() const { return _boundingBox; }

    protected:
        /// Called when the `enabled` property is modified
        void onEnabled(bool enabled) {
        }

        /// Called when the `otherEnabled` member function is invoked
        void onOtherEnabled() {
        }

        /// Returns: The text to draw inside this button
        @property string buttonText() const;

        /// Returns: The color to shade this button when it is enabled
        @property Color enabledColor() const { return Color(1.0, 1.0, 1.0); }

        /// Whether the left edges of this button should be rounded
        immutable bool roundedLeftEdges;

        /// Whether the right edges of this button should be rounded
        immutable bool roundedRightEdges;

    private:
        Track _track;

        bool _active = true;
        bool _pressed;
        bool _enabled;

        PgLayout _trackButtonLayout;

        BoundingBox _boundingBox;
    }

    /// A button class for muting a track
    final class MuteButton : TrackButton {
    public:
        this(Track track) {
            super(track, true, false);
        }

    protected:
        override void onEnabled(bool enabled) {
            if(track !is null) {
                track.mute = enabled;
            }
        }

        @property override string buttonText() const { return "M"; }
        @property override Color enabledColor() const { return Color(0.0, 1.0, 1.0); }
    }

    /// A button class for soloing a track
    final class SoloButton : TrackButton {
    public:
        this(Track track) {
            super(track, false, true);
        }

    protected:
        override void onEnabled(bool enabled) {
            if(track !is null) {
                track.solo = enabled;
            }
            if(enabled) {
                _mixer.soloTrack = true;
            }
            else {
                foreach(trackView; _trackViews) {
                    if(trackView.solo) {
                        return;
                    }
                }
                _mixer.soloTrack = false;
            }
        }

        @property override string buttonText() const { return "S"; }
        @property override Color enabledColor() const { return Color(1.0, 1.0, 0.0); }
    }

    /// A button class for soloing the left channel of a track
    final class LeftButton : TrackButton {
    public:
        this(Track track) {
            super(track, true, false);
        }

        /// Should be set to the right button instance
        TrackButton other;

    protected:
        override void onEnabled(bool enabled) {
            if(track !is null) {
                track.leftSolo = enabled;
            }
            if(other !is null) {
                other.otherEnabled();
            }
        }

        override void onOtherEnabled() {
            if(track !is null) {
                track.leftSolo = false;
            }
        }

        @property override string buttonText() const { return "L"; }
        @property override Color enabledColor() const { return Color(1.0, 0.65, 0.0); }
    }

    /// A button class for soloing the right channel of a track
    final class RightButton : TrackButton {
    public:
        this(Track track) {
            super(track, false, true);
        }

        /// Should be set to the left button instance
        TrackButton other;

    protected:
        override void onEnabled(bool enabled) {
            if(track !is null) {
                track.rightSolo = enabled;
            }
            if(other !is null) {
                other.otherEnabled();
            }
        }

        override void onOtherEnabled() {
            if(track !is null) {
                track.rightSolo = false;
            }
        }

        @property override string buttonText() const { return "R"; }
        @property override Color enabledColor() const { return Color(1.0, 0.65, 0.0); }
    }

    /// Interface for drawing a channel with a fader and meter
    interface ChannelView {
        /// This function is useful to allow the meters to smoothly return to -infinity
        /// after the mixer has stopped playing, since the `processMeter` member function
        /// will no longer be called when the mixer stops playing.
        void processSilence(nframes_t bufferLength);

        /// Reset the meter for the left channel to its initial state
        void resetMeterLeft() @nogc nothrow;

        /// Reset the meter for the right channel to its initial state
        void resetMeterRight() @nogc nothrow;

        /// Reset the meters for both the left and right channels to their initial states
        void resetMeters() @nogc nothrow;

        /// Returns: The maximum sample values for the left and right channels
        ///          since the last call to this function.
        ///          This ensures that level peaks are properly rendered, since the UI most likely refreshes
        ///          at a slower rate than the meter processes incoming audio buffers.
        @property const(sample_t[2]) level();

        /// Returns: The maximum sample values for detected peaks for the left and right channels.
        @property ref const(sample_t[2]) peakMax();

        /// The fader gain (analogous to an analog mixer) for this channel's stereo output, in dBFS
        @property sample_t faderGainDB() const @nogc nothrow;
        /// ditto
        @property sample_t faderGainDB(sample_t db);

        /// The name of the channel. This will be rendered at the top of the channel strip.
        @property string name() const;
    }

    /// A channel view subclass for the master bus
    final class MasterBusView : ChannelView {
    public:
        enum masterBusName = "Master";

        this() {
            _channelStrip = new ChannelStrip(this);
        }

        override void processSilence(nframes_t bufferLength) { _mixer.masterBus.processSilence(bufferLength); }
        @property override const(sample_t[2]) level() { return _mixer.masterBus.level; }
        @property override ref const(sample_t[2]) peakMax() { return _mixer.masterBus.peakMax; }

        override void resetMeterLeft() @nogc nothrow { _mixer.masterBus.resetMeterLeft(); }
        override void resetMeterRight() @nogc nothrow { _mixer.masterBus.resetMeterRight(); }
        override void resetMeters() @nogc nothrow { _mixer.masterBus.resetMeters(); }
        @property override sample_t faderGainDB() const @nogc nothrow { return _mixer.masterBus.faderGainDB; }
        @property override sample_t faderGainDB(sample_t db) { return (_mixer.masterBus.faderGainDB = db); }

        @property override string name() const { return masterBusName; }

        @property ChannelStrip channelStrip() { return _channelStrip; }

    private:
        ChannelStrip _channelStrip;
    }

    /// A channel view subclass for audio tracks
    final class TrackView : ChannelView {
    public:
        /// Create a new `RegionView` and register it with this track
        /// Params:
        /// region = The region to associate with the new `RegionView`
        /// addSoftLink = Whether to add a soft link to `region` to the source audio sequence
        RegionView createRegion(Region region, bool addSoftLink = true) {
            auto newRegionView = new RegionView(this, region);
            if(addSoftLink) {
                newRegionView.addSoftLinkToSequence();
            }

            _track.registerRegion(newRegionView.region);

            if(newRegionView.trackView !is this) {
                newRegionView._trackView = this;
            }
            _regionViews ~= newRegionView;
            this.outer._regionViews ~= newRegionView;

            _hScroll.reconfigure();
            _vScroll.reconfigure();

            return newRegionView;
        }

        /// Register a region (via its view) with the underlying track object.
        void registerRegion(RegionView regionView) {
            _track.registerRegion(regionView.region);
        }

        /// Unregister a region (via its view) with the underlying track object.
        void unregisterRegion(RegionView regionView) {
            _track.unregisterRegion(regionView.region);
        }

        /// Draw all regions registered with this track
        void drawRegions(ref Scoped!Context cr, pixels_t yOffset) {
            foreach(regionView; _regionViews) {
                if(_action == Action.moveRegion && regionView.selected) {
                    regionView.drawRegionMoving(cr, yOffset);
                }
                else {
                    regionView.drawRegion(cr, yOffset);
                }
            }
        }

        /// The the stub for this track.
        /// A track stub renders the track name and buttons for track functions such as mute/solo.
        void drawStub(ref Scoped!Context cr,
                      pixels_t yOffset,
                      size_t trackIndex,
                      pixels_t trackNumberWidth) {
            alias labelPadding = TrackStubs.labelPadding;

            immutable Color selectedGradientTop = Color(0.5, 0.5, 0.5);
            immutable Color selectedGradientBottom = Color(0.3, 0.3, 0.3);
            immutable Color gradientTop = Color(0.2, 0.2, 0.2);
            immutable Color gradientBottom = Color(0.15, 0.15, 0.15);

            cr.save();
            scope(exit) cr.restore();

            cr.setOperator(cairo_operator_t.OVER);

            // compute the bounding box for this track stub
            _stubBox.x0 = 0;
            _stubBox.x1 = _trackStubWidth;
            _stubBox.y0 = yOffset;
            _stubBox.y1 = yOffset + heightPixels;

            // draw the track stub background
            cr.rectangle(0, yOffset, _trackStubWidth, heightPixels);
            Pattern trackGradient = Pattern.createLinear(0, yOffset, 0, yOffset + heightPixels);
            scope(exit) trackGradient.destroy();
            if(this is _selectedTrack) {
                trackGradient.addColorStopRgb(0,
                                              selectedGradientTop.r,
                                              selectedGradientTop.g,
                                              selectedGradientTop.b);
                trackGradient.addColorStopRgb(1,
                                              selectedGradientBottom.r,
                                              selectedGradientBottom.g,
                                              selectedGradientBottom.b);
            }
            else {
                trackGradient.addColorStopRgb(0,
                                              gradientTop.r,
                                              gradientTop.g,
                                              gradientTop.b);
                trackGradient.addColorStopRgb(1,
                                              gradientBottom.r,
                                              gradientBottom.g,
                                              gradientBottom.b);
            }
            cr.setSource(trackGradient);
            cr.fill();

            cr.setSourceRgb(1.0, 1.0, 1.0);

            // draw the numeric track index
            {
                cr.save();
                scope(exit) cr.restore();

                _trackLabelLayout.setText(to!string(trackIndex + 1));
                int labelWidth, labelHeight;
                _trackLabelLayout.getPixelSize(labelWidth, labelHeight);
                cr.translate(trackNumberWidth / 2 - labelWidth / 2,
                             yOffset + heightPixels / 2 - labelHeight / 2);
                PgCairo.updateLayout(cr, _trackLabelLayout);
                PgCairo.showLayout(cr, _trackLabelLayout);
            }

            immutable pixels_t xOffset = trackNumberWidth + labelPadding * 2;

            // draw the track label
            _minHeightPixels = 0;
            pixels_t trackLabelHeight;
            {
                cr.save();
                scope(exit) cr.restore();

                _trackLabelLayout.setText(name);
                int labelWidth, labelHeight;
                _trackLabelLayout.getPixelSize(labelWidth, labelHeight);
                trackLabelHeight = cast(pixels_t)(labelHeight);
                _minHeightPixels += labelHeight + (labelPadding / 2);
                cr.translate(xOffset, yOffset + heightPixels / 2 - (labelHeight + labelPadding / 2));
                PgCairo.updateLayout(cr, _trackLabelLayout);
                PgCairo.showLayout(cr, _trackLabelLayout);
            }

            // draw the mute/solo buttons
            pixels_t buttonXOffset = xOffset;
            pixels_t buttonYOffset = yOffset + heightPixels / 2 + labelPadding / 2;
            _trackButtonStrip.draw(cr, buttonXOffset, buttonYOffset);
            _minHeightPixels += TrackButton.buttonWidth + (labelPadding / 2);

            // draw separators
            {
                cr.save();
                scope(exit) cr.restore();

                // draw a separator above the first track
                if(trackIndex == 0) {
                    cr.moveTo(0, yOffset);
                    cr.lineTo(_trackStubWidth, yOffset);
                }

                // draw vertical separator
                cr.moveTo(trackNumberWidth, yOffset);
                cr.lineTo(trackNumberWidth, yOffset + heightPixels);

                // draw bottom horizontal separator
                cr.moveTo(0, yOffset + heightPixels);
                cr.lineTo(_trackStubWidth, yOffset + heightPixels);

                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.stroke();
            }
        }

        /// A collection of track buttons containing mute/solo and left/right solo buttons
        final class TrackButtonStrip {
        public:
            this(Track track) {
                muteButton = new MuteButton(track);
                soloButton = new SoloButton(track);

                leftButton = new LeftButton(track);
                rightButton = new RightButton(track);
                leftButton.other = rightButton;
                rightButton.other = leftButton;
            }

            void drawMuteSolo(ref Scoped!Context cr, pixels_t xOffset, pixels_t yOffset) {
                muteButton.draw(cr, xOffset, yOffset);
                soloButton.draw(cr, xOffset + TrackButton.buttonWidth, yOffset);
            }

            void drawLeftRight(ref Scoped!Context cr, pixels_t xOffset, pixels_t yOffset) {
                leftButton.draw(cr, xOffset, yOffset);
                rightButton.draw(cr, xOffset + TrackButton.buttonWidth, yOffset);
            }

            void draw(ref Scoped!Context cr, pixels_t xOffset, pixels_t yOffset) {
                enum buttonGroupSeparation = 15;

                drawMuteSolo(cr, xOffset, yOffset);
                xOffset += TrackButton.buttonWidth * 2 + buttonGroupSeparation;
                drawLeftRight(cr, xOffset, yOffset);
            }

            /// Returns: A list of all buttons associated with the button strip
            @property TrackButton[] trackButtons() {
                return [muteButton, soloButton, leftButton, rightButton];
            }

            MuteButton muteButton;
            SoloButton soloButton;

            LeftButton leftButton;
            RightButton rightButton;
        }

        /// Returns: A list of all buttons associated with this track's button strip
        @property TrackButton[] trackButtons() {
            return _trackButtonStrip.trackButtons;
        }

        /// Returns: The button strip associated with this track
        @property TrackButtonStrip trackButtonStrip() {
            return _trackButtonStrip;
        }

        /// Whether the track is muted
        @property bool mute() const { return _track.mute; }

        /// Whether the track is currently in solo mode
        @property bool solo() const { return _track.solo; }

        /// The channel strip object associated with this track
        @property ChannelStrip channelStrip() { return _channelStrip; }

        override void processSilence(nframes_t bufferLength) { _track.processSilence(bufferLength); }
        @property override const(sample_t[2]) level() { return _track.level; }
        @property override ref const(sample_t[2]) peakMax() const { return _track.peakMax; }

        override void resetMeterLeft() @nogc nothrow { _track.resetMeterLeft(); }
        override void resetMeterRight() @nogc nothrow { _track.resetMeterRight(); }
        override void resetMeters() @nogc nothrow { _track.resetMeters(); }
        @property override sample_t faderGainDB() const @nogc nothrow { return _track.faderGainDB; }
        @property override sample_t faderGainDB(sample_t db) { return (_track.faderGainDB = db); }

        /// Returns: `true` if and only if the given vertical scale factor yields a valid zoom level
        bool validZoom(float verticalScaleFactor) {
            return cast(pixels_t)(max(_baseHeightPixels * verticalScaleFactor, RegionView.headerHeight)) >=
                minHeightPixels;
        }

        /// Returns: The height of the track stub, in pixels
        @property pixels_t heightPixels() const {
            return cast(pixels_t)(max(_baseHeightPixels * _verticalScaleFactor, RegionView.headerHeight));
        }

        /// Returns: The minimum height for this track stub, in pixels
        @property pixels_t minHeightPixels() const { return _minHeightPixels; }

        /// Array all region views registered with this track
        @property RegionView[] regionViews() { return _regionViews; }
        /// ditto
        @property RegionView[] regionViews(RegionView[] newRegionViews) { return (_regionViews = newRegionViews); }

        /// The name of this track, rendered in the track stub and channel strip
        @property override string name() const { return _name; }
        /// ditto
        @property string name(string newName) { return (_name = newName); }

        /// Returns: A bounding box for the track stub
        @property ref const(BoundingBox) stubBox() const { return _stubBox; }

        /// The color of all regions in this track
        @property Color color() { return _trackColor; }

        /// Returns: The name of this track
        override string toString() {
            return name;
        }

    private:
        /// Params:
        /// track = The track object to associate with this track view
        /// heightPixels = the initial height in pixels for the track stub,
        ///                and all regions with this track as a parent
        /// name = The name of this track, rendered in the track stub and channel strip
        this(Track track, pixels_t heightPixels, string name) {
            _track = track;
            _channelStrip = new ChannelStrip(this);

            _baseHeightPixels = heightPixels;
            _trackColor = _newTrackColor();
            _name = name;

            _trackButtonStrip = new TrackButtonStrip(_track);
        }

        /// Generate a random color for new tracks
        static Color _newTrackColor() {
            Color color;
            Random gen;
            auto i = uniform(0, 2);
            auto j = uniform(0, 2);
            auto k = uniform(0, 5);

            color.r = (i == 0) ? 1 : 0;
            color.g = (j == 0) ? 1 : 0;
            color.b = (j == 1) ? 1 : 0;
            color.g = (color.g == 0 && k == 0) ? 1 : color.g;
            color.b = (color.b == 0 && k == 1) ? 1 : color.b;

            if(uniform(0, 2)) color.r *= uniform(0.8, 1.0);
            if(uniform(0, 2)) color.g *= uniform(0.8, 1.0);
            if(uniform(0, 2)) color.b *= uniform(0.8, 1.0);

            return color;
        }
 
        Track _track;
        ChannelStrip _channelStrip;
        RegionView[] _regionViews;

        pixels_t _baseHeightPixels;
        pixels_t _minHeightPixels;
        Color _trackColor;
        string _name;

        TrackButtonStrip _trackButtonStrip;

        BoundingBox _stubBox;
    }

    /// Class to facilitate rendering a fader and meter for a channel
    final class ChannelStrip {
    public:
        immutable Duration peakHoldTime = 1500.msecs; /// Amount of time to maintain meter peak levels

        enum channelStripWidth = defaultChannelStripWidth; /// Use a static pixel width for all channel strips
        enum channelStripLabelFont = "Arial 8";

        enum meterHeightPixels = 300;
        enum meterChannelWidthPixels = 8;
        enum meterWidthPixels = meterChannelWidthPixels * 2 + 4;
        enum meterMarkFont = "Arial 7";

        enum faderBackgroundWidthPixels = 6;
        enum faderWidthPixels = 20;
        enum faderHeightPixels = 40;
        enum faderCornerRadiusPixels = 4;

        /// Decibel marks to draw when 0 dB is the maximum level
        static immutable float[] meterMarks0Db =
            [0, -3, -6, -9, -12, -15, -18, -20, -25, -30, -35, -40, -50, -60];

        /// Decibel marks to draw when +6 dB is the maximum level
        static immutable float[] meterMarks6Db =
            [6, 3, 0, -3, -6, -9, -12, -15, -18, -20, -25, -30, -35, -40, -50, -60];

        /// Color stops for drawing a gradient background for a meter
        static immutable Color[] colorMap = [
            Color(1.0, 0.0, 0.0),
            Color(1.0, 0.5, 0.0),
            Color(1.0, 0.95, 0.0),
            Color(0.0, 1.0, 0.0),
            Color(0.0, 0.75, 0.0),
            Color(0.0, 0.4, 0.25),
            Color(0.0, 0.1, 0.5)
        ];

        /// Decibel marks corresponding to each element in `colorMap`
        static immutable float[] colorMapDb = [0, -2, -6, -12, -25, -float.infinity];

        /// Class to render a small text box containing a decibel reading
        abstract class DbReadout {
        public:
            enum dbReadoutWidth = 30; /// Text box width, in pixels
            enum dbReadoutHeight = 20; /// Text box height, in pixels
            enum dbReadoutFont = "Arial 8";

            /// Draw the readout to a cairo context
            void draw(ref Scoped!Context cr, pixels_t readoutXOffset, pixels_t readoutYOffset) {
                // compute the bounding box for the readout
                _boundingBox.x0 = readoutXOffset;
                _boundingBox.y0 = readoutYOffset;
                _boundingBox.x1 = readoutXOffset + dbReadoutWidth;
                _boundingBox.y1 = readoutYOffset + dbReadoutHeight;

                // draw the readout background
                cr.save();
                scope(exit) cr.restore();

                cr.setAntialias(cairo_antialias_t.GRAY);
                cr.rectangle(readoutXOffset, readoutYOffset, dbReadoutWidth, dbReadoutHeight);
                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.stroke();

                cr.rectangle(readoutXOffset + 1, readoutYOffset + 1, dbReadoutWidth - 2, dbReadoutHeight - 2);
                cr.setSourceRgb(0.5, 0.5, 0.5);
                cr.strokePreserve();

                Pattern readoutGradient = Pattern.createLinear(0, readoutYOffset,
                                                               0, readoutYOffset + dbReadoutHeight);
                scope(exit) readoutGradient.destroy();
                readoutGradient.addColorStopRgb(0, 0.15, 0.15, 0.15);
                readoutGradient.addColorStopRgb(1, 0.05, 0.05, 0.05);
                cr.setSource(readoutGradient);
                cr.fill();

                // draw the readout text
                if(!_dbReadoutLayout) {
                    PgFontDescription desc;
                    _dbReadoutLayout = PgCairo.createLayout(cr);
                    desc = PgFontDescription.fromString(dbReadoutFont);
                    _dbReadoutLayout.setFontDescription(desc);
                    desc.free();
                }

                if(abs(db) >= 10) {
                    _dbReadoutLayout.setText(db > 0 ? '+' ~ to!string(round(db)) : to!string(round(db)));
                }
                else if(abs(db) < 0.1) {
                    _dbReadoutLayout.setText("0.0");
                }
                else {
                    auto dbString = appender!string();
                    auto spec = singleSpec("%+1.1f");
                    formatValue(dbString, db, spec);
                    _dbReadoutLayout.setText(dbString.data);
                }

                int widthPixels, heightPixels;
                _dbReadoutLayout.getPixelSize(widthPixels, heightPixels);
                cr.moveTo(readoutXOffset + dbReadoutWidth / 2 - widthPixels / 2,
                          readoutYOffset + dbReadoutHeight / 2 - heightPixels / 2);
                Color color = textColor;
                cr.setSourceRgb(color.r, color.g, color.b);
                PgCairo.updateLayout(cr, _dbReadoutLayout);
                PgCairo.showLayout(cr, _dbReadoutLayout);
            }

            /// Returns: A bounding box for the decibel readout
            @property ref const(BoundingBox) boundingBox() const { return _boundingBox; }

            /// The current decibel value to be displayed by the readout
            float db;

        protected:
            /// Returns: The color to render the text in the readout
            @property Color textColor();

        private:
            BoundingBox _boundingBox;
            PgLayout _dbReadoutLayout;
        }

        /// A decibel readout for the track fader
        final class FaderReadout : DbReadout {
        public:
            this() {
                db = 0;
            }

        protected:
            @property override Color textColor() {
                return Color(1.0, 1.0, 1.0);
            }
        }

        /// A decibel readout for the track meter
        final class MeterReadout : DbReadout {
        public:
            this() {
                db = -float.infinity;
            }

        protected:
            @property override Color textColor() {
                // Color the text to match the current meter levels
                if(_meterGradient !is null && db > -float.infinity) {
                    size_t markIndex;
                    foreach(index, mark; colorMapDb) {
                        if(min(db, 0) >= mark) {
                            markIndex = index;
                            break;
                        }
                    }

                    if(markIndex < colorMapDb.length) {
                        return colorMap[markIndex];
                    }
                }

                return Color(0.4, 0.4, 0.4);
            }
        }

        /// Params:
        /// channelView = The channel view to associate with this channel strip
        this(ChannelView channelView) {
            _channelView = channelView;

            _faderReadout = new FaderReadout();
            _meterReadout = new MeterReadout();
            updateFaderFromChannel();
        }

        /// Draw the entire channel strip to a cairo context
        void draw(ref Scoped!Context cr, pixels_t channelStripXOffset) {
            immutable pixels_t windowWidth = cast(pixels_t)(getWindow().getWidth());
            immutable pixels_t windowHeight = cast(pixels_t)(getWindow().getHeight());

            _faderYOffset = windowHeight - (meterHeightPixels + faderHeightPixels / 2 + 25);

            immutable pixels_t faderXOffset = channelStripXOffset + 20;
            immutable pixels_t meterXOffset = faderXOffset + faderBackgroundWidthPixels + 35;
            immutable pixels_t labelXOffset = channelStripXOffset + channelStripWidth / 2;

            drawFader(cr, faderXOffset, _faderYOffset);
            drawMeter(cr, meterXOffset, _faderYOffset);
            drawLabel(cr, labelXOffset, _faderYOffset - 75);
        }

        /// Subroutine to draw the track fader
        void drawFader(ref Scoped!Context cr, pixels_t faderXOffset, pixels_t faderYOffset) {
            if(_channelView !is null) {
                enum degrees = PI / 180.0;

                cr.save();
                scope(exit) cr.restore();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.GRAY);
                cr.setLineWidth(1.0);

                // draw the background
                cr.rectangle(faderXOffset - faderBackgroundWidthPixels / 2, faderYOffset,
                             faderBackgroundWidthPixels, meterHeightPixels);
                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.fill();

                // compute pixel offsets for the top left corner of the fader
                immutable pixels_t xOffset = faderXOffset - faderWidthPixels / 2;
                immutable pixels_t yOffset = faderYOffset - faderHeightPixels / 2 + _faderAdjustmentPixels;

                // compute a bounding box for the fader
                _faderBox.x0 = xOffset;
                _faderBox.y0 = yOffset;
                _faderBox.x1 = xOffset + faderWidthPixels;
                _faderBox.y1 = yOffset + faderHeightPixels;

                // draw the fader
                Pattern faderGradient = Pattern.createLinear(0, yOffset, 0, yOffset + faderHeightPixels);
                scope(exit) faderGradient.destroy();
                faderGradient.addColorStopRgb(0, 0.25, 0.25, 0.25);
                faderGradient.addColorStopRgb(0.5, 0.6, 0.6, 0.6);
                faderGradient.addColorStopRgb(1, 0.25, 0.25, 0.25);

                cr.newSubPath();
                cr.arc(xOffset + faderCornerRadiusPixels, yOffset + faderCornerRadiusPixels,
                       faderCornerRadiusPixels, 180 * degrees, 270 * degrees);
                cr.arc(xOffset + faderWidthPixels - faderCornerRadiusPixels, yOffset + faderCornerRadiusPixels,
                       faderCornerRadiusPixels, -90 * degrees, 0 * degrees);
                cr.arc(xOffset + faderWidthPixels - faderCornerRadiusPixels,
                       yOffset + faderHeightPixels - faderCornerRadiusPixels,
                       faderCornerRadiusPixels, 0 * degrees, 90 * degrees);
                cr.arc(xOffset + faderCornerRadiusPixels, yOffset + faderHeightPixels - faderCornerRadiusPixels,
                       faderCornerRadiusPixels, 90 * degrees, 180 * degrees);
                cr.closePath();

                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.strokePreserve();
                cr.setSource(faderGradient);
                cr.fill();

                cr.setAntialias(cairo_antialias_t.NONE);
                cr.moveTo(faderXOffset - (faderWidthPixels / 2) + 2, faderYOffset + _faderAdjustmentPixels);
                cr.lineTo(faderXOffset + (faderWidthPixels / 2) - 2, faderYOffset + _faderAdjustmentPixels);
                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.stroke();

                // draw the dB readout
                immutable pixels_t readoutXOffset =
                    faderXOffset - DbReadout.dbReadoutWidth / 2;
                immutable pixels_t readoutYOffset =
                    faderYOffset - (faderHeightPixels / 2 + DbReadout.dbReadoutHeight + 5);
                _faderReadout.draw(cr, readoutXOffset, readoutYOffset);
            }
        }

        /// Subroutine to draw the track meter
        void drawMeter(ref Scoped!Context cr, pixels_t meterXOffset, pixels_t meterYOffset) {
            if(_channelView !is null) {
                cr.save();
                scope(exit) cr.restore();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.GRAY);
                cr.setLineWidth(1.0);

                if(_meterGradient is null || _backgroundGradient is null) {
                    static void addMeterColorStops(T)(Pattern pattern, T colorMap) {
                        // clip
                        pattern.addColorStopRgb(1.0, colorMap[0].r, colorMap[0].g, colorMap[0].b);

                        // 0 dB
                        pattern.addColorStopRgb(_deflect0Db(colorMapDb[1]),
                                                colorMap[1].r, colorMap[1].g, colorMap[1].b);

                        // -3 dB
                        pattern.addColorStopRgb(_deflect0Db(colorMapDb[2]),
                                                colorMap[2].r, colorMap[2].g, colorMap[2].b);

                        // -9 dB
                        pattern.addColorStopRgb(_deflect0Db(colorMapDb[3]),
                                                colorMap[3].r, colorMap[3].g, colorMap[3].b);

                        // -18 dB
                        pattern.addColorStopRgb(_deflect0Db(colorMapDb[4]),
                                                colorMap[4].r, colorMap[4].g, colorMap[4].b);

                        // -40 dB
                        pattern.addColorStopRgb(_deflect0Db(colorMapDb[5]),
                                                colorMap[5].r, colorMap[5].g, colorMap[5].b);

                        // -inf
                        pattern.addColorStopRgb(0.0, colorMap[6].r, colorMap[6].g, colorMap[6].b);
                    }

                    _meterGradient =
                        Pattern.createLinear(0, meterYOffset + meterHeightPixels, 0, meterYOffset);
                    addMeterColorStops(_meterGradient, colorMap);

                    _backgroundGradient =
                        Pattern.createLinear(0, meterYOffset + meterHeightPixels, 0, meterYOffset);
                    addMeterColorStops(_backgroundGradient,
                                       std.algorithm.map!((Color color) => color / 10)(colorMap));
                }

                immutable pixels_t meterXOffset1 = meterXOffset + 1;
                immutable pixels_t meterXOffset2 = meterXOffset1 + 2 + meterChannelWidthPixels;

                // draw the meter marks
                if(!_meterMarkLayout) {
                    PgFontDescription desc;
                    _meterMarkLayout = PgCairo.createLayout(cr);
                    desc = PgFontDescription.fromString(meterMarkFont);
                    _meterMarkLayout.setFontDescription(desc);
                    desc.free();
                }

                void drawMark(float db) {
                    _meterMarkLayout.setText(db > 0 ? ('+' ~ to!string(cast(int)(db))) :
                                             to!string(cast(int)(db)));
                    int widthPixels, heightPixels;
                    _meterMarkLayout.getPixelSize(widthPixels, heightPixels);
                    cr.moveTo(meterXOffset - (widthPixels + 4),
                              meterYOffset + meterHeightPixels -
                              (meterHeightPixels * _deflect0Db(db) + heightPixels / 2));
                    PgCairo.updateLayout(cr, _meterMarkLayout);
                    PgCairo.showLayout(cr, _meterMarkLayout);
                }
                cr.setSourceRgb(1.0, 1.0, 1.0);
                foreach(meterMark; meterMarks0Db) {
                    drawMark(meterMark);
                }

                // compute the bounding box for the meter
                _meterBox.x0 = meterXOffset;
                _meterBox.y0 = meterYOffset;
                _meterBox.x1 = meterXOffset + meterWidthPixels;
                _meterBox.y1 = meterYOffset + meterHeightPixels;

                // draw the meter background
                cr.rectangle(meterXOffset, meterYOffset, meterWidthPixels, meterHeightPixels);
                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.strokePreserve();
                cr.setSource(_backgroundGradient);
                cr.fill();

                // draw the meter levels
                immutable sample_t levelDb1 = 20 * log10(_channelView.level[0]);
                immutable sample_t levelDb2 = 20 * log10(_channelView.level[1]);

                immutable pixels_t levelHeight1 = min(cast(pixels_t)(_deflect0Db(levelDb1) * meterHeightPixels),
                                                      meterHeightPixels);
                immutable pixels_t levelHeight2 = min(cast(pixels_t)(_deflect0Db(levelDb2) * meterHeightPixels),
                                                      meterHeightPixels);

                cr.rectangle(meterXOffset1, meterYOffset + (meterHeightPixels - levelHeight1),
                             meterChannelWidthPixels, levelHeight1);
                cr.setSource(_meterGradient);
                cr.fill();

                cr.rectangle(meterXOffset2, meterYOffset + (meterHeightPixels - levelHeight2),
                             meterChannelWidthPixels, levelHeight2);
                cr.setSource(_meterGradient);
                cr.fill();

                // draw the peak levels
                updatePeaks();

                immutable sample_t peakDb1 = 20 * log10(_peak1);
                immutable sample_t peakDb2 = 20 * log10(_peak2);

                immutable pixels_t peakHeight1 = min(cast(pixels_t)(_deflect0Db(peakDb1) * meterHeightPixels),
                                                     meterHeightPixels);
                immutable pixels_t peakHeight2 = min(cast(pixels_t)(_deflect0Db(peakDb2) * meterHeightPixels),
                                                     meterHeightPixels);
                if(peakHeight1 > 0 || peakHeight2 > 0) {
                    cr.moveTo(meterXOffset1, meterYOffset + (meterHeightPixels - peakHeight1));
                    cr.lineTo(meterXOffset1 + meterChannelWidthPixels,
                              meterYOffset + (meterHeightPixels - peakHeight1));

                    cr.moveTo(meterXOffset2, meterYOffset + (meterHeightPixels - peakHeight2));
                    cr.lineTo(meterXOffset2 + meterChannelWidthPixels,
                              meterYOffset + (meterHeightPixels - peakHeight2));

                    cr.setSource(_meterGradient);
                    cr.stroke();
                }

                //draw the dB readout
                immutable pixels_t readoutXOffset =
                    meterXOffset + meterWidthPixels / 2 - DbReadout.dbReadoutWidth / 2;
                immutable pixels_t readoutYOffset =
                    meterYOffset - (faderHeightPixels / 2 + DbReadout.dbReadoutHeight + 5);
                _meterReadout.db = 20 * log10(max(_readoutPeak1, _readoutPeak2));
                _meterReadout.draw(cr, readoutXOffset, readoutYOffset);
            }
        }

        /// Subroutine to draw the track label
        void drawLabel(ref Scoped!Context cr, pixels_t labelXOffset, pixels_t labelYOffset) {
            cr.save();
            scope(exit) cr.restore();

            if(!_channelStripLabelLayout) {
                PgFontDescription desc;
                _channelStripLabelLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(channelStripLabelFont);
                _channelStripLabelLayout.setFontDescription(desc);
                desc.free();
            }

            _channelStripLabelLayout.setText(_channelView.name);
            int labelWidth, labelHeight;
            _channelStripLabelLayout.getPixelSize(labelWidth, labelHeight);
            cr.moveTo(labelXOffset - labelWidth / 2, labelYOffset);
            cr.setSourceRgb(1.0, 1.0, 1.0);
            PgCairo.updateLayout(cr, _channelStripLabelLayout);
            PgCairo.showLayout(cr, _channelStripLabelLayout);
        }

        /// Call this function when the size of the widget containing this channel strip has been changed
        void sizeChanged() {
            if(_meterGradient !is null) {
                _meterGradient.destroy();
            }
            _meterGradient = null;

            if(_backgroundGradient !is null) {
                _backgroundGradient.destroy();
            }
            _backgroundGradient = null;
        }

        /// This function will hold the current peak levels according to the peak hold time constant.
        /// Once the maximum peak hold time has been reached, the peaks will begin falling, until a new
        /// peak is detected and held. This gives the user a reasonable idea of the relative peaks
        /// present in recently played audio.
        void updatePeaks() {
            // update peak hold times
            _peak1 = _channelView.peakMax[0];
            _peak2 = _channelView.peakMax[1];

            if(_readoutPeak1 < _peak1) {
                _readoutPeak1 = _peak1;
            }
            if(_readoutPeak2 < _peak2) {
                _readoutPeak2 = _peak2;
            }

            if(!_peak1Falling.isNull()) {
                auto elapsed = MonoTime.currTime - _lastPeakTime;
                _peak1Falling = max(_peak1Falling - sample_t(1) / elapsed.split!("msecs").msecs, 0);
                _peak1 = _peak1Falling;
                if(_peak1Falling < _peak1 || _peak1Falling == 0) {
                    _peak1Falling.nullify();
                    _peakHold1 = _peak1;
                    _totalPeakTime1 = 0.msecs;
                }
                else {
                    _channelView.resetMeterLeft();
                }
            }
            else {
                if(_peakHold1 > 0 && _peak1 == _peakHold1) {
                    auto elapsed = MonoTime.currTime - _lastPeakTime;
                    _totalPeakTime1 += elapsed;
                    if(_totalPeakTime1 >= peakHoldTime) {
                        _peak1Falling = _peak1;
                        _channelView.resetMeterLeft();
                    }
                }
                else {
                    _peakHold1 = _peak1;
                    _totalPeakTime1 = 0.msecs;
                }
            }

            if(!_peak2Falling.isNull()) {
                auto elapsed = MonoTime.currTime - _lastPeakTime;
                _peak2Falling = max(_peak2Falling - sample_t(1) / elapsed.split!("msecs").msecs, 0);
                _peak2 = _peak2Falling;
                if(_peak2Falling < _peak2 || _peak2 <= 0) {
                    _peak2Falling.nullify();
                    _peakHold2 = _peak2;
                    _totalPeakTime2 = 0.msecs;
                }
                else {
                    _channelView.resetMeterRight();
                }
            }
            else {
                if(_peakHold2 > 0 && _peak2 == _peakHold2) {
                    auto elapsed = MonoTime.currTime - _lastPeakTime;
                    _totalPeakTime2 += elapsed;
                    if(_totalPeakTime2 >= peakHoldTime) {
                        _peak2Falling = _peak2;
                        _channelView.resetMeterRight();
                    }
                }
                else {
                    _peakHold2 = _peak2;
                    _totalPeakTime2 = 0.msecs;
                }
            }

            _lastPeakTime = MonoTime.currTime;
        }

        /// Continues to update the meter when the mixer stops playing.
        /// This allows the meters to smoothly return to -infinity.
        /// Returns: `true` if and only if the meter should be redrawn
        bool refresh() {
            if(_mixer.playing) {
                _mixerPlaying = true;
                _processSilence = false;
                return true;
            }
            else if(_mixerPlaying) {
                _mixerPlaying = false;
                _processSilence = true;
                _lastRefresh = MonoTime.currTime;
            }

            if(_processSilence && _channelView !is null) {
                auto elapsed = (MonoTime.currTime - _lastRefresh).split!("msecs").msecs;
                _lastRefresh = MonoTime.currTime;

                // this check is required for the meter implementation
                if(elapsed > 0) {
                    _channelView.processSilence(cast(nframes_t)(_mixer.sampleRate / 1000 * elapsed));
                }

                immutable sample_t levelDb1 = 20 * log10(_channelView.level[0]);
                immutable sample_t levelDb2 = 20 * log10(_channelView.level[1]);
                if(levelDb1 <= -70 && levelDb2 <= -70 &&
                   _peak1Falling.isNull && _peak2Falling.isNull) {
                    _processSilence = false;
                    return true;
                }
            }

            return _processSilence;
        }

        /// Reset the meters for both the left and right channels to their initial states
        void resetMeters() {
            if(_channelView !is null) {
                _channelView.resetMeters();
                _peak1 = _peak2 = _readoutPeak1 = _readoutPeak2 = -float.infinity;
                _peak1Falling.nullify();
                _peak2Falling.nullify();
                _processSilence = false;
            }
        }

        /// Reset the fader to 0 dB, and reset the meters
        void zeroFader() {
            if(_channelView !is null) {
                _channelView.faderGainDB = 0;
                _channelView.resetMeters();
                updateFaderFromChannel();
            }
        }

        /// Modify the fader gain when the user moves the fader via the mouse
        void updateFaderFromMouse(pixels_t mouseY) {
            _faderAdjustmentPixels = clamp(mouseY - _faderYOffset, 0, meterHeightPixels);
            if(_channelView !is null) {
                _channelView.faderGainDB =
                    _deflectInverse6Db(1 - cast(float)(_faderAdjustmentPixels) / cast(float)(meterHeightPixels));
                _faderReadout.db = _channelView.faderGainDB;
            }
        }

        /// Modify the fader gain from the associated channel object.
        /// This is useful when updating the channel strip state from the undo/redo history.
        void updateFaderFromChannel() {
            if(_channelView !is null) {
                _faderAdjustmentPixels =
                    cast(pixels_t)((1 - _deflect6Db(_channelView.faderGainDB)) * meterHeightPixels);
                _faderReadout.db = _channelView.faderGainDB;
            }
            else {
                _faderAdjustmentPixels = cast(pixels_t)((1 - _deflect6Db(0)) * meterHeightPixels);
                _faderReadout.db = 0;
            }
        }

        /// Returns: The channel view object associated with this channel strip
        @property ChannelView channelView() { return _channelView; }

        /// Returns: `true` if and only if the channel strip should be redrawn.
        ///          This occurs if the mixer is currently playing, or if the meter has not yet
        ///          fallen to -infinity.
        @property bool redrawRequested() {
            return _mixerPlaying || _processSilence;
        }

        /// Returns: A bounding box containing the user-adjustable fader.
        ///          This is the area that the user can click to adjust the fader.
        @property ref const(BoundingBox) faderBox() const { return _faderBox; }

        /// Returns: A bounding box containing the decibel readout corresponding to the fader
        @property ref const(BoundingBox) faderReadoutBox() const { return _faderReadout.boundingBox; }

        /// Returns: A bounding box containing the meter
        @property ref const(BoundingBox) meterBox() const { return _meterBox; }

        /// Returns: A bounding box for containing the decibel readout corresponding to the meter
        @property ref const(BoundingBox) meterReadoutBox() const { return _meterReadout.boundingBox; }

    private:
        /// Calculate a deflection between (-inf, 0] dB.
        /// This is used to convert decibel values to pixel coordinates.
        static float _deflect0Db(float db) {
            float def = 0.0f;

            if(db < -70.0f) {
                def = 0.0f;
            }
            else if(db < -60.0f) {
                def = (db + 70.0f) * 0.25f;
            }
            else if(db < -50.0f) {
                def = (db + 60.0f) * 0.5f + 2.5f;
            }
            else if(db < -40.0f) {
                def = (db + 50.0f) * 0.75f + 7.5f;
            }
            else if(db < -30.0f) {
                def = (db + 40.0f) * 1.5f + 15.0f;
            }
            else if(db < -20.0f) {
                def = (db + 30.0f) * 2.0f + 30.0f;
            }
            else if(db < 0.0f) {
                def = (db + 20.0f) * 2.5f + 50.0f;
            }
            else {
                def = 100.0f;
            }

            return def / 100.0f;
        }

        /// Calculate a deflection between (-inf, 6] dB.
        /// This is used to convert decibel values to pixel coordinates.
        static float _deflect6Db(float db) {
            float def = 0.0f;

            if(db < -70.0f) {
                def = 0.0f;
            }
            else if(db < -60.0f) {
                def = (db + 70.0f) * 0.25f;
            }
            else if(db < -50.0f) {
                def = (db + 60.0f) * 0.5f + 2.5f;
            }
            else if(db < -40.0f) {
                def = (db + 50.0f) * 0.75f + 7.5f;
            }
            else if(db < -30.0f) {
                def = (db + 40.0f) * 1.5f + 15.0f;
            }
            else if(db < -20.0f) {
                def = (db + 30.0f) * 2.0f + 30.0f;
            }
            else if(db < 6.0f) {
                def = (db + 20.0f) * 2.5f + 50.0f;
            }
            else {
                def = 115.0f;
            }

            return def / 115.0f;
        }

        /// Linearly scale between logarithmically spaced meter marks.
        /// This algorithm seems to yield pleasant behavior when adjusting faders via the mouse.
        /// Params:
        /// faderPosition = A fractional value between 0 and 1 representing the fader position
        /// Returns: A value, in dBFS, corresponding to the fader position
        static float _deflectInverse6Db(float faderPosition) {
            static auto deflectionPoints = std.algorithm.map!(db => _deflect6Db(db))(meterMarks6Db);

            size_t index;
            float db;

            if(faderPosition >= deflectionPoints[0]) {
                db = meterMarks6Db[0];
            }
            else {
                foreach(point; deflectionPoints) {
                    if(faderPosition >= point && index < meterMarks6Db.length) {
                        db = ((faderPosition - point) / ((index > 0 ? deflectionPoints[index - 1] : 1) - point)) *
                            ((index > 0 ? meterMarks6Db[index - 1] : meterMarks6Db[0]) - meterMarks6Db[index]) +
                            meterMarks6Db[index];
                        break;
                    }
                    ++index;
                }
                if(index >= meterMarks6Db.length) {
                    db = -float.infinity;
                }
            }

            return db;
        }

        ChannelView _channelView;

        PgLayout _channelStripLabelLayout;

        FaderReadout _faderReadout;
        MeterReadout _meterReadout;

        pixels_t _faderYOffset;
        pixels_t _faderAdjustmentPixels;
        BoundingBox _faderBox;
        BoundingBox _meterBox;

        Pattern _meterGradient;
        Pattern _backgroundGradient;
        PgLayout _meterMarkLayout;

        bool _mixerPlaying;
        bool _processSilence;
        MonoTime _lastRefresh;

        sample_t _peak1 = -float.infinity;
        sample_t _peak2 = -float.infinity;
        sample_t _readoutPeak1 = -float.infinity;
        sample_t _readoutPeak2 = -float.infinity;
        sample_t _peakHold1 = 0;
        sample_t _peakHold2 = 0;
        Nullable!sample_t _peak1Falling;
        Nullable!sample_t _peak2Falling;
        MonoTime _lastPeakTime;
        Duration _totalPeakTime1;
        Duration _totalPeakTime2;
    }

    /// Renders two channel strips in the arrange view.
    /// The first corresponds to the currently selected track.
    /// The second corresponds to the master bus.
    final class ArrangeChannelStrip : DrawingArea {
    public:
        this() {
            _arrangeChannelStripWidth = defaultChannelStripWidth * 2;
            setSizeRequest(_arrangeChannelStripWidth, 0);

            addOnDraw(&drawCallback);
            addOnSizeAllocate(&onSizeAllocate);
            addOnMotionNotify(&onMotionNotify);
            addOnButtonPress(&onButtonPress);
            addOnButtonRelease(&onButtonRelease);

            update();
        }

        /// Updates the state of the selected track and master bus channel strips from their respective tracks.
        /// This is useful when updating the current state after an undo/redo operation.
        void update() {
            if(_selectedTrack !is null) {
                _selectedTrackChannelStrip = _selectedTrack.channelStrip;
                _selectedTrackChannelStrip.updateFaderFromChannel();

                _masterBusView.channelStrip.updateFaderFromChannel();
            }
            else {
                _selectedTrackChannelStrip = null;
            }
        }

        /// Redraw this widget
        void redraw() {
            queueDrawArea(0, 0, getWindow().getWidth(), getWindow().getHeight());
        }

        /// Draw the selected track and master bus channel strips to a cairo context
        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(_arrangeChannelStripRefresh is null) {
                _arrangeChannelStripRefresh = new Timeout(cast(uint)(1.0 / refreshRate * 1000), &onRefresh, false);
            }

            cr.save();
            scope(exit) cr.restore();

            // draw the background
            cr.setSourceRgb(0.1, 0.1, 0.1);
            cr.paint();

            // draw the channel strip for the currently selected track
            if(_selectedTrackChannelStrip !is null) {
                _selectedTrackChannelStrip.draw(cr, 0);
            }

            // draw the channel strip for the master bus
            {
                cr.save();
                scope(exit) cr.restore();

                _masterBusView.channelStrip.draw(cr, ChannelStrip.channelStripWidth);
            }

            // draw right borders
            {
                cr.save();
                scope(exit) cr.restore();

                cr.setAntialias(cairo_antialias_t.NONE);
                cr.setLineWidth(1.0);

                cr.moveTo(_arrangeChannelStripWidth / 2, 0);
                cr.lineTo(_arrangeChannelStripWidth / 2, getWindow.getHeight());
                cr.moveTo(_arrangeChannelStripWidth - 1, 0);
                cr.lineTo(_arrangeChannelStripWidth - 1, getWindow.getHeight());
                cr.setSourceRgb(0.0, 0.0, 0.0);
                cr.stroke();
            }

            return true;
        }

        /// Callback to refresh the level and peak values for the selected track and master bus channel strips
        bool onRefresh() {
            foreach(trackView; _trackViews) {
                if(trackView != _selectedTrack) {
                    trackView.channelStrip.updatePeaks();
                }
                trackView.channelStrip.refresh();
            }

            _masterBusView.channelStrip.refresh();

            if((_selectedTrackChannelStrip !is null && _selectedTrackChannelStrip.redrawRequested) ||
               _masterBusView.channelStrip.redrawRequested) {
                redraw();
            }

            return true;
        }

        /// This function is called when Gtk issues a size allocation request for this widget
        void onSizeAllocate(GtkAllocation* allocation, Widget widget) {
            if(_selectedTrackChannelStrip !is null) {
                _selectedTrackChannelStrip.sizeChanged();
            }

            _masterBusView.channelStrip.sizeChanged();
        }

        /// Called when the user moves the mouse within this widget
        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                _mouseY = cast(typeof(_mouseX))(event.motion.y);

                if(_selectedTrackChannelStrip !is null && _selectedTrackFaderMoving) {
                    _selectedTrackChannelStrip.updateFaderFromMouse(_mouseY);
                    redraw();
                }
                else if(_masterBusFaderMoving) {
                    _masterBusView.channelStrip.updateFaderFromMouse(_mouseY);
                    redraw();
                }
            }
            return true;
        }

        /// Called when the user presses a mouse button within this widget
        bool onButtonPress(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_PRESS) {
                bool doubleClick;
                auto doubleClickElapsed = (MonoTime.currTime - _doubleClickTime).split!("msecs").msecs;
                if(doubleClickElapsed <= doubleClickMsecs) {
                    doubleClick = true;
                }
                _doubleClickTime = MonoTime.currTime;

                bool caughtMouseEvent;
                if(event.button.button == leftButton) {
                    if(_selectedTrackChannelStrip !is null) {
                        if(_selectedTrackChannelStrip.faderBox.containsPoint(_mouseX, _mouseY) ||
                           _selectedTrackChannelStrip.faderReadoutBox.containsPoint(_mouseX, _mouseY)) {
                            if(doubleClick) {
                                _selectedTrackChannelStrip.zeroFader();
                                redraw();
                                caughtMouseEvent = true;
                            }
                            else {
                                _selectedTrackFaderMoving = true;
                                _selectedTrackFaderStartGainDB = _selectedTrack.faderGainDB;
                                caughtMouseEvent = true;
                            }
                        }
                        else if(_selectedTrackChannelStrip.meterBox.containsPoint(_mouseX, _mouseY) ||
                                _selectedTrackChannelStrip.meterReadoutBox.containsPoint(_mouseX, _mouseY)) {
                            _selectedTrackChannelStrip.resetMeters();
                            redraw();
                            caughtMouseEvent = true;
                        }
                    }

                    if(!caughtMouseEvent) {
                        if(_masterBusView.channelStrip.faderBox.containsPoint(_mouseX, _mouseY) ||
                           _masterBusView.channelStrip.faderReadoutBox.containsPoint(_mouseX, _mouseY)) {
                            if(doubleClick) {
                                _masterBusView.channelStrip.zeroFader();
                                redraw();
                            }
                            else {
                                _masterBusFaderMoving = true;
                                _masterBusFaderStartGainDB = _masterBusView.faderGainDB;
                            }
                        }
                        else if(_masterBusView.channelStrip.meterBox.containsPoint(_mouseX, _mouseY) ||
                                _masterBusView.channelStrip.meterReadoutBox.containsPoint(_mouseX, _mouseY)) {
                            _masterBusView.channelStrip.resetMeters();
                            redraw();
                        }
                    }
                }
            }
            return false;
        }

        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == leftButton) {
                if(_selectedTrackFaderMoving) {
                    _selectedTrackFaderMoving = false;
                    if(_selectedTrackFaderStartGainDB != _selectedTrack.faderGainDB) {
                        appendArrangeState(currentArrangeState!(ArrangeStateType.selectedTrackEdit));
                    }
                }

                if(_masterBusFaderMoving) {
                    _masterBusFaderMoving = false;
                    if(_masterBusFaderStartGainDB != _masterBusView.faderGainDB) {
                        appendArrangeState(currentArrangeState!(ArrangeStateType.masterBusEdit));
                    }
                }
            }
            return false;
        }

    private:
        pixels_t _arrangeChannelStripWidth;

        ChannelStrip _selectedTrackChannelStrip;
        bool _selectedTrackFaderMoving;
        sample_t _selectedTrackFaderStartGainDB;

        bool _masterBusFaderMoving;
        sample_t _masterBusFaderStartGainDB;

        pixels_t _mouseX;
        pixels_t _mouseY;
    }

    /// Renders track stubs for all track views currently registered in this session.
    final class TrackStubs : DrawingArea {
    public:
        enum labelPadding = 5; // general padding for track labels, in pixels
        enum labelFont = "Arial 12"; // font family and size to use for track labels
        enum buttonFont = "Arial 9"; // font family for track stub buttons; e.g., mute/solo

        this() {
            _trackStubWidth = defaultTrackStubWidth;
            setSizeRequest(_trackStubWidth, 0);

            addOnDraw(&drawCallback);
            addOnMotionNotify(&onMotionNotify);
            addOnButtonPress(&onButtonPress);
            addOnButtonRelease(&onButtonRelease);
        }

        /// Redraw this widget
        void redraw() {
            queueDrawArea(0, 0, getWindow().getWidth(), getWindow().getHeight());
        }

        /// Draw the track stubs
        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(!_trackLabelLayout) {
                PgFontDescription desc;
                _trackLabelLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(TrackStubs.labelFont);
                _trackLabelLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);

            cr.setSourceRgb(0.1, 0.1, 0.1);
            cr.paint();

            // compute the width, in pixels, of the maximum track number
            pixels_t trackNumberWidth;
            {
                _trackLabelLayout.setText(to!string(_trackViews.length));
                int labelWidth, labelHeight;
                _trackLabelLayout.getPixelSize(labelWidth, labelHeight);
                trackNumberWidth = cast(pixels_t)(labelWidth) + labelPadding * 2;
            }

            // draw track stubs
            pixels_t yOffset = _canvas.firstTrackYOffset - _verticalPixelsOffset;
            foreach(trackIndex, trackView; _trackViews) {
                trackView.drawStub(cr, yOffset, trackIndex, trackNumberWidth);

                // increment yOffset for the next track
                yOffset += trackView.heightPixels;
            }

            return true;
        }

        /// Called when the user moves the mouse within this widget
        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                _mouseY = cast(typeof(_mouseX))(event.motion.y);
            }
            return true;
        }

        /// Called when the user presses a mouse button within this widget
        bool onButtonPress(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_PRESS) {
                TrackView trackView = _mouseOverTrack(_mouseY);

                if(event.button.button == leftButton) {
                    if(trackView !is null) {
                        // detect if the mouse is over a track button
                        _trackButtonPressed = null;
                        foreach(trackButton; trackView.trackButtons) {
                            if(trackButton.boundingBox.containsPoint(_mouseX, _mouseY)) {
                                trackButton.pressed = true;
                                _trackButtonPressed = trackButton;
                                redraw();
                                break;
                            }
                        }

                        if(_trackButtonPressed is null && trackView !is _selectedTrack) {
                            // select the new track
                            if(trackView !is _selectedTrack) {
                                _selectTrack(trackView);
                                appendArrangeState(currentArrangeState!(ArrangeStateType.selectedTrackEdit));
                            }

                            redraw();
                        }
                    }
                }
                else if(event.button.button == rightButton && _selectedTrack !is null) {
                    // show a context menu on right-click
                    auto buttonEvent = event.button;

                    if(_trackMenu is null) {
                        _createTrackMenu();
                    }
                    _trackMenu.popup(buttonEvent.button, buttonEvent.time);
                    _trackMenu.showAll();
                }
            }
            return false;
        }

        /// Called when the user releases a mouse button within this widget
        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == leftButton) {
                if(_trackButtonPressed !is null) {
                    if(_trackButtonPressed.boundingBox.containsPoint(_mouseX, _mouseY)) {
                        // toggle the pressed track button
                        _trackButtonPressed.pressed = false;
                        _trackButtonPressed.enabled = !_trackButtonPressed.enabled;
                    }
                    else {
                        _trackButtonPressed.pressed = false;
                    }
                    _trackButtonPressed = null;
                    redraw();
                }
            }
            return false;
        }

    private:
        pixels_t _mouseX;
        pixels_t _mouseY;
    }

    /// Renders a canvas widget that allows the user to manipulate tracks/regions.
    final class Canvas : DrawingArea {
        enum timeStripHeightPixels = 40;

        enum markerHeightPixels = 20;
        enum markerHeadWidthPixels = 16;

        enum timeMarkerFont = "Arial 10";
        enum markerLabelFont = "Arial 10";

        this() {
            setCanFocus(true);

            addOnDraw(&drawCallback);
            addOnSizeAllocate(&onSizeAllocate);
            addOnMotionNotify(&onMotionNotify);
            addOnLeaveNotify(&onLeaveNotify);
            addOnButtonPress(&onButtonPress);
            addOnButtonRelease(&onButtonRelease);
            addOnScroll(&onScroll);
            addOnKeyPress(&onKeyPress);
        }

        /// The width of the currently visible section of canvas, in pixels
        @property pixels_t viewWidthPixels() const {
            return _viewWidthPixels;
        }

        /// The height of the currently visible section of canvas, in pixels
        @property pixels_t viewHeightPixels() const {
            return _viewHeightPixels;
        }

        /// The vertical offset, in pixels, at which to render markers
        @property pixels_t markerYOffset() {
            return timeStripHeightPixels;
        }

        /// The vertical offset, in pixels, at which to begin rendering the first track
        @property pixels_t firstTrackYOffset() {
            return markerYOffset + markerHeightPixels;
        }

        /// A reasonable number of frames for fine seek operations
        @property nframes_t smallSeekIncrement() {
            return viewWidthSamples / 10;
        }

        /// A reasonable number of frames for coarse seek operations
        @property nframes_t largeSeekIncrement() {
            return viewWidthSamples / 5;
        }

        /// Draw the canvas to a cairo context
        bool drawCallback(Scoped!Context cr, Widget widget) {
            if(_canvasRefresh is null) {
                _canvasRefresh = new Timeout(cast(uint)(1.0 / refreshRate * 1000), &onRefresh, false);
            }

            cr.setOperator(cairo_operator_t.SOURCE);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.paint();

            // draw the canvas; i.e., the visible area that contains the timeline and audio regions
            {
                drawBackground(cr);
                drawTracks(cr);
                drawMarkers(cr);
                drawTimeStrip(cr);
                drawTransport(cr);
                drawSelectBox(cr);
            }

            return true;
        }

        /// Subroutine to render the canvas background
        void drawBackground(ref Scoped!Context cr) {
            cr.save();
            scope(exit) cr.restore();

            nframes_t secondsDistanceSamples = _mixer.sampleRate;
            nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timeStripScaleFactor);
            pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;

            // draw all currently visible arrange ticks
            auto firstMarkerOffset = (viewOffset + tickDistanceSamples) % tickDistanceSamples;
            for(auto i = viewOffset - firstMarkerOffset;
                i < viewOffset + viewWidthSamples + tickDistanceSamples; i += tickDistanceSamples) {
                pixels_t xOffset =
                    cast(pixels_t)(((i >= viewOffset) ?
                                    cast(long)(i - viewOffset) : -cast(long)(viewOffset - i)) / samplesPerPixel);
                // draw primary arrange ticks
                cr.moveTo(xOffset, markerYOffset);
                cr.lineTo(xOffset, viewHeightPixels);
                cr.setSourceRgb(0.2, 0.2, 0.2);
                cr.stroke();

                // draw secondary arrange ticks
                cr.moveTo(xOffset + tickDistancePixels / 2, markerYOffset);
                cr.lineTo(xOffset + tickDistancePixels / 2, viewHeightPixels);
                cr.moveTo(xOffset + tickDistancePixels / 4, markerYOffset);
                cr.lineTo(xOffset + tickDistancePixels / 4, viewHeightPixels);
                cr.moveTo(xOffset + (tickDistancePixels / 4) * 3, markerYOffset);
                cr.lineTo(xOffset + (tickDistancePixels / 4) * 3, viewHeightPixels);
                cr.setSourceRgb(0.1, 0.1, 0.1);
                cr.stroke();
            }
        }

        /// Subroutine to render the timestrip
        void drawTimeStrip(ref Scoped!Context cr) {
            enum primaryTickHeightFactor = 0.5;
            enum secondaryTickHeightFactor = 0.35;
            enum tertiaryTickHeightFactor = 0.2;

            enum timeStripBackgroundPadding = 2;

            cr.save();
            scope(exit) cr.restore();

            // draw a black background for the timeStrip
            cr.rectangle(0, 0, viewWidthPixels, timeStripHeightPixels - timeStripBackgroundPadding);
            cr.setSourceRgb(0.0, 0.0, 0.0);
            cr.fill();

            if(!_timeStripMarkerLayout) {
                PgFontDescription desc;
                _timeStripMarkerLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(timeMarkerFont);
                _timeStripMarkerLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setSourceRgb(1.0, 1.0, 1.0);
            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);
            nframes_t secondsDistanceSamples = _mixer.sampleRate;
            pixels_t secondsDistancePixels = secondsDistanceSamples / samplesPerPixel;

            void autoScale() {
                nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timeStripScaleFactor);
                pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;
                if(tickDistancePixels > 200) {
                    _timeStripScaleFactor *= 0.5f;
                }
                else if(tickDistancePixels < 100) {
                    _timeStripScaleFactor *= 2.0f;
                }
            }

            if(secondsDistancePixels > 150) {
                autoScale();
            }
            else if(secondsDistancePixels > 60) {
                _timeStripScaleFactor = 1;
            }
            else if(secondsDistancePixels > 25) {
                _timeStripScaleFactor = 2;
            }
            else if(secondsDistancePixels > 15) {
                _timeStripScaleFactor = 5;
            }
            else if(secondsDistancePixels > 10) {
                _timeStripScaleFactor = 10;
            }
            else if(secondsDistancePixels > 3) {
                _timeStripScaleFactor = 15;
            }
            else {
                autoScale();
            }

            nframes_t tickDistanceSamples = cast(nframes_t)(secondsDistanceSamples * _timeStripScaleFactor);
            pixels_t tickDistancePixels = tickDistanceSamples / samplesPerPixel;

            auto decDigits = 1;
            if(secondsDistancePixels <= 15) {
                decDigits = 0;
            }
            else if(secondsDistancePixels >= 750) {
                decDigits = clamp(cast(typeof(decDigits))(10 - log(tickDistanceSamples)), 1, 5);
            }

            auto minuteSpec = singleSpec("%.0f");
            auto decDigitsFormat = to!string(decDigits) ~ 'f';
            auto secondsSpec = singleSpec("%." ~ decDigitsFormat);
            auto secondsSpecTwoDigitsString = appender!string();
            secondsSpecTwoDigitsString.put("%0");
            secondsSpecTwoDigitsString.put(to!string(decDigits > 0 ? decDigits + 3 : 2));
            secondsSpecTwoDigitsString.put('.');
            secondsSpecTwoDigitsString.put(decDigitsFormat);
            auto secondsSpecTwoDigits = singleSpec(secondsSpecTwoDigitsString.data);

            // draw all currently visible time ticks and their time labels
            auto firstMarkerOffset = (viewOffset + tickDistanceSamples) % tickDistanceSamples;
            for(auto i = viewOffset - firstMarkerOffset;
                i < viewOffset + viewWidthSamples + tickDistanceSamples; i += tickDistanceSamples) {
                pixels_t xOffset =
                    cast(pixels_t)(((i >= viewOffset) ?
                                    cast(long)(i - viewOffset) : -cast(long)(viewOffset - i)) / samplesPerPixel);

                // draw primary timeStrip tick
                cr.moveTo(xOffset, 0);
                cr.lineTo(xOffset, timeStripHeightPixels * primaryTickHeightFactor);

                // draw one secondary timeStrip tick
                cr.moveTo(xOffset + tickDistancePixels / 2, 0);
                cr.lineTo(xOffset + tickDistancePixels / 2, timeStripHeightPixels * secondaryTickHeightFactor);

                // draw two tertiary timeStrip ticks
                cr.moveTo(xOffset + tickDistancePixels / 4, 0);
                cr.lineTo(xOffset + tickDistancePixels / 4, timeStripHeightPixels * tertiaryTickHeightFactor);
                cr.moveTo(xOffset + (tickDistancePixels / 4) * 3, 0);
                cr.lineTo(xOffset + (tickDistancePixels / 4) * 3, timeStripHeightPixels * tertiaryTickHeightFactor);

                pixels_t timeMarkerXOffset;
                auto timeString = appender!string();
                auto minutes = (i / secondsDistanceSamples) / 60;
                if(i == 0) {
                    timeString.put('0');
                    timeMarkerXOffset = xOffset;
                }
                else {
                    if(minutes > 0) {
                        timeString.put(to!string(minutes));
                        timeString.put(':');
                        formatValue(timeString, float(i) / float(secondsDistanceSamples) - minutes * 60,
                                    secondsSpecTwoDigits);
                    }
                    else {
                        formatValue(timeString, float(i) / float(secondsDistanceSamples), secondsSpec);
                    }

                    int widthPixels, heightPixels;
                    _timeStripMarkerLayout.getPixelSize(widthPixels, heightPixels);
                    timeMarkerXOffset = xOffset - widthPixels / 2;
                }

                cr.setSourceRgb(1.0, 1.0, 1.0);
                cr.stroke();

                _timeStripMarkerLayout.setText(timeString.data);
                cr.moveTo(timeMarkerXOffset, timeStripHeightPixels * 0.5);
                PgCairo.updateLayout(cr, _timeStripMarkerLayout);
                PgCairo.showLayout(cr, _timeStripMarkerLayout);
            }
        }

        /// Subroutine to draw the regions registered to each visible track
        void drawTracks(ref Scoped!Context cr) {
            pixels_t yOffset = firstTrackYOffset - _verticalPixelsOffset;
            foreach(trackView; _trackViews) {
                trackView.drawRegions(cr, yOffset);
                yOffset += trackView.heightPixels;
            }
        }

        /// Subroutine to draw the mixer transport
        void drawTransport(ref Scoped!Context cr) {
            enum transportHeadWidth = 16;
            enum transportHeadHeight = 10;

            cr.save();
            scope(exit) cr.restore();

            if(_mode == Mode.editRegion && !_mixer.playing) {
                return;
            }
            else if(_action == Action.moveTransport) {
                _transportPixelsOffset = clamp(_mouseX,
                                               0,
                                               (viewOffset + viewWidthSamples > _mixer.timeline.lastFrame) ?
                                                   ((_mixer.timeline.lastFrame - viewOffset) / samplesPerPixel) :
                                                   viewWidthPixels);
            }
            else if(viewOffset <= _mixer.timeline.transportOffset + (transportHeadWidth / 2) &&
                    _mixer.timeline.transportOffset <= viewOffset + viewWidthSamples + (transportHeadWidth / 2)) {
                _transportPixelsOffset = (_mixer.timeline.transportOffset - viewOffset) / samplesPerPixel;
            }
            else {
                return;
            }

            cr.setSourceRgb(1.0, 0.0, 0.0);
            cr.setLineWidth(1.0);
            cr.moveTo(_transportPixelsOffset, 0);
            cr.lineTo(_transportPixelsOffset, _viewHeightPixels);
            cr.stroke();

            cr.moveTo(_transportPixelsOffset - transportHeadWidth / 2, 0);
            cr.lineTo(_transportPixelsOffset + transportHeadWidth / 2, 0);
            cr.lineTo(_transportPixelsOffset, transportHeadHeight);
            cr.closePath();
            cr.fill();
        }

        /// Subroutine to draw a selection box, for selecting multiple regions
        void drawSelectBox(ref Scoped!Context cr) {
            if(_action == Action.selectBox) {
                cr.save();
                scope(exit) cr.restore();

                cr.setOperator(cairo_operator_t.OVER);
                cr.setAntialias(cairo_antialias_t.NONE);

                cr.setLineWidth(1.0);
                cr.rectangle(_selectMouseX, _selectMouseY, _mouseX - _selectMouseX, _mouseY - _selectMouseY);
                cr.setSourceRgba(0.0, 1.0, 0.0, 0.5);
                cr.fillPreserve();
                cr.setSourceRgb(0.0, 1.0, 0.0);
                cr.stroke();
            }
        }

        /// Subroutine to draw markers
        void drawMarkers(ref Scoped!Context cr) {
            enum taperFactor = 0.75;

            cr.save();
            scope(exit) cr.restore();

            if(!_markerLabelLayout) {
                PgFontDescription desc;
                _markerLabelLayout = PgCairo.createLayout(cr);
                desc = PgFontDescription.fromString(markerLabelFont);
                _markerLabelLayout.setFontDescription(desc);
                desc.free();
            }

            cr.setAntialias(cairo_antialias_t.NONE);
            cr.setLineWidth(1.0);

            // draw the visible user-defined markers
            pixels_t yOffset = markerYOffset - _verticalPixelsOffset;
            foreach(ref marker; _markers) {
                if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples) {
                    pixels_t xOffset = (marker.offset - viewOffset) / samplesPerPixel;

                    cr.setAntialias(cairo_antialias_t.FAST);
                    cr.moveTo(xOffset, yOffset + markerHeightPixels);
                    cr.lineTo(xOffset - markerHeadWidthPixels / 2, yOffset + markerHeightPixels * taperFactor);
                    cr.lineTo(xOffset - markerHeadWidthPixels / 2, yOffset);
                    cr.lineTo(xOffset + markerHeadWidthPixels / 2, yOffset);
                    cr.lineTo(xOffset + markerHeadWidthPixels / 2, yOffset + markerHeightPixels * taperFactor);
                    cr.closePath();
                    cr.setSourceRgb(1.0, 0.90, 0.0);
                    cr.fillPreserve();
                    cr.setSourceRgb(1.0, 0.65, 0.0);
                    cr.stroke();

                    cr.setAntialias(cairo_antialias_t.NONE);
                    cr.moveTo(xOffset, yOffset + markerHeightPixels);
                    cr.lineTo(xOffset, viewHeightPixels);
                    cr.stroke();

                    cr.setSourceRgb(0.0, 0.0, 0.0);
                    _markerLabelLayout.setText(marker.name);
                    int widthPixels, heightPixels;
                    _markerLabelLayout.getPixelSize(widthPixels, heightPixels);
                    cr.moveTo(xOffset - widthPixels / 2, yOffset);
                    PgCairo.updateLayout(cr, _markerLabelLayout);
                    PgCairo.showLayout(cr, _markerLabelLayout);
                }
            }

            // draw a dotted line at the end of the project, if visible
            if(_mixer.timeline.lastFrame > viewOffset && _mixer.timeline.lastFrame <= viewOffset + viewWidthSamples) {
                enum dottedLinePixels = 15;
                pixels_t xOffset = (_mixer.timeline.lastFrame - viewOffset) / samplesPerPixel;

                for(auto y = markerYOffset; y < viewHeightPixels; y += dottedLinePixels * 2) {
                    cr.moveTo(xOffset, y);
                    cr.lineTo(xOffset, y + dottedLinePixels);
                }
                cr.setSourceRgb(1.0, 1.0, 1.0);
                cr.stroke();
            }
        }

        /// Redraw this widget
        void redraw() {
            queueDrawArea(0, 0, getWindow().getWidth(), getWindow().getHeight());
        }

        /// Callback to refresh the transport when the mixer is playing
        bool onRefresh() {
            if(_mixer.playing) {
                if(_viewFollowTransport && _mixer.timeline.transportOffset >= viewOffset + viewWidthSamples) {
                    _viewOffset = _mixer.timeline.transportOffset;
                }

                _mixerPlaying = true;
                redraw();
            }
            else if(_mixerPlaying) {
                _mixerPlaying = false;
                redraw();
            }
            _menuBar.updateMixerMenu();
            return true;
        }

        /// This function is called when Gtk issues a size allocation request for this widget
        void onSizeAllocate(GtkAllocation* allocation, Widget widget) {
            GtkAllocation size;
            getAllocation(size);
            _viewWidthPixels = cast(pixels_t)(size.width);
            _viewHeightPixels = cast(pixels_t)(size.height);

            _hScroll.reconfigure();
            _vScroll.reconfigure();
        }

        /// Called in edit mode, when the user selects a subregion by clicking and dragging the mouse
        void onSelectSubregion() {
            if(_editRegion !is null) {
                immutable nframes_t mouseFrame =
                    clamp(max(0, _mouseX) * samplesPerPixel + viewOffset,
                          _editRegion.offset,
                          _editRegion.offset + _editRegion.nframes);
                if(mouseFrame < _editRegion.subregionStartFrame + _editRegion.offset) {
                    _editRegion.subregionStartFrame = mouseFrame - _editRegion.offset;
                    _editRegion.subregionEndFrame = _editRegion.editPointOffset;
                }
                else if(mouseFrame > _editRegion.subregionEndFrame + _editRegion.offset) {
                    _editRegion.subregionEndFrame = mouseFrame - _editRegion.offset;
                    _editRegion.subregionStartFrame = _editRegion.editPointOffset;
                }
                else {
                    if(mouseFrame > _editRegion.subregionStartFrame + _editRegion.offset &&
                       mouseFrame < _editRegion.editPointOffset + _editRegion.offset) {
                        _editRegion.subregionStartFrame = mouseFrame - _editRegion.offset;
                        _editRegion.subregionEndFrame = _editRegion.editPointOffset;
                    }
                    else if(mouseFrame > _editRegion.editPointOffset + _editRegion.offset &&
                            mouseFrame < _editRegion.subregionEndFrame + _editRegion.offset) {
                        _editRegion.subregionEndFrame = mouseFrame - _editRegion.offset;
                        _editRegion.subregionStartFrame = _editRegion.editPointOffset;
                    }
                }

                if(_mixer.looping) {
                    _mixer.enableLoop(_editRegion.subregionStartFrame + _editRegion.offset,
                                      _editRegion.subregionEndFrame + _editRegion.offset);
                }

                redraw();
            }
        }

        /// Called in arrange mode, when the user clicks and drags the beginning of a region.
        /// This alters the start frame of the region, without moving any frames temporally, i.e.,
        /// "shrinking" or "growing" the region.
        void onShrinkSubregionStart() {
            if(_editRegion !is null) {
                immutable nframes_t mouseFrame =
                    clamp(_mouseX, _editRegion.boundingBox.x0, _editRegion.boundingBox.x1) * samplesPerPixel +
                    viewOffset;
                if(mouseFrame < _editRegion.subregionEndFrame + _editRegion.offset) {
                    immutable nframes_t newStartFrame = mouseFrame - _editRegion.offset;
                    if(_editRegion.editPointOffset == _editRegion.subregionStartFrame) {
                        _editRegion.editPointOffset = newStartFrame;
                    }
                    _editRegion.subregionStartFrame = newStartFrame;
                }
                else {
                    immutable nframes_t newStartFrame = _editRegion.subregionEndFrame;
                    if(_editRegion.editPointOffset == _editRegion.subregionStartFrame) {
                        _editRegion.editPointOffset = newStartFrame;
                    }
                    _editRegion.subregionStartFrame = newStartFrame;
                }
                redraw();
            }
        }

        /// Called in arrange mode, when the user clicks and drags the end of a region.
        /// This alters the end frame of the region, without moving any frames temporally, i.e.,
        /// "shrinking" or "growing" the region.
        void onShrinkSubregionEnd() {
            if(_editRegion !is null) {
                immutable nframes_t mouseFrame =
                    clamp(_mouseX, _editRegion.boundingBox.x0, _editRegion.boundingBox.x1) * samplesPerPixel +
                    viewOffset;
                if(mouseFrame > _editRegion.subregionStartFrame + _editRegion.offset) {
                    immutable nframes_t newEndFrame = mouseFrame - _editRegion.offset;
                    if(_editRegion.editPointOffset == _editRegion.subregionEndFrame) {
                        _editRegion.editPointOffset = newEndFrame;
                    }
                    _editRegion.subregionEndFrame = newEndFrame;
                }
                else {
                    immutable nframes_t newEndFrame = _editRegion.subregionStartFrame;
                    if(_editRegion.editPointOffset == _editRegion.subregionEndFrame) {
                        _editRegion.editPointOffset = newEndFrame;
                    }
                    _editRegion.subregionEndFrame = newEndFrame;
                }
                redraw();
            }
        }

        /// Called when the user moves the mouse within this widget
        bool onMotionNotify(Event event, Widget widget) {
            if(event.type == EventType.MOTION_NOTIFY) {
                pixels_t prevMouseX = _mouseX;
                pixels_t prevMouseY = _mouseY;
                _mouseX = cast(typeof(_mouseX))(event.motion.x);
                _mouseY = cast(typeof(_mouseX))(event.motion.y);

                switch(_action) {
                    case Action.selectRegion:
                        if(!_selectedRegions.empty) {
                            _moveTrackIndex = _mouseOverTrackIndex(_mouseY);
                            _minMoveTrackIndex = _minPreviewTrackIndex(_selectedRegions);
                            _maxMoveTrackIndex = _maxPreviewTrackIndex(_selectedRegions);
                            foreach(regionView; _selectedRegions) {
                                regionView.previewTrackIndex = _trackIndex(regionView.trackView);
                            }
                            _setAction(Action.moveRegion);
                            redraw();
                        }
                        break;

                    case Action.mouseOverRegionStart:
                    case Action.mouseOverRegionEnd:
                        _mouseOverRegionEndpoints();
                        break;

                    case Action.shrinkRegionStart:
                        immutable nframes_t prevMouseFrame = viewOffset + max(prevMouseX, 0) * samplesPerPixel;
                        immutable nframes_t mouseFrame = viewOffset + max(_mouseX, 0) * samplesPerPixel;

                        // find the region that ends earliest
                        RegionView earliestEnd;
                        foreach(regionView; _selectedRegions) {
                            if(earliestEnd is null ||
                               earliestEnd.offset + earliestEnd.sliceEndFrame >
                               regionView.offset + regionView.sliceEndFrame) {
                                earliestEnd = regionView;
                            }
                        }

                        // shrink selected regions from the left
                        if(earliestEnd !is null) {
                            immutable nframes_t minRegionWidth = RegionView.cornerRadius * 2 * samplesPerPixel;

                            immutable nframes_t earliestEndStartFrame = mouseFrame > prevMouseFrame ?
                                earliestEnd.offset + (mouseFrame - prevMouseFrame) :
                                earliestEnd.offset - min(prevMouseFrame - mouseFrame, earliestEnd.offset);
                            auto shrinkResult = earliestEnd.shrinkStart(min(earliestEndStartFrame,
                                                                            earliestEnd.offset +
                                                                            earliestEnd.nframes - minRegionWidth));
                            if(shrinkResult.success) {
                                foreach(regionView; _selectedRegions) {
                                    if(regionView !is earliestEnd) {
                                        immutable nframes_t startFrame = mouseFrame > prevMouseFrame ?
                                            regionView.offset + shrinkResult.delta :
                                            regionView.offset - shrinkResult.delta;
                                        regionView.shrinkStart(min(startFrame,
                                                                   regionView.offset +
                                                                   regionView.nframes - minRegionWidth));
                                    }
                                }
                            }

                            redraw();
                        }
                        break;

                    case Action.shrinkRegionEnd:
                        immutable nframes_t prevMouseFrame = viewOffset + max(prevMouseX, 0) * samplesPerPixel;
                        immutable nframes_t mouseFrame = viewOffset + max(_mouseX, 0) * samplesPerPixel;

                        // find the region that starts latest
                        RegionView latestStart;
                        foreach(regionView; _selectedRegions) {
                            if(latestStart is null || latestStart.offset < regionView.offset) {
                                latestStart = regionView;
                            }
                        }

                        // shrink selected regions from the right
                        if(latestStart !is null) {
                            immutable nframes_t latestStartEndFrame = mouseFrame > prevMouseFrame ?
                                latestStart.offset + latestStart.nframes + (mouseFrame - prevMouseFrame) :
                                latestStart.offset + latestStart.nframes -
                                min(prevMouseFrame - mouseFrame, latestStart.nframes);
                            auto shrinkResult = latestStart.shrinkEnd(latestStartEndFrame);
                            if(shrinkResult.success) {
                                foreach(regionView; _selectedRegions) {
                                    if(regionView !is latestStart) {
                                        immutable nframes_t endFrame = mouseFrame > prevMouseFrame ?
                                            regionView.offset + regionView.nframes + shrinkResult.delta :
                                            regionView.offset + regionView.nframes - shrinkResult.delta;
                                        regionView.shrinkEnd(endFrame);
                                    }
                                }
                            }

                            redraw();
                        }
                        break;

                    case Action.selectSubregion:
                        onSelectSubregion();
                        break;

                    case Action.shrinkSubregionStart:
                        onShrinkSubregionStart();
                        break;

                    case Action.shrinkSubregionEnd:
                        onShrinkSubregionEnd();
                        break;

                    case Action.mouseOverSubregionStart:
                    case Action.mouseOverSubregionEnd:
                        _mouseOverSubregionEndpoints();
                        break;

                    case Action.selectBox:
                        redraw();
                        break;

                    case Action.moveRegion:
                        if(!_moveTrackIndex.isNull) {
                            auto newMoveTrackIndex = _mouseOverTrackIndex(_mouseY);
                            if(!newMoveTrackIndex.isNull() && newMoveTrackIndex != _moveTrackIndex) {
                                if(newMoveTrackIndex > _moveTrackIndex) {
                                    // move the selected regions down one track, if possible
                                    auto delta = newMoveTrackIndex - _moveTrackIndex;
                                    if(_maxMoveTrackIndex + delta < _trackViews.length) {
                                        _moveTrackIndex += delta;
                                        foreach(regionView; _selectedRegions) {
                                            regionView.previewTrackIndex += delta;
                                        }
                                        _minMoveTrackIndex = _minPreviewTrackIndex(_selectedRegions);
                                        _maxMoveTrackIndex = _maxPreviewTrackIndex(_selectedRegions);
                                    }
                                }
                                else {
                                    // move the selected regions up one track, if possible
                                    auto delta = _moveTrackIndex - newMoveTrackIndex;
                                    if(_minMoveTrackIndex >= delta) {
                                        _moveTrackIndex -= delta;
                                        foreach(regionView; _selectedRegions) {
                                            regionView.previewTrackIndex -= delta;
                                        }
                                        _minMoveTrackIndex = _minPreviewTrackIndex(_selectedRegions);
                                        _maxMoveTrackIndex = _maxPreviewTrackIndex(_selectedRegions);
                                    }
                                }
                            }
                        }

                        foreach(regionView; _selectedRegions) {
                            immutable nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                            if(_mouseX > prevMouseX) {
                                regionView.previewOffset += deltaXSamples;
                            }
                            else if(_earliestSelectedRegion.previewOffset > abs(deltaXSamples)) {
                                regionView.previewOffset -= deltaXSamples;
                            }
                            else {
                                regionView.previewOffset =
                                    regionView.offset > _earliestSelectedRegion.offset ?
                                    regionView.offset - _earliestSelectedRegion.offset : 0;
                            }
                        }

                        redraw();
                        break;

                    case Action.moveMarker:
                        immutable nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                        if(_mouseX > prevMouseX) {
                            if(_moveMarker.offset + deltaXSamples >= _mixer.timeline.lastFrame) {
                                _moveMarker.offset = _mixer.timeline.lastFrame;
                            }
                            else {
                                _moveMarker.offset += deltaXSamples;
                            }
                        }
                        else if(_moveMarker.offset > abs(deltaXSamples)) {
                            _moveMarker.offset -= deltaXSamples;
                        }
                        else {
                            _moveMarker.offset = 0;
                        }
                        redraw();
                        break;

                    case Action.moveOnset:
                        immutable nframes_t deltaXSamples = abs(_mouseX - prevMouseX) * samplesPerPixel;
                        immutable Direction direction = (_mouseX > prevMouseX) ? Direction.right : Direction.left;
                        _moveOnsetFrameDest = _editRegion.moveOnset(_moveOnsetIndex,
                                                                    _moveOnsetFrameDest,
                                                                    deltaXSamples,
                                                                    direction,
                                                                    _moveOnsetChannel);

                        redraw();
                        break;

                    case Action.moveTransport:
                        redraw();
                        break;

                    case Action.none:
                    default:
                        if(_mode == Mode.arrange) {
                            _mouseOverRegionEndpoints();
                        }
                        else if(_mode == Mode.editRegion) {
                            _mouseOverSubregionEndpoints();
                        }
                        break;
                }
            }
            return true;
        }

        /// Called when the mouse leaves this widget
        bool onLeaveNotify(GdkEventCrossing* eventCrossing, Widget widget) {
            switch(_action) {
                case Action.mouseOverRegionStart:
                case Action.mouseOverRegionEnd:
                case Action.mouseOverSubregionStart:
                case Action.mouseOverSubregionEnd:
                    _setAction(Action.none);
                    break;

                default:
                    break;
            }

            return false;
        }

        /// Called when the user presses a mouse button within this widget
        bool onButtonPress(Event event, Widget widget) {
            GdkModifierType state;
            event.getState(state);
            auto shiftPressed = state & GdkModifierType.SHIFT_MASK;
            auto controlPressed = state & GdkModifierType.CONTROL_MASK;

            if(event.type == EventType.BUTTON_PRESS && event.button.button == leftButton) {
                // if the mouse is over a marker, move that marker
                auto marker = _mouseOverMarker();
                if(!marker.isNull()) {
                    _moveMarker = marker;
                    _setAction(Action.moveMarker);
                }
                else {
                    // if the mouse was not over a marker, but is over the time strip, move the transport
                    if(_mouseY >= 0 && _mouseY <
                       ((_vScroll.pixelsOffset < timeStripHeightPixels + markerHeightPixels) ?
                        timeStripHeightPixels + markerHeightPixels - _vScroll.pixelsOffset :
                        timeStripHeightPixels)) {
                        _setAction(Action.moveTransport);
                    }
                    else {
                        bool newAction;

                        switch(_mode) {
                            // implement different behaviors for button presses depending on the current mode
                            case Mode.arrange:
                                TrackView trackView = _mouseOverTrack(_mouseY);

                                RegionView mouseOverRegion;
                                if(trackView !is null) {
                                    // detect if the mouse is over an audio region
                                    foreach(regionView; retro(trackView.regionViews)) {
                                        if(_mouseX >= regionView.boundingBox.x0 &&
                                           _mouseX < regionView.boundingBox.x1) {
                                            mouseOverRegion = regionView;
                                            break;
                                        }
                                    }

                                    // detect if the mouse is near one of the endpoints of a region;
                                    // if so, begin adjusting that endpoint
                                    if(!shiftPressed) {
                                        if(_action == Action.mouseOverRegionStart &&
                                           _mouseOverRegionStart !is null) {
                                            if(!_mouseOverRegionStart.selected) {
                                                // deselect all other regions
                                                foreach(regionView; _selectedRegions) {
                                                    regionView.selected = false;
                                                }
                                                _selectedRegionsApp.clear();

                                                // select this region
                                                _selectedRegionsApp.put(_mouseOverRegionStart);
                                                _mouseOverRegionStart.selected = true;
                                            }
                                            _computeEarliestSelectedRegion();

                                            // begin shrinking the start of the selected regions
                                            _setAction(Action.shrinkRegionStart);
                                            newAction = true;
                                        }
                                        else if(_action == Action.mouseOverRegionEnd &&
                                                _mouseOverRegionEnd !is null) {
                                            // select the region
                                            if(!_mouseOverRegionEnd.selected) {
                                                // deselect all other regions
                                                foreach(regionView; _selectedRegions) {
                                                    regionView.selected = false;
                                                }
                                                _selectedRegionsApp.clear();

                                                _selectedRegionsApp.put(_mouseOverRegionEnd);
                                                _mouseOverRegionEnd.selected = true;
                                            }
                                            _computeEarliestSelectedRegion();

                                            // begin shrinking the end of the selected regions
                                            _setAction(Action.shrinkRegionEnd);
                                            newAction = true;
                                        }
                                        else if(mouseOverRegion !is null &&
                                                mouseOverRegion.selected &&
                                                !shiftPressed) {
                                            _computeEarliestSelectedRegion();
                                            _setAction(Action.selectRegion);
                                            newAction = true;
                                        }
                                    }
                                }

                                if(!newAction) {
                                    // if the mouse is not over a region and no region is selected, do nothing
                                    if(mouseOverRegion is null && _selectedRegions.empty) {
                                        break;
                                    }

                                    // if this region is the only region currently selected, do nothing
                                    if(!(_selectedRegions.length == 1 && _selectedRegions[0] is mouseOverRegion)) {
                                        // if shift is not currently pressed, deselect all regions
                                        if(!shiftPressed) {
                                            foreach(regionView; _selectedRegions) {
                                                regionView.selected = false;
                                            }
                                            _earliestSelectedRegion = null;
                                        }

                                        _selectedRegionsApp.clear();
                                        if(mouseOverRegion !is null) {
                                            // if the region is already selected and shift is pressed, deselect it
                                            mouseOverRegion.selected = !(mouseOverRegion.selected && shiftPressed);
                                            newAction = true;
                                            if(mouseOverRegion.selected) {
                                                _selectedRegionsApp.put(mouseOverRegion);
                                            }
                                        }

                                        _computeEarliestSelectedRegion();
                                        _setAction(Action.selectRegion);

                                        appendArrangeState(
                                            currentArrangeState!(ArrangeStateType.selectedRegionsEdit));
                                    }
                                }
                                break;

                            case Mode.editRegion:
                                if(_editRegion !is null) {
                                    if(_action == Action.mouseOverSubregionStart) {
                                        _setAction(Action.shrinkSubregionStart);
                                        newAction = true;
                                    }
                                    else if(_action == Action.mouseOverSubregionEnd) {
                                        _setAction(Action.shrinkSubregionEnd);
                                        newAction = true;
                                    }

                                    if(_editRegion.showOnsets) {
                                        // detect if the mouse is over an onset
                                        _moveOnsetChannel = _editRegion.mouseOverChannel(_mouseY);
                                        if(_editRegion.getOnset(viewOffset + _mouseX * samplesPerPixel -
                                                                _editRegion.offset,
                                                                mouseOverThreshold * samplesPerPixel,
                                                                _moveOnsetFrameSrc,
                                                                _moveOnsetIndex,
                                                                _moveOnsetChannel)) {
                                            _moveOnsetFrameDest = _moveOnsetFrameSrc;
                                            _setAction(Action.moveOnset);
                                            newAction = true;
                                        }
                                    }

                                    if(!newAction) {
                                        if(_editRegion.boundingBox.containsPoint(_mouseX, _mouseY)) {
                                            if(_editRegion.subregionSelected && shiftPressed) {
                                                // append to the selected subregion
                                                onSelectSubregion();
                                                _setAction(Action.selectSubregion);
                                                newAction = true;
                                            }
                                            else {
                                                // move the edit point and start selecting a subregion
                                                immutable auto oldEditPointOffset = _editRegion.editPointOffset;
                                                _editRegion.editPointOffset =
                                                    cast(nframes_t)(_mouseX * samplesPerPixel) + viewOffset -
                                                    _editRegion.offset;
                                                if(_editRegion.editPointOffset != oldEditPointOffset) {
                                                    _editRegion.subregionStartFrame = _editRegion.editPointOffset;
                                                    _editRegion.subregionEndFrame = _editRegion.editPointOffset;
                                                    _setAction(Action.selectSubregion);
                                                }
                                                newAction = true;
                                            }
                                        }
                                    }
                                }
                                break;

                            default:
                                break;
                        }

                        if(!newAction && _mode == Mode.arrange) {
                            _selectMouseX = _mouseX;
                            _selectMouseY = _mouseY;
                            _setAction(Action.selectBox);
                        }
                    }

                    redraw();
                }
            }
            else if(event.type == EventType.BUTTON_PRESS && event.button.button == rightButton) {
                auto buttonEvent = event.button;

                switch(_mode) {
                    case Mode.arrange:
                        // if the mouse is over a marker, display the marker menu
                        auto marker = _mouseOverMarker();
                        if(!marker.isNull()) {
                            _selectedMarker = marker;

                            if(_markerMenu is null) {
                                _createMarkerMenu();
                            }
                            _markerMenu.popup(buttonEvent.button, buttonEvent.time);
                            _markerMenu.showAll();
                        }
                        // otherwise, display the arrange menu
                        else {
                            if(_arrangeMenu is null) {
                                _createArrangeMenu();
                            }
                            _arrangeMenu.popup(buttonEvent.button, buttonEvent.time);
                            _editRegionMenuItem.setSensitive(!_selectedRegions.empty);
                            _arrangeMenu.showAll();
                        }
                        break;

                    case Mode.editRegion:
                        if(_editRegionMenu is null) {
                            _editRegionMenu = new Menu();
                            _createEditRegionMenu(_editRegionMenu,
                                                  _gainMenuItem,
                                                  _normalizeMenuItem,
                                                  _reverseMenuItem,
                                                  _fadeInMenuItem,
                                                  _fadeOutMenuItem,
                                                  _stretchSelectionMenuItem,
                                                  _showOnsetsMenuItem,
                                                  _onsetDetectionMenuItem,
                                                  _linkChannelsMenuItem);
                            _editRegionMenu.attachToWidget(this, null);
                        }

                        _updateEditRegionMenu(_gainMenuItem,
                                              _normalizeMenuItem,
                                              _reverseMenuItem,
                                              _fadeInMenuItem,
                                              _fadeOutMenuItem,
                                              _stretchSelectionMenuItem,
                                              _showOnsetsMenuItem,
                                              _onsetDetectionMenuItem,
                                              _linkChannelsMenuItem);
                        _menuBar.updateRegionMenu();

                        _editRegionMenu.popup(buttonEvent.button, buttonEvent.time);
                        _editRegionMenu.showAll();
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        /// Called when the user releases a mouse button within this widget
        bool onButtonRelease(Event event, Widget widget) {
            if(event.type == EventType.BUTTON_RELEASE && event.button.button == leftButton) {
                switch(_action) {
                    // reset the cursor if necessary
                    case Action.selectRegion:
                        _setAction(Action.none);
                        redraw();
                        break;

                    case Action.shrinkRegionStart:
                    case Action.shrinkRegionEnd:
                        _setAction(Action.none);
                        appendArrangeState(currentArrangeState!(ArrangeStateType.selectedRegionsEdit));
                        break;

                    // select a subregion
                    case Action.selectSubregion:
                        _editRegion.subregionSelected =
                            !(_editRegion.subregionStartFrame == _editRegion.subregionEndFrame);

                        _editRegion.appendEditState(_editRegion.currentEditState(false), "Selection modified");

                        _setAction(Action.none);
                        redraw();
                        break;

                    // move the endpoints of the selected subregion
                    case Action.shrinkSubregionStart:
                        _setAction(Action.none);
                        _mouseOverSubregionEndpoints();
                        break;

                    case Action.shrinkSubregionEnd:
                        _setAction(Action.none);
                        _mouseOverSubregionEndpoints();
                        break;

                    // select all regions within the selection box drawn with the mouse
                    case Action.selectBox:
                        _setAction(Action.none);
                        if(_mode == Mode.arrange) {
                            BoundingBox selectBox = BoundingBox(_selectMouseX, _selectMouseY, _mouseX, _mouseY);
                            bool regionFound;
                            foreach(regionView; _regionViews) {
                                if(selectBox.intersect(regionView.boundingBox) && !regionView.selected) {
                                    regionFound = true;
                                    regionView.selected = true;
                                    _selectedRegionsApp.put(regionView);
                                }
                            }
                            _computeEarliestSelectedRegion();

                            if(regionFound) {
                                appendArrangeState(currentArrangeState!(ArrangeStateType.selectedRegionsEdit));
                            }
                        }
                        redraw();
                        break;

                    // move a region by setting its global frame offset
                    case Action.moveRegion:
                        _setAction(Action.none);
                        bool regionModified;
                        bool tracksModified;
                        foreach(regionView; _selectedRegions) {
                            if(regionView.offset != regionView.previewOffset) {
                                regionView.offset = regionView.previewOffset;
                                _mixer.timeline.resizeIfNecessary(regionView.offset + regionView.nframes);
                                regionModified = true;
                            }

                            if(regionView.previewTrackIndex >= 0 &&
                               regionView.previewTrackIndex < _trackViews.length &&
                               regionView.previewTrackIndex != _trackIndex(regionView.trackView)) {
                                regionView.moveToTrack(_trackViews[regionView.previewTrackIndex]);
                                tracksModified = true;
                            }
                        }

                        if(regionModified) {
                            appendArrangeState(currentArrangeState!(ArrangeStateType.selectedRegionsEdit));
                        }
                        if(tracksModified) {
                            appendArrangeState(currentArrangeState!(ArrangeStateType.tracksEdit));
                        }
                        if(regionModified || tracksModified) {
                            _recomputeTrackViewRegions();
                        }

                        redraw();
                        break;

                    // stop moving a marker
                    case Action.moveMarker:
                        _setAction(Action.none);
                        break;

                    // stretch the audio inside a region
                    case Action.moveOnset:
                        immutable nframes_t onsetFrameStart =
                            _editRegion.getPrevOnset(_moveOnsetIndex, _moveOnsetChannel);
                        immutable nframes_t onsetFrameEnd =
                            _editRegion.getNextOnset(_moveOnsetIndex, _moveOnsetChannel);

                        OnsetSequence onsets = _editRegion.linkChannels ?
                            _editRegion._onsetsLinked : _editRegion._onsets[_moveOnsetChannel];
                        if(onsets[_moveOnsetIndex].leftSource && onsets[_moveOnsetIndex].rightSource) {
                            _editRegion.region.stretchThreePoint(onsetFrameStart,
                                                                 _moveOnsetFrameSrc,
                                                                 _moveOnsetFrameDest,
                                                                 onsetFrameEnd,
                                                                 _editRegion.linkChannels,
                                                                 _moveOnsetChannel,
                                                                 AudioSequence.AudioPieceTable(
                                                                     onsets[_moveOnsetIndex].leftSource),
                                                                 AudioSequence.AudioPieceTable(
                                                                     onsets[_moveOnsetIndex].rightSource));
                        }
                        else {
                            _editRegion.region.stretchThreePoint(onsetFrameStart,
                                                                 _moveOnsetFrameSrc,
                                                                 _moveOnsetFrameDest,
                                                                 onsetFrameEnd,
                                                                 _editRegion.linkChannels,
                                                                 _moveOnsetChannel);
                        }

                        if(_moveOnsetFrameDest == onsetFrameStart) {
                            if(_moveOnsetIndex > 0) {
                                onsets.replace([Onset(onsets[_moveOnsetIndex - 1].onsetFrame,
                                                      AudioSequence.AudioPieceTable(
                                                          onsets[_moveOnsetIndex - 1].leftSource),
                                                      AudioSequence.AudioPieceTable(
                                                          onsets[_moveOnsetIndex].rightSource))],
                                               _moveOnsetIndex - 1, _moveOnsetIndex + 1);
                            }
                            else {
                                onsets.remove(_moveOnsetIndex, _moveOnsetIndex + 1);
                            }
                        }
                        else if(_moveOnsetFrameDest == onsetFrameEnd) {
                            if(_moveOnsetIndex + 1 < onsets.length) {
                                onsets.replace([Onset(onsets[_moveOnsetIndex + 1].onsetFrame,
                                                      AudioSequence.AudioPieceTable(
                                                          onsets[_moveOnsetIndex].leftSource),
                                                      AudioSequence.AudioPieceTable(
                                                          onsets[_moveOnsetIndex + 1].rightSource))],
                                               _moveOnsetIndex, _moveOnsetIndex + 2);
                            }
                            else {
                                onsets.remove(_moveOnsetIndex, _moveOnsetIndex + 1);
                            }
                        }
                        else {
                            onsets.replace([Onset(_moveOnsetFrameDest,
                                                  AudioSequence.AudioPieceTable(
                                                      onsets[_moveOnsetIndex].leftSource),
                                                  AudioSequence.AudioPieceTable(
                                                      onsets[_moveOnsetIndex].rightSource))],
                                           _moveOnsetIndex, _moveOnsetIndex + 1);
                        }

                        _editRegion.appendEditState(_editRegion.currentEditState(true,
                                                                                 true,
                                                                                 true,
                                                                                 _moveOnsetChannel),
                                                    "Three-point stretch");

                        redraw();
                        _setAction(Action.none);
                        break;

                    case Action.moveTransport:
                        _setAction(Action.none);
                        _mixer.timeline.transportOffset =
                            viewOffset + (clamp(_mouseX, 0, viewWidthPixels) * samplesPerPixel);
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        /// Called when the user scrolls inside this widget, i.e., with the mouse scroll wheel
        bool onScroll(Event event, Widget widget) {
            if(event.type == EventType.SCROLL) {
                GdkModifierType state;
                event.getState(state);
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;

                ScrollDirection direction;
                event.getScrollDirection(direction);
                switch(direction) {
                    case ScrollDirection.LEFT:
                        if(controlPressed) {
                            _zoomOut();
                        }
                        else {
                            if(_hScroll.stepSamples <= viewOffset) {
                                _viewOffset -= _hScroll.stepSamples;
                            }
                            else {
                                _viewOffset = viewMinSamples;
                            }
                            _hScroll.update();
                            if(_action == Action.centerView ||
                               _action == Action.centerViewStart ||
                               _action == Action.centerViewEnd) {
                                _setAction(Action.none);
                            }
                            redraw();
                        }
                        break;

                    case ScrollDirection.RIGHT:
                        if(controlPressed) {
                            _zoomIn();
                        }
                        else {
                            if(_hScroll.stepSamples + viewOffset <= _mixer.timeline.lastFrame) {
                                _viewOffset += _hScroll.stepSamples;
                            }
                            else {
                                _viewOffset = _mixer.timeline.lastFrame;
                            }
                            _hScroll.update();
                            if(_action == Action.centerView ||
                               _action == Action.centerViewStart ||
                               _action == Action.centerViewEnd) {
                                _setAction(Action.none);
                            }
                            redraw();
                        }
                        break;

                    case ScrollDirection.UP:
                        if(controlPressed) {
                            _zoomOutVertical();
                        }
                        else {
                            _vScroll.pixelsOffset = _vScroll.pixelsOffset - _vScroll.stepIncrement;
                            _verticalPixelsOffset = _vScroll.pixelsOffset;
                            redraw();
                        }
                        break;

                    case ScrollDirection.DOWN:
                        if(controlPressed) {
                            _zoomInVertical();
                        }
                        else {
                            _vScroll.pixelsOffset = _vScroll.pixelsOffset + _vScroll.stepIncrement;
                            _verticalPixelsOffset = cast(pixels_t)(_vScroll.pixelsOffset);
                            redraw();
                        }
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

        /// Called when the user presses a key within this widget
        bool onKeyPress(Event event, Widget widget) {
            if(event.type == EventType.KEY_PRESS) {
                switch(_action) {
                    // insert a new marker
                    case Action.createMarker:
                        _setAction(Action.none);
                        wchar keyval = cast(wchar)(Keymap.keyvalToUnicode(event.key.keyval));
                        if(isAlpha(keyval) || isNumber(keyval)) {
                            _markers[event.key.keyval] = new Marker(_mixer.timeline.transportOffset,
                                                                    to!string(keyval));
                            redraw();
                        }
                        return false;

                    case Action.jumpToMarker:
                        _setAction(Action.none);
                        try {
                            _mixer.timeline.transportOffset = _markers[event.key.keyval].offset;
                            redraw();
                        }
                        catch(RangeError) {
                        }
                        return false;

                    default:
                        break;
                }

                GdkModifierType state;
                event.getState(state);
                auto shiftPressed = state & GdkModifierType.SHIFT_MASK;
                auto controlPressed = state & GdkModifierType.CONTROL_MASK;

                switch(event.key.keyval) {
                    case GdkKeysyms.GDK_space:
                        if(shiftPressed) {
                            if(_mode == Mode.editRegion && _editRegion.subregionSelected) {
                                // loop the selected subregion
                                _mixer.timeline.transportOffset =
                                    _editRegion.subregionStartFrame + _editRegion.offset;
                                _mixer.enableLoop(_editRegion.subregionStartFrame + _editRegion.offset,
                                                  _editRegion.subregionEndFrame + _editRegion.offset);
                                _mixer.play();
                            }
                        }
                        else {
                            // toggle play/pause for the mixer
                            if(_mixer.playing) {
                                _mixer.pause();
                            }
                            else {
                                if(_mode == Mode.editRegion) {
                                    _mixer.timeline.transportOffset =
                                        _editRegion.editPointOffset + _editRegion.offset;
                                }
                                _mixer.play();
                            }
                        }
                        _menuBar.updateMixerMenu();
                        redraw();
                        break;

                    case GdkKeysyms.GDK_equal:
                        _zoomIn();
                        break;

                    case GdkKeysyms.GDK_minus:
                        _zoomOut();
                        break;

                    case GdkKeysyms.GDK_Return:
                        // move the transport to the last marker
                        Marker* lastMarker;
                        foreach(ref marker; _markers) {
                            if(!lastMarker ||
                               (marker.offset > lastMarker.offset &&
                                marker.offset < _mixer.timeline.transportOffset)) {
                                lastMarker = &marker;
                            }
                        }
                        _mixer.timeline.transportOffset = lastMarker ? lastMarker.offset : 0;
                        redraw();
                        break;

                    // Shift + Alt + <
                    case GdkKeysyms.GDK_macron:
                        // move the transport and view to the beginning of the project
                        _mixer.timeline.transportOffset = 0;
                        _viewOffset = viewMinSamples;
                        redraw();
                        break;

                    // Shift + Alt + >
                    case GdkKeysyms.GDK_breve:
                        // move the transport to end of the project and center the view on the transport
                        _mixer.timeline.transportOffset = _mixer.timeline.lastFrame;
                        if(viewMaxSamples >= (viewWidthSamples / 2) * 3) {
                            _viewOffset = viewMaxSamples - (viewWidthSamples / 2) * 3;
                        }
                        redraw();
                        break;

                    // Alt + f
                    case GdkKeysyms.GDK_function:
                        // seek the transport forward (large increment)
                        _mixer.timeline.transportOffset = min(_mixer.timeline.lastFrame,
                                                              _mixer.timeline.transportOffset + largeSeekIncrement);
                        redraw();
                        break;

                    // Alt + b
                    case GdkKeysyms.GDK_integral:
                        // seek the transport backward (large increment)
                        _mixer.timeline.transportOffset = _mixer.timeline.transportOffset > largeSeekIncrement ?
                            _mixer.timeline.transportOffset - largeSeekIncrement : 0;
                        redraw();
                        break;

                    case GdkKeysyms.GDK_BackSpace:
                        if(_mode == Mode.arrange && _selectedRegions.length > 0) {
                            _removeSelectedRegions();
                            redraw();
                        }
                        else if(_mode == Mode.editRegion && _editRegion.subregionSelected) {
                            // remove the selected subregion
                            _editRegion.region.removeLocal(_editRegion.subregionStartFrame,
                                                           _editRegion.subregionEndFrame);

                            _editRegion.subregionSelected = false;

                            if(_editRegion.showOnsets) {
                                _editRegion.computeOnsets();
                            }
                            _editRegion.appendEditState(_editRegion.currentEditState(true, true),
                                                        "Subregion delete");

                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_a:
                        if(controlPressed) {
                            // move the transport to the minimum offset of all selected regions
                            if(_earliestSelectedRegion !is null) {
                                _mixer.timeline.transportOffset = _earliestSelectedRegion.offset;
                                redraw();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_b:
                        if(controlPressed) {
                            // seek the transport backward (small increment)
                            _mixer.timeline.transportOffset = _mixer.timeline.transportOffset > smallSeekIncrement ?
                                _mixer.timeline.transportOffset - smallSeekIncrement : 0;
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_c:
                        if(controlPressed) {
                            if(_mode == Mode.arrange) {
                                arrangeCopy();
                            }
                            else if(_mode == Mode.editRegion) {
                                editRegionCopy();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_e:
                        if(controlPressed) {
                            // move the transport to the maximum length of all selected regions
                            nframes_t maxOffset = 0;
                            bool foundRegion;
                            foreach(regionView; _selectedRegions) {
                                if(regionView.offset + regionView.nframes > maxOffset) {
                                    maxOffset = regionView.offset + regionView.nframes;
                                    foundRegion = true;
                                }
                            }
                            if(foundRegion) {
                                _mixer.timeline.transportOffset = maxOffset;
                                redraw();
                            }
                        }
                        else {
                            // toggle edit mode
                            _setMode(_mode == Mode.editRegion ? Mode.arrange : Mode.editRegion);
                        }
                        break;

                    case GdkKeysyms.GDK_f:
                        if(controlPressed) {
                            // seek the transport forward (small increment)
                            _mixer.timeline.transportOffset =
                                min(_mixer.timeline.lastFrame, _mixer.timeline.transportOffset + smallSeekIncrement);
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_h:
                        if(controlPressed) {
                            if(_mode == Mode.arrange) {
                                if(_selectedRegions.length == _regionViews.length) {
                                    // deselect all regions
                                    foreach(regionView; _selectedRegions) {
                                        regionView.selected = false;
                                    }
                                    _earliestSelectedRegion = null;
                                    _selectedRegionsApp.clear();
                                }
                                else {
                                    // select all regions
                                    _selectedRegionsApp.clear();
                                    foreach(regionView; _regionViews) {
                                        regionView.selected = true;
                                        _selectedRegionsApp.put(regionView);
                                    }
                                    _computeEarliestSelectedRegion();
                                }
                            }
                            else if(_mode == Mode.editRegion && _editRegion !is null) {
                                if(_editRegion.subregionSelected &&
                                   _editRegion.subregionStartFrame == 0 &&
                                   _editRegion.subregionEndFrame == _editRegion.nframes) {
                                    // deselect the entire region
                                    _editRegion.subregionSelected = false;
                                }
                                else {
                                    // select the entire region
                                    _editRegion.subregionSelected = true;
                                    _editRegion.subregionStartFrame = 0;
                                    _editRegion.subregionEndFrame = _editRegion.nframes;
                                }
                            }
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_i:
                        // if control is pressed, prompt the user to import an audio file
                        if(controlPressed && _mode == Mode.arrange) {
                            onImportFile();
                        }
                        break;

                    case GdkKeysyms.GDK_j:
                        // if control is pressed, jump to a marker that is about to be specified
                        if(controlPressed) {
                            _setAction(Action.jumpToMarker);
                        }
                        break;

                    case GdkKeysyms.GDK_l:
                        // center the view on the transport, emacs-style
                        if(_action == Action.centerViewStart) {
                            _viewOffset = _mixer.timeline.transportOffset;
                            _setAction(Action.centerViewEnd);
                        }
                        else if(_action == Action.centerViewEnd) {
                            if(_mixer.timeline.transportOffset > viewWidthSamples) {
                                _viewOffset = _mixer.timeline.transportOffset - viewWidthSamples;
                            }
                            else {
                                _viewOffset = viewMinSamples;
                            }
                            _setAction(Action.centerView);
                        }
                        else {
                            if(_mixer.timeline.transportOffset < viewWidthSamples / 2) {
                                _viewOffset = viewMinSamples;
                            }
                            else if(_mixer.timeline.transportOffset > viewMaxSamples - viewWidthSamples / 2) {
                                _viewOffset = viewMaxSamples;
                            }
                            else {
                                _viewOffset = _mixer.timeline.transportOffset - viewWidthSamples / 2;
                            }
                            _setAction(Action.centerViewStart);
                        }
                        _centeredView = true;
                        redraw();
                        _hScroll.update();
                        break;

                    case GdkKeysyms.GDK_m:
                        // if control is pressed, create a marker at the current transport position
                        if(controlPressed) {
                            _setAction(Action.createMarker);
                        }
                        // otherwise, mute selected regions
                        else if(_mode == Mode.arrange) {
                            foreach(regionView; _selectedRegions) {
                                regionView.region.mute = !regionView.region.mute;
                            }
                            redraw();
                        }
                        else if(_mode == Mode.editRegion) {
                            _editRegion.region.mute = !_editRegion.region.mute;
                            redraw();
                        }
                        break;

                    case GdkKeysyms.GDK_n:
                        // if control is pressed, prompt the user to start a new session
                        if(controlPressed && _mode == Mode.arrange) {
                            _menuBar.onNew();
                        }
                        break;

                    case GdkKeysyms.GDK_q:
                        // if control is pressed, prompt the user to quit the application
                        if(controlPressed && _mode == Mode.arrange) {
                            _menuBar.onQuit();
                        }
                        break;

                    case GdkKeysyms.GDK_v:
                        if(controlPressed) {
                            if(_mode == Mode.arrange) {
                                arrangePaste();
                            }
                            else if(_mode == Mode.editRegion && _copyBuffer.length > 0) {
                                editRegionPaste();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_x:
                        if(controlPressed) {
                            if(_mode == Mode.arrange) {
                                arrangeCut();
                            }
                            else if(_mode == Mode.editRegion && _editRegion.subregionSelected) {
                                editRegionCut();
                            }
                        }
                        break;

                    case GdkKeysyms.GDK_y:
                        if(_mode == Mode.arrange) {
                            redoArrange();
                            redraw();
                        }
                        else if(_mode == Mode.editRegion) {
                            editRegionRedo();
                        }
                        break;

                    case GdkKeysyms.GDK_z:
                        if(_mode == Mode.arrange) {
                            undoArrange();
                        }
                        else if(_mode == Mode.editRegion) {
                            editRegionUndo();
                        }
                        break;

                    default:
                        break;
                }
            }
            return false;
        }

    private:
        /// Returns: A `Marker` object if the mouse is over a marker; otherwise, `null`
        Nullable!Marker _mouseOverMarker() {
            Nullable!Marker result;
            if(_mouseY >= markerYOffset && _mouseY < markerYOffset + markerHeightPixels) {
                foreach(ref marker; _markers) {
                    if(marker.offset >= viewOffset && marker.offset < viewOffset + viewWidthSamples &&
                       (cast(pixels_t)((marker.offset - viewOffset) / samplesPerPixel) -
                        markerHeadWidthPixels / 2 <= _mouseX) &&
                       (cast(pixels_t)((marker.offset - viewOffset) / samplesPerPixel) +
                        markerHeadWidthPixels / 2 >= _mouseX)) {
                        result = marker;
                        return result;
                    }
                }
            }
            return result;
        }

        /// This function checks if the mouse is hovering over the endpoints of any region.
        /// If so, it modifies the current cursor to denote that a shrink operation
        /// is possible if the user presses the mouse button.
        void _mouseOverRegionEndpoints() {
            if(_mode == Mode.arrange) {
                _mouseOverRegionStart = null;
                _mouseOverRegionEnd = null;

                bool foundRegion;
                TrackView trackView = _mouseOverTrack(_mouseY);
                if(trackView !is null) {
                    foreach(regionView; retro(trackView.regionViews)) {
                        if(_mouseY >= regionView.boundingBox.y0 + RegionView.headerHeight) {
                            if(_mouseX >= regionView.boundingBox.x0 - mouseOverThreshold &&
                               _mouseX <= regionView.boundingBox.x0 + mouseOverThreshold) {
                                _mouseOverRegionStart = regionView;
                                _setAction(Action.mouseOverRegionStart);
                                foundRegion = true;
                            }
                            else if(_mouseX >= regionView.boundingBox.x1 - mouseOverThreshold &&
                                    _mouseX <= regionView.boundingBox.x1 + mouseOverThreshold) {
                                _mouseOverRegionEnd = regionView;
                                _setAction(Action.mouseOverRegionEnd);
                                foundRegion = true;
                            }
                        }
                    }
                }

                if(!foundRegion &&
                   (_action == Action.mouseOverRegionStart || _action == Action.mouseOverRegionEnd)) {
                    _setAction(Action.none);
                }
            }
        }

        /// This function checks if the mouse is hovering over the endpoints of the currently selected
        /// subregion, if any. If so, it modifies the current cursor to denote that a subregion shrink
        /// operation is possible if the user presses the mouse button.
        void _mouseOverSubregionEndpoints() {
            if(_mode == Mode.editRegion &&
               _editRegion !is null &&
               _editRegion.subregionSelected &&
               _action != Action.shrinkSubregionStart &&
               _action != Action.shrinkSubregionEnd) {
                // check if the mouse is near the ends of the selected subregion
                if(_mouseX >= _editRegion.subregionBox.x1 - mouseOverThreshold &&
                        _mouseX <= _editRegion.subregionBox.x1 + mouseOverThreshold) {
                    _setAction(Action.mouseOverSubregionEnd);
                }
                else if(_mouseX >= _editRegion.subregionBox.x0 - mouseOverThreshold &&
                   _mouseX <= _editRegion.subregionBox.x0 + mouseOverThreshold) {
                    _setAction(Action.mouseOverSubregionStart);
                }
                else if(_action == Action.mouseOverSubregionStart ||
                        _action == Action.mouseOverSubregionEnd) {
                    _setAction(Action.none);
                }
            }
        }

        pixels_t _mouseX;
        pixels_t _mouseY;
        pixels_t _selectMouseX;
        pixels_t _selectMouseY;
    }

    /// A marker object; effectively a positional hotkey within a session.
    static class Marker {
    public:
        this(nframes_t offset, string name) {
            this.offset = offset;
            this.name = name;
        }

        nframes_t offset;
        string name;
    }

    /// Create and register a new track with the current session
    void createTrackView(string trackName) {
        _createTrackView(trackName);
        appendArrangeState(currentArrangeState!(ArrangeStateType.tracksEdit), true);
    }

    /// Create and register a new track with the current session
    /// Params:
    /// region = A region to immediately add to the new track
    void createTrackView(string trackName, Region region) {
        auto newTrackView = _createTrackView(trackName);
        newTrackView.createRegion(region);
        appendArrangeState(currentArrangeState!(ArrangeStateType.tracksEdit), true);
    }

    /// Unregisters the specified track with the current session
    void deleteTrackView(TrackView deleteTrack) {
        if(_mode != Mode.arrange) {
            _setMode(Mode.arrange);
        }

        auto regionViewsApp = appender!(RegionView[]);
        foreach(regionView; _regionViews) {
            if(regionView.trackView !is deleteTrack) {
                regionViewsApp.put(regionView);
            }
        }
        _regionViews = regionViewsApp.data;

        auto trackViewsApp = appender!(TrackView[]);
        foreach(trackView; _trackViews) {
            if(trackView !is deleteTrack) {
                trackViewsApp.put(trackView);
            }
        }
        _trackViews = trackViewsApp.data;

        _redrawAll();
        _menuBar.updateTrackMenu();
        appendArrangeState(currentArrangeState!(ArrangeStateType.tracksEdit), true);
    }

    /// Loads a list of files from disk, storing each in a new region/track
    void loadRegionsFromFiles(const(string[]) fileNames) {
        Nullable!SampleRateConverter resampleDialog(nframes_t originalSampleRate,
                                                    nframes_t newSampleRate) {
            Nullable!SampleRateConverter result;

            auto sampleRateDialog = new SampleRateDialog(originalSampleRate, newSampleRate);
            auto sampleRateResponse = sampleRateDialog.run();
            if(sampleRateResponse == ResponseType.OK) {
                result = sampleRateDialog.selectedSampleRateConverter;
            }

            return result;
        }

        static struct ResampleRequest {
            nframes_t originalSampleRate;
            nframes_t newSampleRate;
        }

        static struct ResampleResponse {
            Nullable!SampleRateConverter sampleRateConverter;
        }

        static struct ErrorMessage {
            string msg;
        }

        void dispatchRequests() {
            receiveTimeout(0.msecs,
                           (ResampleRequest resampleRequest) {
                               auto sampleRateConverter =
                                       resampleDialog(resampleRequest.originalSampleRate,
                                                      resampleRequest.newSampleRate);
                               send(locate(LoadState.mangleof),
                                    ResampleResponse(sampleRateConverter));
                           },
                           (ErrorMessage errorMessage) {
                               ErrorDialog.display(_parentWindow, errorMessage.msg);
                           });
        }

        void loadRegionTask(string fileName, LoadState.Callback progressCallback) {
            Nullable!SampleRateConverter resampleCallback(nframes_t originalSampleRate,
                                                          nframes_t newSampleRate) {
                Nullable!SampleRateConverter result;
                send(locate(uiThreadName),
                     ResampleRequest(originalSampleRate, newSampleRate));
                receive((ResampleResponse resampleResponse) {
                        result = resampleResponse.sampleRateConverter;
                    });
                return result;
            }

            auto newSequence = loadAudioFile(fileName,
                                             _mixer.sampleRate,
                                             &resampleCallback,
                                             progressCallback);
            if(newSequence is null) {
                if(progressCallback(LoadState.complete, 0)) {
                    send(locate(uiThreadName),
                         ErrorMessage("Could not load file " ~ baseName(fileName)));
                }
            }
            else {
                _audioSequencesApp.put(newSequence);
                auto newRegion = new Region(newSequence);
                createTrackView(newRegion.name, newRegion);
            }
        }
        alias RegionTaskDelegate = void delegate(LoadState.Callback);
        auto regionTaskList = appender!(ProgressTask!(RegionTaskDelegate)[]);
        foreach(fileName; fileNames) {
            regionTaskList.put(progressTask(baseName(fileName),
                                            delegate void(LoadState.Callback progressCallback) {
                                                loadRegionTask(fileName, progressCallback);
                                            }));
        }

        if(regionTaskList.data.length > 0) {
            beginProgressTask!(LoadState, true)(regionTaskList.data, &dispatchRequests);
            _canvas.redraw();
        }
    }

    /// Opens a file browser dialog, which allows the user to select one or more audio files to load
    void onImportFile() {
        if(_importFileChooser is null) {
            _importFileChooser = new FileChooserDialog("Import Audio File",
                                                       _parentWindow,
                                                       FileChooserAction.OPEN,
                                                       null,
                                                       null);
            _importFileChooser.setSelectMultiple(true);
        }

        auto response = _importFileChooser.run();
        if(response == ResponseType.OK) {
            ListSG fileList = _importFileChooser.getUris();
            auto fileNames = appender!(string[])();
            for(auto i = 0; i < fileList.length(); ++i) {
                string hostname;
                fileNames.put(URI.filenameFromUri(Str.toString(cast(char*)(fileList.nthData(i))), hostname));
            }
            _importFileChooser.hide();

            loadRegionsFromFiles(fileNames.data);
        }
        else if(response == ResponseType.CANCEL) {
            _importFileChooser.hide();
        }
        else {
            _importFileChooser.destroy();
            _importFileChooser = null;
        }
    }

    /// Opens a file browser dialog for exporting the current session to an audio file
    void onExportSession() {
        if(_exportFileChooser is null) {
            _exportFileChooser = new FileChooserDialog("Export Session",
                                                       _parentWindow,
                                                       FileChooserAction.SAVE,
                                                       null,
                                                       null);
            _exportFileChooser.setSelectMultiple(false);

            auto addFilter(string name, string pattern) {
                auto fileFilter = new FileFilter();
                fileFilter.setName(name);
                fileFilter.addPattern(pattern);
                _exportFileChooser.addFilter(fileFilter);
                return fileFilter;
            }

            auto defaultFilter = addFilter(AudioFileFormat.wavFilterName, "*.wav");
            addFilter(AudioFileFormat.flacFilterName, "*.flac");
            addFilter(AudioFileFormat.oggVorbisFilterName, "*.ogg");
            addFilter(AudioFileFormat.aiffFilterName, "*.aiff");
            addFilter(AudioFileFormat.cafFilterName, "*.caf");

            _exportFileChooser.setFilter(defaultFilter);
        }

        auto response = _exportFileChooser.run();
        if(response == ResponseType.OK) {
            string hostname;
            auto fileName = URI.filenameFromUri(_exportFileChooser.getUri(), hostname);
            _exportFileChooser.hide();

            if(std.file.exists(fileName)) {
                auto dialog = new MessageDialog(_parentWindow,
                                                GtkDialogFlags.MODAL,
                                                MessageType.QUESTION,
                                                ButtonsType.OK_CANCEL,
                                                "Are you sure? " ~ fileName ~ " will be overwritten.");
                auto overwriteResponse = dialog.run();
                dialog.destroy();
                if(overwriteResponse != ResponseType.OK) {
                    return;
                }
            }

            AudioBitDepth audioBitDepth;
            string audioFileFormat = _exportFileChooser.getFilter().getName();
            if(audioFileFormat == AudioFileFormat.wavFilterName ||
               audioFileFormat == AudioFileFormat.aiffFilterName ||
               audioFileFormat == AudioFileFormat.cafFilterName) {
                auto bitDepthDialog = new BitDepthDialog();
                auto bitDepthResponse = bitDepthDialog.run();
                if(bitDepthResponse != ResponseType.OK) {
                    return;
                }
                else {
                    audioBitDepth = bitDepthDialog.selectedBitDepth;
                }
            }

            auto progressTask =
                progressTask(fileName,
                             delegate void(SaveState.Callback progressCallback) {
                                 try {
                                     _mixer.exportSessionToFile(fileName,
                                                                cast(AudioFileFormat)
                                                                audioFileFormat,
                                                                audioBitDepth,
                                                                progressCallback);
                                 }
                                 catch(AudioError e) {
                                     ErrorDialog.display(_parentWindow, e.msg);
                                 }
                             });
            beginProgressTask!(SaveState, true)(progressTask);
        }
        else if(response == ResponseType.CANCEL) {
            _exportFileChooser.hide();
        }
        else {
            _exportFileChooser.destroy();
            _exportFileChooser = null;
        }
    }

    /// Sets the current mode to `Mode.editRegion`, if not already set
    void onEditRegion(MenuItem menuItem) {
        if(_mode != Mode.editRegion) {
            _setMode(Mode.editRegion);
        }
    }

    /// This function creates a progress dialog and updates a progress bar
    /// via the progress callback associated with the progress task.
    /// Additionally, this function will inform the progress task
    /// if the user cancels the operation.
    /// Params:
    /// taskList = A list of `ProgressTask` objects to execute sequentially
    /// dispatchMessages = A non-blocking delegate to handle custom messages during the dialog's lifetime
    void beginProgressTask(ProgressState,
                           bool cancelButton = false,
                           ProgressTask = .ProgressTask!(void delegate(ProgressState.Callback)))
        (ProgressTask[] progressTaskList, void delegate() dispatchMessages = null)
        if(__traits(isSame, TemplateOf!ProgressState, .ProgressState) &&
           __traits(isSame, TemplateOf!ProgressTask, .ProgressTask)) {
            enum progressRefreshRate = 10; /// Specified in Hz
            enum progressMessageTimeout = 10.msecs;

            auto progressDialog = new Dialog();
            progressDialog.setDefaultSize(400, 75);
            progressDialog.setTransientFor(_parentWindow);
            progressDialog.setModal(true);

            auto dialogBox = progressDialog.getContentArea();
            auto progressBar = new ProgressBar();
            dialogBox.packStart(progressBar, false, false, 20);

            auto progressLabel = new Label(string.init);
            dialogBox.packStart(progressLabel, false, false, 10);

            static if(cancelButton) {
                void onProgressCancel(Button button) {
                    progressDialog.response(ResponseType.CANCEL);
                }
                dialogBox.packEnd(ArrangeDialog.createCancelButton(&onProgressCancel), false, false, 10);
            }

            if(progressTaskList.length > 0) {
                // block on message crowding to ensure this thread receives the progress completion message
                setMaxMailboxSize(thisTid,
                                  LoadState.nStages * LoadState.stepsPerStage,
                                  OnCrowding.block);

                static bool progressTaskCancelled;
                static bool progressThreadRegistered;

                static bool progressCallback(ProgressState.Stage stage, double stageFraction) {
                    if(!progressThreadRegistered) {
                        register(ProgressState.mangleof, thisTid);
                    }

                    // send a progress message to the UI thread
                    send(locate(uiThreadName), ProgressState(stage, stageFraction));

                    // catch messages from the UI thread indicating that the computation was cancelled
                    if(!progressTaskCancelled) {
                        receiveTimeout(0.msecs, (bool cancel) { progressTaskCancelled = cancel; });
                    }

                    return !progressTaskCancelled;
                }

                Timeout progressTimeout;
                typeof(task(progressTaskList[size_t.init].taskFunc, &progressCallback)) currentTask;
                size_t currentTaskIndex;
                bool currentTaskComplete;

                bool onProgressRefresh() {
                    static string stageCases() {
                        string result;
                        foreach(stage; __traits(allMembers, ProgressState.Stage)[0 .. $ - 1]) {
                            result ~=
                                "case ProgressState.Stage." ~ cast(string)(stage) ~ ": " ~
                                "progressLabel.setText(" ~ 
                                "ProgressState.stageDescriptions[ProgressState.Stage." ~
                                cast(string)(stage) ~ "] ~ \": \" ~ " ~
                                "progressTaskList[currentTaskIndex].name); break;\n";
                        }
                        return result;
                    }

                    while(receiveTimeout(progressMessageTimeout,
                                         (ProgressState progressState) {
                                             progressBar.setFraction(progressState.completionFraction);

                                             final switch(progressState.stage) {
                                                 mixin(stageCases());

                                             case ProgressState.complete:
                                                 currentTaskComplete = true;
                                                 break;
                                             }
                                         })) {}

                    if(dispatchMessages !is null) {
                        dispatchMessages();
                    }

                    if(currentTaskComplete) {
                        currentTask.workForce();
                        ++currentTaskIndex;
                        if(currentTaskIndex < progressTaskList.length) {
                            progressThreadRegistered = false;
                            progressDialog.setTitle(progressTaskList[currentTaskIndex].name);
                            currentTask = task(progressTaskList[currentTaskIndex].taskFunc, &progressCallback);
                            currentTask.executeInNewThread();
                        }
                        else {
                            if(progressDialog.getWidgetStruct() !is null) {
                                progressDialog.response(ResponseType.ACCEPT);
                            }
                            progressTimeout.destroy();
                        }
                    }

                    return true;
                }

                progressTaskCancelled = false;
                progressThreadRegistered = false;
                progressDialog.setTitle(progressTaskList[currentTaskIndex].name);
                currentTask = task(progressTaskList[currentTaskIndex].taskFunc, &progressCallback);
                currentTask.executeInNewThread();

                progressTimeout = new Timeout(cast(uint)(1.0 / progressRefreshRate * 1000),
                                              &onProgressRefresh,
                                              false);

                progressDialog.showAll();
                auto response = progressDialog.run();
                if(response != ResponseType.ACCEPT) {
                    send(locate(ProgressState.mangleof), true);
                }

                progressTimeout.destroy();

                while(!currentTaskComplete) {
                    onProgressRefresh();
                }
            }

            if(progressDialog.getWidgetStruct() !is null) {
                progressDialog.destroy();
            }
        }

    /// Specialization for `beginProgressTask` for executing only a single `ProgressTask`
    void beginProgressTask(ProgressState,
                           bool cancelButton = false,
                           ProgressTask = .ProgressTask!(void delegate(ProgressState.Callback)))
        (ProgressTask task, void delegate() dispatchMessages = null)
        if(!is(ProgressTask == T[], T) &&
           __traits(isSame, TemplateOf!ProgressState, .ProgressState) &&
           __traits(isSame, TemplateOf!ProgressTask, .ProgressTask)) {
            ProgressTask[] taskList = new ProgressTask[](1);
            taskList[0] = task;
            beginProgressTask!(ProgressState, cancelButton, ProgressTask)(taskList, dispatchMessages);
        }

    void onShowOnsets(CheckMenuItem showOnsets) {
        _editRegion.showOnsets = showOnsets.getActive();
        _canvas.redraw();
    }

    void onLinkChannels(CheckMenuItem linkChannels) {
        _editRegion.linkChannels = linkChannels.getActive();
        _canvas.redraw();
    }

    void editRegionUndo() {
        if(_editRegion !is null) {
            _editRegion.undoEdit();
            _canvas.redraw();
        }
    }

    void editRegionRedo() {
        if(_editRegion !is null) {
            _editRegion.redoEdit();
            _canvas.redraw();
        }
    }

    void editRegionCopy() {
        if(_editRegion !is null && _editRegion.subregionSelected) {
            // save the selected subregion
            _copyBuffer = _editRegion.region.getSliceLocal(_editRegion.subregionStartFrame,
                                                           _editRegion.subregionEndFrame);
        }
    }

    void editRegionCut() {
        if(_editRegion !is null) {
            // copy the selected subregion, then remove it
            _copyBuffer = _editRegion.region.getSliceLocal(_editRegion.subregionStartFrame,
                                                           _editRegion.subregionEndFrame);
            _editRegion.region.removeLocal(_editRegion.subregionStartFrame,
                                           _editRegion.subregionEndFrame);

            _editRegion.subregionSelected = false;

            if(_editRegion.showOnsets) {
                _editRegion.computeOnsets();
            }
            _editRegion.appendEditState(_editRegion.currentEditState(true, true), "Cut subregion");

            _canvas.redraw();
        }
    }

    void editRegionPaste() {
        if(_editRegion !is null && _copyBuffer.length > 0) {
            // paste the copy buffer
            _editRegion.region.insertLocal(_copyBuffer,
                                           _editRegion.editPointOffset);

            // select the pasted region
            _editRegion.subregionSelected = true;
            _editRegion.subregionStartFrame = _editRegion.editPointOffset;
            _editRegion.subregionEndFrame = _editRegion.editPointOffset +
                cast(nframes_t)(_copyBuffer.length / _editRegion.nChannels);

            if(_editRegion.showOnsets) {
                _editRegion.computeOnsets();
            }
            _editRegion.appendEditState(_editRegion.currentEditState(true, true), "Paste subregion");

            _canvas.redraw();
        }
    }

    void arrangeCopy() {
        if(_mode == Mode.arrange && _selectedRegions.length > 0) {
            // save the selected regions to the copy buffer
            _copiedRegionStatesApp.clear();
            _copiedRegionStatesApp.reserve(_selectedRegions.length);
            foreach(regionView; _selectedRegions) {
                _copiedRegionStatesApp.put(RegionViewState(regionView,
                                                           regionView.offset,
                                                           regionView.sliceStartFrame,
                                                           regionView.sliceEndFrame));
            }
        }
    }

    void arrangeCut() {
        if(_mode == Mode.arrange && _selectedRegions.length > 0) {
            arrangeCopy();
            _removeSelectedRegions();
            _canvas.redraw();
        }
    }

    void arrangePaste() {
        if(_mode == Mode.arrange && _copiedRegionStates.length > 0) {
            // deselect all currently selected regions
            foreach(regionView; _selectedRegions) {
                regionView.selected = false;
            }
            _selectedRegionsApp.clear();

            // insert the copied regions at the transport offset
            immutable auto earliestOffset = _getEarliestRegion(_copiedRegionStates).offset;
            immutable auto copyOffset = earliestOffset > _mixer.timeline.transportOffset ?
                earliestOffset - _mixer.timeline.transportOffset :
                _mixer.timeline.transportOffset - earliestOffset;
            foreach(regionViewState; _copiedRegionStates) {
                auto regionView = regionViewState.regionView;

                auto trackView = regionView.trackView;
                Region newRegion;
                final switch(_copyMode) {
                    case CopyMode.soft:
                        newRegion = regionView.region.softCopy();
                        break;

                    case CopyMode.hard:
                        newRegion = regionView.region.hardCopy();
                        _audioSequencesApp.put(newRegion.audioSequence);
                        break;
                }
                auto newRegionView = trackView.createRegion(newRegion);
                newRegionView.sliceStartFrame = regionViewState.sliceStartFrame;
                newRegionView.sliceEndFrame = regionViewState.sliceEndFrame;
                newRegionView.selected = true;
                _selectedRegionsApp.put(newRegionView);
                newRegionView.offset = earliestOffset > _mixer.timeline.transportOffset ?
                    regionView.offset - copyOffset :
                    regionView.offset + copyOffset;
                _mixer.timeline.resizeIfNecessary(newRegionView.offset + newRegionView.nframes);
            }

            _computeEarliestSelectedRegion();
            appendArrangeState(currentArrangeState!(ArrangeStateType.tracksEdit), true);

            _canvas.redraw();
        }
    }

    /// Retrieve the current arrange state.
    /// Params:
    /// stateType = The type of the last edit in arrange mode
    @property ArrangeState currentArrangeState(ArrangeStateType stateType)() {
        static if(stateType == ArrangeStateType.masterBusEdit) {
            return ArrangeState(stateType, ChannelViewState(_masterBusView.faderGainDB));
        }
        else if(stateType == ArrangeStateType.tracksEdit) {
            auto trackStatesApp = appender!(TrackViewState[]);
            foreach(trackView; _trackViews) {
                trackStatesApp.put(TrackViewState(trackView,
                                                  trackView.regionViews,
                                                  trackView.faderGainDB));
            }
            return ArrangeState(stateType, TrackViewStateList(_selectedTrack, trackStatesApp.data));
        }
        else if(stateType == ArrangeStateType.selectedTrackEdit) {
            return ArrangeState(stateType, TrackViewState(_selectedTrack,
                                                          _selectedTrack.regionViews,
                                                          _selectedTrack.faderGainDB));
        }
        else if(stateType == ArrangeStateType.selectedRegionsEdit) {
            Appender!(RegionViewState[]) regionViewStates;
            foreach(regionView; _selectedRegions) {
                regionViewStates.put(RegionViewState(regionView,
                                                     regionView.offset,
                                                     regionView.sliceStartFrame,
                                                     regionView.sliceEndFrame));
            }
            return ArrangeState(stateType, regionViewStates.data.dup);
        }
    }

    /// Update the session according to the current arrange state.
    /// This function should be called after an undo/redo operation to
    /// effect the changes of the new arrange state.
    void updateCurrentArrangeState() {
        void updateMasterBus(ArrangeState arrangeState) {
            _masterBusView.faderGainDB = arrangeState.masterBusState.faderGainDB;
        }

        void updateTracks(ArrangeState arrangeState) {
            auto trackViewsApp = appender!(TrackView[]);
            auto regionViewsApp = appender!(RegionView[]);
            foreach(trackViewState; arrangeState.trackStates) {
                trackViewState.trackView.regionViews = trackViewState.regionViews;
                trackViewState.trackView.faderGainDB = trackViewState.faderGainDB;
                trackViewsApp.put(trackViewState.trackView);
                foreach(regionView; trackViewState.regionViews) {
                    regionViewsApp.put(regionView);
                }
            }
            _trackViews = trackViewsApp.data;
            _regionViews = regionViewsApp.data;
            _selectTrack(arrangeState.trackStates.selectedTrack);
        }

        void updateSelectedTrack(ArrangeState arrangeState) {
            // update the selected track
            _selectTrack(arrangeState.selectedTrackState.trackView);
            if(_selectedTrack !is null) {
                _selectedTrack.regionViews = arrangeState.selectedTrackState.regionViews;
                _selectedTrack.faderGainDB = arrangeState.selectedTrackState.faderGainDB;
            }
        }

        void updateSelectedRegions(ArrangeState arrangeState) {
            // clear the selection flag for all currently selected regions
            foreach(regionView; _selectedRegions) {
                regionView.selected = false;
            }
            _selectedRegionsApp.clear();

            // update selected regions
            foreach(regionViewState; arrangeState.selectedRegionStates) {
                regionViewState.regionView.selected = true;
                regionViewState.regionView.offset = regionViewState.offset;
                regionViewState.regionView.sliceStartFrame = regionViewState.sliceStartFrame;
                regionViewState.regionView.sliceEndFrame = regionViewState.sliceEndFrame;
                _selectedRegionsApp.put(regionViewState.regionView);
                _computeEarliestSelectedRegion();
            }
        }

        // update the master bus state to the last saved state in the undo history
        void backtrackMasterBus() {
            foreach(arrangeState; retro(_arrangeStateHistory.undoHistory)) {
                if(arrangeState.stateType == ArrangeStateType.masterBusEdit) {
                    updateMasterBus(arrangeState);
                    return;
                }
            }

            // if no state was found, reinitialize the master bus fader
            _masterBusView.channelStrip.zeroFader();
        }

        // update the track state to the last saved state in the undo history
        void backtrackTracks() {
            foreach(arrangeState; retro(_arrangeStateHistory.undoHistory)) {
                if(arrangeState.stateType == ArrangeStateType.tracksEdit) {
                    updateTracks(arrangeState);
                    break;
                }
            }
        }

        // update the selected region state to the last saved state in the undo history
        void backtrackSelectedRegions() {
            bool foundState;
            foreach(arrangeState; retro(_arrangeStateHistory.undoHistory)) {
                if(arrangeState.stateType == ArrangeStateType.selectedRegionsEdit) {
                    updateSelectedRegions(arrangeState);
                    foundState = true;

                    break;
                }
            }
            if(!foundState) {
                foreach(regionView; _selectedRegions) {
                    regionView.selected = false;
                }
                _selectedRegionsApp.clear();
            }
        }

        final switch(_arrangeStateHistory.currentState.stateType) {
            case ArrangeStateType.empty:
                _masterBusView.channelStrip.zeroFader();

                foreach(regionView; _selectedRegions) {
                    regionView.selected = false;
                }
                _selectedRegionsApp.clear();

                _selectedTrack = null;
                _trackViews = [];
                break;

            case ArrangeStateType.masterBusEdit:
                backtrackMasterBus();
                updateMasterBus(_arrangeStateHistory.currentState);
                break;

            case ArrangeStateType.tracksEdit:
                backtrackMasterBus();
                backtrackSelectedRegions();
                updateTracks(_arrangeStateHistory.currentState);
                break;

            case ArrangeStateType.selectedTrackEdit:
                backtrackMasterBus();
                backtrackSelectedRegions();
                updateSelectedTrack(_arrangeStateHistory.currentState);
                break;

            case ArrangeStateType.selectedRegionsEdit:
                backtrackMasterBus();
                backtrackTracks();
                updateSelectedRegions(_arrangeStateHistory.currentState);
                break;
        }

        _canvas.redraw();
        _trackStubs.redraw();
        _arrangeChannelStrip.update();
        _arrangeChannelStrip.redraw();
    }

    /// Append an arragne state to the undo history
    /// Params:
    /// arrangeState = The state of the last arrange operation
    /// updateSequenceBrowser = Whether the last arrange operation necessitates an update to the sequence browser
    void appendArrangeState(ArrangeState arrangeState, bool updateSequenceBrowser = false) {
        _arrangeStateHistory.appendState(arrangeState);
        if(updateSequenceBrowser && _sequenceBrowser !is null && _sequenceBrowser.isVisible()) {
            _sequenceBrowser.updateSequenceTreeView();
        }
        _savedState = false;
    }

    /// Returns: `true` if and only if an undo operation is possible
    bool queryUndoArrange() {
        return _arrangeStateHistory.queryUndo();
    }

    /// Returns: `true` if and only if a redo operation is possible
    bool queryRedoArrange() {
        return _arrangeStateHistory.queryRedo();
    }

    /// Undo the last arrange operation, if possible.
    /// This function will clear the redo history if the user subsequently executes a new operation.
    void undoArrange() {
        if(queryUndoArrange()) {
            _arrangeStateHistory.undo();
            updateCurrentArrangeState();

            if(_sequenceBrowser !is null && _sequenceBrowser.isVisible()) {
                _sequenceBrowser.updateSequenceTreeView();
            }
        }
    }

    /// Redo the last arrange operation, if possible.
    void redoArrange() {
        if(queryRedoArrange()) {
            _arrangeStateHistory.redo();
            updateCurrentArrangeState();

            if(_sequenceBrowser !is null && _sequenceBrowser.isVisible()) {
                _sequenceBrowser.updateSequenceTreeView();
            }
        }
    }

    /// State for an operation on a channel
    static struct ChannelViewState {
        sample_t faderGainDB;
    }

    /// State for an operation on a single track
    static struct TrackViewState {
        TrackView trackView;
        RegionView[] regionViews;
        sample_t faderGainDB;
    }

    /// State for an operation on multiple tracks
    static struct TrackViewStateList {
        TrackView selectedTrack;
        TrackViewState[] trackViewStates;
        alias trackViewStates this;
    }

    /// State for an operation on a single region
    static struct RegionViewState {
        RegionView regionView;
        nframes_t offset;
        nframes_t sliceStartFrame;
        nframes_t sliceEndFrame;
    }

    /// Enumeration of states corresponding to every undo-able arrange operation
    enum ArrangeStateType {
        empty,
        masterBusEdit,
        tracksEdit,
        selectedTrackEdit,
        selectedRegionsEdit
    }

    /// A structure containing a state type and the state data corresponding to that type.
    /// The state data is implemented via a private union type.
    static struct ArrangeState {
    public:
        /// A predicate indicating whether a given type is valid data for some state type
        static bool isValidStateData(T)() {
            foreach(member; __traits(allMembers, StateData)) {
                static if(is(T : typeof(mixin("StateData." ~ member)))) {
                    return true;
                }
            }
        }

        this(T)(ArrangeStateType stateType, T stateData) if(isValidStateData!T) {
            _stateType = stateType;

            foreach(member; __traits(allMembers, StateData)) {
                static if(is(T : typeof(mixin("StateData." ~ member)))) {
                    mixin("_stateData." ~ member ~ " = stateData;");
                    break;
                }
            }
        }

        /// Returns: A special empty state that corresponds to a new, unedited session
        static ArrangeState emptyState() {
            return ArrangeState();
        }

        /// Returns: The state type corresonding to this arrange state
        @property ArrangeStateType stateType() const { return _stateType; }

        mixin(_stateDataMembers());

    private:
        static string _stateDataMembers() {
            string result;
            foreach(member; __traits(allMembers, StateData)) {
                result ~= "@property auto ref " ~ member ~ "() { return _stateData." ~ member ~ "; }";
            }
            return result;
        }

        static union StateData {
            ChannelViewState masterBusState;
            TrackViewStateList trackStates;
            TrackViewState selectedTrackState;
            RegionViewState[] selectedRegionStates;
        }

        ArrangeStateType _stateType;
        StateData _stateData;
    }

    /// The number of samples represented by one pixel of screen space in the canvas
    @property nframes_t samplesPerPixel() const { return _samplesPerPixel; }

    /// The frame index corresponding to the leftmost visible pixel in the canvas
    @property nframes_t viewOffset() const { return _viewOffset; }

    /// The number of samples spanned by the currently visible section of the canvas
    @property nframes_t viewWidthSamples() { return _canvas.viewWidthPixels * _samplesPerPixel; }

    /// The minimum frame index viewable within the canvas
    @property nframes_t viewMinSamples() { return 0; }

    /// The maximum frame index viewable within the canvas
    @property nframes_t viewMaxSamples() { return _mixer.timeline.lastFrame + viewWidthSamples; }

private:
    /// Factor to use in calculations of track/region heights when zooming vertically
    enum _verticalZoomFactor = 1.2f;

    /// Set a limit on the maximum zoom level
    enum _verticalZoomFactorMax = _verticalZoomFactor * 3;

    /// Set a limit on the minimum zoom level
    enum _verticalZoomFactorMin = _verticalZoomFactor / 10;

    void _createArrangeMenu() {
        _arrangeMenu = new Menu();

        _arrangeMenu.append(new MenuItem(delegate void(MenuItem menuItem) { onImportFile(); },
                                         "_Import file...", true));
        _editRegionMenuItem = new MenuItem(&onEditRegion, "_Edit Region", "arrange.editRegion", true,
                                           _accelGroup, 'e', cast(GdkModifierType)(0));
        _arrangeMenu.append(_editRegionMenuItem);

        _arrangeMenu.attachToWidget(this, null);
    }

    void _createMarkerMenu() {
        _markerMenu = new Menu();

        _markerMenu.append(new MenuItem(delegate void(MenuItem menuItem) {
                    if(_selectedMarker !is null && _selectedMarker.name.length == 1) {
                        _markers.remove(to!wchar(_selectedMarker.name[0]));
                        _canvas.redraw();
                    }
                }, "_Delete marker", true));

        _markerMenu.attachToWidget(this, null);
    }

    TrackView _createTrackView(string trackName) {
        TrackView trackView;
        trackView = new TrackView(_mixer.createTrack(), defaultTrackHeightPixels, trackName);

        // select the new track
        _selectTrack(trackView);
        _trackViews ~= trackView;

        _redrawAll();

        return trackView;
    }

    void _createTrackMenu() {
        _trackMenu = new Menu();

        _trackMenu.append(new MenuItem(delegate void(MenuItem) { new RenameTrackDialog(); },
                                       "Rename Track..."));

        _trackMenu.attachToWidget(this, null);
    }

    void _createEditRegionMenu(ref Menu editRegionMenu,
                               ref MenuItem gainMenuItem,
                               ref MenuItem normalizeMenuItem,
                               ref MenuItem reverseMenuItem,
                               ref MenuItem fadeInMenuItem,
                               ref MenuItem fadeOutMenuItem,
                               ref MenuItem stretchSelectionMenuItem,
                               ref CheckMenuItem showOnsetsMenuItem,
                               ref MenuItem onsetDetectionMenuItem,
                               ref CheckMenuItem linkChannelsMenuItem) {
        gainMenuItem = new MenuItem(delegate void(MenuItem) { new GainDialog(); },
                                    "Gain...");
        editRegionMenu.append(gainMenuItem);

        normalizeMenuItem = new MenuItem(delegate void(MenuItem) { new NormalizeDialog(); },
                                         "Normalize...");
        editRegionMenu.append(normalizeMenuItem);

        reverseMenuItem = new MenuItem(delegate void(MenuItem) {
                if(_mode == Mode.editRegion && _editRegion !is null && _editRegion.subregionSelected) {
                    _editRegion.region.reverse(_editRegion.subregionStartFrame, _editRegion.subregionEndFrame);
                    if(_editRegion.showOnsets) {
                        _editRegion.computeOnsets();
                    }
                    _editRegion.appendEditState(_editRegion.currentEditState(true), "Reverse subregion");
                    _canvas.redraw();
                }
            }, "Reverse Selection...");
        editRegionMenu.append(reverseMenuItem);

        fadeInMenuItem = new MenuItem(delegate void(MenuItem) {
                if(_mode == Mode.editRegion && _editRegion !is null && _editRegion.subregionSelected) {
                    _editRegion.region.fadeIn(_editRegion.subregionStartFrame, _editRegion.subregionEndFrame);
                    if(_editRegion.showOnsets) {
                        _editRegion.computeOnsets();
                    }
                    _editRegion.appendEditState(_editRegion.currentEditState(true), "Fade in subregion");
                    _canvas.redraw();
                }
            }, "Fade In Selection...");
        editRegionMenu.append(fadeInMenuItem);

        fadeOutMenuItem = new MenuItem(delegate void(MenuItem) {
                if(_mode == Mode.editRegion && _editRegion !is null && _editRegion.subregionSelected) {
                    _editRegion.region.fadeOut(_editRegion.subregionStartFrame, _editRegion.subregionEndFrame);
                    if(_editRegion.showOnsets) {
                        _editRegion.computeOnsets();
                    }
                    _editRegion.appendEditState(_editRegion.currentEditState(true), "Fade out subregion");
                    _canvas.redraw();
                }
            }, "Fade Out Selection...");
        editRegionMenu.append(fadeOutMenuItem);

        stretchSelectionMenuItem = new MenuItem(delegate void(MenuItem) { new StretchSelectionDialog(); },
                                                "Stretch Selection...");
        editRegionMenu.append(stretchSelectionMenuItem);

        showOnsetsMenuItem = new CheckMenuItem("Show Onsets");
        showOnsetsMenuItem.addOnToggled(&onShowOnsets);
        editRegionMenu.append(showOnsetsMenuItem);

        onsetDetectionMenuItem = new MenuItem(delegate void(MenuItem) { new OnsetDetectionDialog(); },
                                               "Onset Detection...");
        editRegionMenu.append(onsetDetectionMenuItem);

        linkChannelsMenuItem = new CheckMenuItem("Link Channels");
        linkChannelsMenuItem.addOnToggled(&onLinkChannels);
        editRegionMenu.append(linkChannelsMenuItem);
    }

    void _updateEditRegionMenu(ref MenuItem gainMenuItem,
                               ref MenuItem normalizeMenuItem,
                               ref MenuItem reverseMenuItem,
                               ref MenuItem fadeInMenuItem,
                               ref MenuItem fadeOutMenuItem,
                               ref MenuItem stretchSelectionMenuItem,
                               ref CheckMenuItem showOnsetsMenuItem,
                               ref MenuItem onsetDetectionMenuItem,
                               ref CheckMenuItem linkChannelsMenuItem) {
        if(_editRegion !is null) {
            gainMenuItem.setSensitive(true);
            normalizeMenuItem.setSensitive(true);

            reverseMenuItem.setSensitive(_editRegion.subregionSelected);
            fadeInMenuItem.setSensitive(_editRegion.subregionSelected);
            fadeOutMenuItem.setSensitive(_editRegion.subregionSelected);
            stretchSelectionMenuItem.setSensitive(_editRegion.subregionSelected);

            showOnsetsMenuItem.setSensitive(true);
            showOnsetsMenuItem.setActive(_editRegion.showOnsets);

            onsetDetectionMenuItem.setSensitive(_editRegion.showOnsets);

            linkChannelsMenuItem.setSensitive(_editRegion.nChannels > 1 &&
                                              _editRegion.showOnsets);
            linkChannelsMenuItem.setActive(_editRegion.linkChannels);
        }
    }

    /// Calculate bin sizes for various zoom levels.
    /// Returns: A binning size corresponding to a cache bin size in `Region.cacheBinSizes`.
    nframes_t _zoomBinSize() {
        if(_samplesPerPixel >= 600) {
            return 100;
        }
        else if(_samplesPerPixel >= 300) {
            return 50;
        }
        else if(_samplesPerPixel >= 100) {
            return 20;
        }
        else {
            return 10;
        }
    }

    /// Zoom the canvas view in along the horizontal (time) axis
    void _zoomIn() {
        if(_samplesPerPixel > 600) {
            _samplesPerPixel -= 100;
        }
        else if(_samplesPerPixel > 300) {
            _samplesPerPixel -= 50;
        }
        else if(_samplesPerPixel > 100) {
            _samplesPerPixel -= 20;
        }
        else if(_samplesPerPixel > 10) {
            _samplesPerPixel -= 10;
        }
        _canvas.redraw();
        _hScroll.reconfigure();
    }

    /// Zoom the canvas view out along the horizontal (time) axis
    void _zoomOut() {
        if(_samplesPerPixel >= 600) {
            _samplesPerPixel += 100;
        }
        else if(_samplesPerPixel >= 300) {
            _samplesPerPixel += 50;
        }
        else if(_samplesPerPixel >= 100) {
            _samplesPerPixel += 20;
        }
        else {
            _samplesPerPixel += 10;
        }
        _canvas.redraw();
        _hScroll.reconfigure();
    }

    /// Zoom the canvas view in along the vertical (amplitude) axis
    void _zoomInVertical() {
        auto newVerticalScaleFactor = max(_verticalScaleFactor / _verticalZoomFactor, _verticalZoomFactorMin);
        bool validZoom = true;
        foreach(trackView; _trackViews) {
            if(!trackView.validZoom(newVerticalScaleFactor)) {
                validZoom = false;
                break;
            }
        }
        if(validZoom) {
            _verticalScaleFactor = newVerticalScaleFactor;
            _canvas.redraw();
            _trackStubs.redraw();
            _vScroll.reconfigure();
        }
    }

    /// Zoom the canvas view out along the vertical (amplitude) axis
    void _zoomOutVertical() {
        _verticalScaleFactor = min(_verticalScaleFactor * _verticalZoomFactor, _verticalZoomFactorMax);
        _canvas.redraw();
        _trackStubs.redraw();
        _vScroll.reconfigure();
    }

    /// Change the cursor according to the current action
    void _setCursor() {
        static Cursor cursorMove;
        static Cursor cursorMoveOnset;
        static Cursor cursorShrinkSubregionStart;
        static Cursor cursorShrinkSubregionEnd;

        void setCursorByType(Cursor cursor, CursorType cursorType) {
            if(cursor is null) {
                cursor = new Cursor(Display.getDefault(), cursorType);
            }
            getWindow().setCursor(cursor);
        }
        void setCursorDefault() {
            getWindow().setCursor(null);
        }

        switch(_action) {
            case Action.moveMarker:
            case Action.moveRegion:
                setCursorByType(cursorMove, CursorType.FLEUR);
                break;

            case Action.mouseOverRegionStart:
            case Action.mouseOverRegionEnd:
            case Action.shrinkRegionStart:
            case Action.shrinkRegionEnd:
            case Action.moveOnset:
                setCursorByType(cursorMoveOnset, CursorType.SB_H_DOUBLE_ARROW);
                break;

            case Action.mouseOverSubregionStart:
            case Action.shrinkSubregionStart:
                setCursorByType(cursorShrinkSubregionStart, CursorType.LEFT_SIDE);
                break;

            case Action.mouseOverSubregionEnd:
            case Action.shrinkSubregionEnd:
                setCursorByType(cursorShrinkSubregionEnd, CursorType.RIGHT_SIDE);
                break;

            default:
                setCursorDefault();
                break;
        }
    }

    /// Set the current action
    void _setAction(Action action) {
        _action = action;
        _setCursor();
    }

    /// Set the current mode, i.e., arrange mode or edit region mode
    void _setMode(Mode mode) {
        switch(mode) {
            case Mode.editRegion:
                // enable edit mode for the first selected region
                _editRegion = null;
                foreach(regionView; _selectedRegions) {
                    regionView.editMode = true;
                    _editRegion = regionView;
                    break;
                }
                if(_editRegion is null) {
                    return;
                }
                break;

            default:
                // if the last mode was editRegion, unset the edit mode flag for the edited region
                if(_mode == Mode.editRegion) {
                    _editRegion.editMode = false;
                    _editRegion = null;
                }
                break;
        }

        _mode = mode;
        _setAction(Action.none);
        _canvas.redraw();
        if(_menuBar !is null) {
            _menuBar.updateEditMenu();
            _menuBar.updateRegionMenu();
        }
    }

    /// Returns: The region that begins the earliest in the given `regionViews` list
    RegionView _getEarliestRegion(RegionView[] regionViews) {
        RegionView earliestRegion = null;
        nframes_t minOffset = nframes_t.max;
        foreach(regionView; regionViews) {
            regionView.previewOffset = regionView.offset;
            if(regionView.offset < minOffset) {
                minOffset = regionView.offset;
                earliestRegion = regionView;
            }
        }
        return earliestRegion;
    }

    /// Returns: The region that begins the earliest in the given `regionViewStates` list
    RegionView _getEarliestRegion(RegionViewState[] regionViewStates) {
        RegionView earliestRegion = null;
        nframes_t minOffset = nframes_t.max;
        foreach(regionViewState; regionViewStates) {
            auto regionView = regionViewState.regionView;
            regionView.previewOffset = regionView.offset;
            if(regionView.offset < minOffset) {
                minOffset = regionView.offset;
                earliestRegion = regionView;
            }
        }
        return earliestRegion;
    }

    /// Set a private data member to the earliest currently selected region
    void _computeEarliestSelectedRegion() {
        _earliestSelectedRegion = _getEarliestRegion(_selectedRegions);
    }

    /// Returns: A track view that the mouse is currently hovering over.
    ///          If no such track exists, this function returns `null`.
    TrackView _mouseOverTrack(pixels_t mouseY) {
        foreach(trackView; _trackViews) {
            if(mouseY >= trackView.stubBox.y0 && mouseY < trackView.stubBox.y1) {
                return trackView;
            }
        }

        return null;
    }

    /// Returns: The index of the track in the `_trackViews` data member of the track
    ///          the mouse is currently hovering over.
    ///          If no such track exists, this function returns `null`.
    Nullable!size_t _mouseOverTrackIndex(pixels_t mouseY) {
        Nullable!size_t result;
        foreach(trackIndex, trackView; _trackViews) {
            if(mouseY >= trackView.stubBox.y0 && mouseY < trackView.stubBox.y1) {
                result = trackIndex;
                break;
            }
        }
        return result;
    }

    /// Returns: The index of the track in the `_trackView` data member that matches
    ///          the identity of the `trackView` argument.
    ///          If no such track is found, this function returns `null`.
    Nullable!size_t _trackIndex(TrackView trackView) {
        Nullable!size_t result;
        foreach(trackIndex, track; _trackViews) {
            if(track is trackView) {
                result = trackIndex;
                break;
            }
        }
        return result;
    }

    /// Returns: The minimum index of the `previewTrackIndex` member of
    ///          any region in the `regionViews` argument.
    ///          If no region is found, returns `null`.
    Nullable!size_t _minPreviewTrackIndex(RegionView[] regionViews) {
        Nullable!size_t result;
        foreach(regionView; regionViews) {
            if(result.isNull() ||
               result > regionView.previewTrackIndex) {
                result = regionView.previewTrackIndex;
            }
        }
        return result;
    }

    /// Returns: The maximum index of the `previewTrackIndex` member of
    ///          any region in the `regionViews` argument.
    ///          If no region is found, returns `null`.
    Nullable!size_t _maxPreviewTrackIndex(RegionView[] regionViews) {
        Nullable!size_t result;
        foreach(regionView; regionViews) {
            if((result.isNull() ||
                result < regionView.previewTrackIndex)) {
                result = regionView.previewTrackIndex;
            }
        }
        return result;
    }

    /// Recomputes the registered regions for all tracks in the current session.
    /// This function should be called after one or more regions have been
    /// moved from one track to another.
    void _recomputeTrackViewRegions() {
        foreach(trackView; _trackViews) {
            auto regionViewsApp = appender!(RegionView[]);
            foreach(regionView; _regionViews) {
                if(regionView.trackView is trackView) {
                    regionViewsApp.put(regionView);
                }
            }
            trackView.regionViews = regionViewsApp.data;
        }
    }

    void _selectTrack(TrackView trackView) {
        _selectedTrack = trackView;
        _arrangeChannelStrip.update();
        _arrangeChannelStrip.redraw();
        _menuBar.updateTrackMenu();
    }

    /// Remove the currently selected regions from the current session.
    /// This will unregister each region from its parent track.
    /// This function should be called when the user deletes or cuts all currently selected regions.
    void _removeSelectedRegions() {
        // remove the selected regions from their respective tracks
        foreach(trackView; _trackViews) {
            auto regionViewsApp = appender!(RegionView[]);
            foreach(regionView; trackView.regionViews) {
                if(!regionView.selected) {
                    regionViewsApp.put(regionView);
                }
            }
            trackView.regionViews = regionViewsApp.data;
        }

        // remove the selected regions from the global list of regions
        auto regionViewsApp = appender!(RegionView[]);
        foreach(regionView; _regionViews) {
            if(!regionView.selected) {
                regionViewsApp.put(regionView);
            }
        }
        _regionViews = regionViewsApp.data;

        appendArrangeState(currentArrangeState!(ArrangeStateType.tracksEdit), true);
    }

    /// Redraw all widgets in the arrange view, and update the visible channel strips
    void _redrawAll() {
        _hScroll.reconfigure();
        _vScroll.reconfigure();

        _canvas.redraw();
        _trackStubs.redraw();
        _arrangeChannelStrip.update();
        _arrangeChannelStrip.redraw();
    }

    /// Reset the arrange view to a clean, empty state.
    /// This function should be called when the user closes the current session and begins a new session.
    void _resetArrangeView() {
        _arrangeStateHistory = new StateHistory!ArrangeState(ArrangeState());
        _savedState = true;

        _mixer.reset();
        _trackViews = [];
        _regionViews = [];

        _selectedTrack = null;
        _selectedRegionsApp.clear();
        _earliestSelectedRegion = null;
        _editRegion = null;

        _markers = _markers.init;
        _moveMarker = null;

        _viewOffset = 0;

        _setMode(Mode.arrange);
        _setAction(Action.none);

        _redrawAll();
    }

    StateHistory!ArrangeState _arrangeStateHistory;
    bool _savedState = true;

    Window _parentWindow;
    AccelGroup _accelGroup;
    ArrangeMenuBar _menuBar;

    SequenceBrowser _sequenceBrowser;

    Mixer _mixer;
    MasterBusView _masterBusView;
    TrackView[] _trackViews;
    RegionView[] _regionViews;
    Appender!(AudioSequence[]) _audioSequencesApp;
    @property AudioSequence[] _audioSequences() { return _audioSequencesApp.data; }

    TrackView _selectedTrack;
    Appender!(RegionView[]) _selectedRegionsApp;
    @property RegionView[] _selectedRegions() { return _selectedRegionsApp.data; }
    RegionView _earliestSelectedRegion;

    Appender!(RegionViewState[]) _copiedRegionStatesApp;
    @property RegionViewState[] _copiedRegionStates() { return _copiedRegionStatesApp.data; }
    RegionView _mouseOverRegionStart;
    RegionView _mouseOverRegionEnd;
    Nullable!size_t _moveTrackIndex;
    Nullable!size_t _minMoveTrackIndex;
    Nullable!size_t _maxMoveTrackIndex;

    RegionView _editRegion;
    AudioSequence.AudioPieceTable _copyBuffer;

    Menu _markerMenu;
    Marker[uint] _markers;
    Marker _selectedMarker;
    Marker _moveMarker;

    bool _mixerPlaying;

    PgLayout _trackLabelLayout;
    PgLayout _regionHeaderLabelLayout;
    PgLayout _markerLabelLayout;
    PgLayout _timeStripMarkerLayout;
    float _timeStripScaleFactor = 1;

    nframes_t _samplesPerPixel;
    nframes_t _viewOffset;
    bool _viewFollowTransport;

    ArrangeChannelStrip _arrangeChannelStrip;
    Timeout _arrangeChannelStripRefresh;

    TrackStubs _trackStubs;
    pixels_t _trackStubWidth;
    TrackButton _trackButtonPressed;

    Canvas _canvas;
    ArrangeHScroll _hScroll;
    ArrangeVScroll _vScroll;
    Timeout _canvasRefresh;

    Menu _arrangeMenu;
    MenuItem _editRegionMenuItem;
    FileChooserDialog _importFileChooser;
    FileChooserDialog _exportFileChooser;

    Menu _trackMenu;
    Menu _editRegionMenu;
    MenuItem _gainMenuItem;
    MenuItem _normalizeMenuItem;
    MenuItem _reverseMenuItem;
    MenuItem _fadeInMenuItem;
    MenuItem _fadeOutMenuItem;
    MenuItem _stretchSelectionMenuItem;
    CheckMenuItem _showOnsetsMenuItem;
    MenuItem _onsetDetectionMenuItem;
    CheckMenuItem _linkChannelsMenuItem;

    pixels_t _viewWidthPixels;
    pixels_t _viewHeightPixels;
    pixels_t _transportPixelsOffset;
    pixels_t _verticalPixelsOffset;
    float _verticalScaleFactor = 1;

    Mode _mode;
    CopyMode _copyMode;
    Action _action;
    bool _centeredView;
    MonoTime _doubleClickTime;

    size_t _moveOnsetIndex;
    channels_t _moveOnsetChannel;
    nframes_t _moveOnsetFrameSrc; /// Locally indexed for the region being edited
    nframes_t _moveOnsetFrameDest; /// Locally indexed for the region being edited
}
