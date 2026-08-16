import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Constants
private enum AppConstants {
    static let githubURL = URL(string: "https://github.com/ganiyevuz/hazel-plus")!
    static let allowedMovieTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]

    /// System Settings deep links. Both fall back to opening System Settings
    /// unscoped, so a scheme change never leaves a button that does nothing.
    static let wallpaperPane = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
    static let screenSaverPane = "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"
}

// MARK: - View
struct ManagementView: View {
    @ObservedObject var store: WallpaperStore
    @ObservedObject var controller: WallpaperController

    @State private var showingFileImporter = false
    @State private var showingDuplicateAlert = false
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""
    @State private var duplicateVideoName = ""
    @State private var screenSaverSelection: ScreenSaverSelection = .unknown
    @State private var showingRemoveConfirmation = false
    @State private var showingRemoveFailure = false

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            library
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 460)
        .background(.regularMaterial)
        .onAppear(perform: refreshScreenSaverSelection)
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: AppConstants.allowedMovieTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .alert("Wallpaper Already Exists", isPresented: $showingDuplicateAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The wallpaper \"\(duplicateVideoName)\" is already in your library.")
        }
        .alert("Error", isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .confirmationDialog(
            "Remove Hazel wallpapers from System Settings?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive, action: removeFromSystemSettings)
            Button("Cancel", role: .cancel) { }
        } message: {
            // Says the entries come back, because syncWallpaperStore() runs on
            // launch, import and delete — without this the action reads as broken.
            Text("Your videos stay in Hazel. This only removes the \"Hazel\" section from System Settings → Wallpaper → Screen Saver.\n\nHazel re-adds it the next time it launches or you change your library, so use this before uninstalling.")
        }
        .alert("Couldn't remove Hazel wallpapers", isPresented: $showingRemoveFailure) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("System Settings may still show the \"Hazel\" section. Try again, or remove it after restarting your Mac.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Hazel")
                .font(.headline)

            Spacer()

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    toolbarButton(
                        systemImage: "photo",
                        help: "Open Wallpaper settings"
                    ) { open(AppConstants.wallpaperPane) }

                    // The dot is the whole former "Screen Saver" section, compressed:
                    // it lights up only when a Hazel video is the active screen saver.
                    toolbarButton(
                        systemImage: "moon.stars",
                        help: screenSaverHelp,
                        showsIndicator: isHazelScreenSaverActive
                    ) { open(AppConstants.screenSaverPane) }

                    Link(destination: AppConstants.githubURL) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .frame(width: 15, height: 15)
                    }
                    .buttonStyle(.glass)
                    .help("View Hazel on GitHub")

                    // Destructive actions live behind a menu, never as a bare
                    // toolbar icon that can be hit by accident.
                    Menu {
                        Button("Remove Hazel Wallpapers from System Settings…",
                               systemImage: "trash",
                               role: .destructive) {
                            showingRemoveConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 15, height: 15)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .menuIndicator(.hidden)
                    .help("More options")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func toolbarButton(
        systemImage: String,
        help: String,
        showsIndicator: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 15, height: 15)
                .overlay(alignment: .topTrailing) {
                    if showsIndicator {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                            .offset(x: 5, y: -4)
                    }
                }
        }
        .buttonStyle(.glass)
        .help(help)
    }

    private var isHazelScreenSaverActive: Bool {
        if case .hazelWallpaper = screenSaverSelection { return true }
        return false
    }

    /// Doubles as the answer to "what about the lock screen?" — macOS has no
    /// separate lock screen wallpaper, so it follows whatever this is set to.
    private var screenSaverHelp: String {
        let state: String
        switch screenSaverSelection {
        case .hazelWallpaper(let id):
            let title = store.wallpapers.first(where: { $0.id == id })?.title
            state = "Currently: \(title ?? "a Hazel wallpaper")"
        case .otherApp:
            state = "Currently: another app's wallpaper"
        case .notAnAerial:
            state = "No Hazel wallpaper set"
        case .unknown:
            state = "Current setting unavailable"
        }
        return "Open Screen Saver settings — \(state). Your lock screen follows this."
    }

    // MARK: - Library

    private var library: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                AddCard { showingFileImporter = true }

                ForEach(store.wallpapers) { item in
                    WallpaperCard(
                        item: item,
                        isSelected: store.activeWallpaperID == item.id,
                        onTap: {
                            store.setActiveWallpaper(item)
                            controller.setWallpaper(item)
                        },
                        onRemove: {
                            if store.activeWallpaperID == item.id {
                                controller.clearWallpaper()
                            }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.removeWallpaper(item)
                            }
                        },
                        onToggleLoop: {
                            store.toggleLoop(for: item)
                            if store.activeWallpaperID == item.id,
                               let updatedItem = store.wallpapers.first(where: { $0.id == item.id }) {
                                controller.setWallpaper(updatedItem)
                            }
                        },
                        onToggleMute: {
                            store.toggleMute(for: item)
                            if store.activeWallpaperID == item.id,
                               let updatedItem = store.wallpapers.first(where: { $0.id == item.id }) {
                                controller.setWallpaper(updatedItem)
                            }
                        }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func removeFromSystemSettings() {
        WallpaperStoreRegistrar.shared.removeAll { succeeded in
            guard !succeeded else {
                // The tile is gone, so the screen-saver indicator is now stale.
                refreshScreenSaverSelection()
                return
            }
            showingRemoveFailure = true
        }
    }

    private func refreshScreenSaverSelection() {
        screenSaverSelection = WallpaperStoreRegistrar.shared
            .currentScreenSaverSelection(library: store.wallpapers)
    }

    /// Opens a System Settings pane, falling back to System Settings itself if
    /// the deep-link scheme is not honoured on this macOS version.
    private func open(_ paneURLString: String) {
        if let paneURL = URL(string: paneURLString), NSWorkspace.shared.open(paneURL) {
            return
        }
        if let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.openApplication(at: appURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var lastAddedItem: WallpaperItem?
            var hasDuplicate = false

            for url in urls {
                let fileName = url.deletingPathExtension().lastPathComponent
                if store.wallpapers.contains(where: { $0.title == fileName }) {
                    duplicateVideoName = fileName
                    hasDuplicate = true
                    continue
                }

                if let item = store.addWallpaper(url: url) {
                    lastAddedItem = item
                }
            }

            if hasDuplicate {
                showingDuplicateAlert = true
            }

            if let itemToActivate = lastAddedItem {
                store.setActiveWallpaper(itemToActivate)
                controller.setWallpaper(itemToActivate)
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
            showingErrorAlert = true
        }
    }
}

// MARK: - Window Controller
class ManagementWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    func showPanel(store: WallpaperStore, controller: WallpaperController) {
        if let existingPanel = panel {
            existingPanel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(rootView: ManagementView(store: store, controller: controller))

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.title = "Hazel"
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.isMovableByWindowBackground = true
        newPanel.contentView = hostingView
        newPanel.isReleasedWhenClosed = false
        newPanel.level = .floating
        newPanel.center()
        newPanel.delegate = self

        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closePanel() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
