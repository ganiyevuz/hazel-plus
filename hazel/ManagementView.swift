import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Constants
private enum AppConstants {
    static let githubURL = URL(string: "https://github.com/harryfrzz/hazel")!
    static let allowedMovieTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            homeScreenSection
            screenSaverSection
            lockScreenSection
            Spacer(minLength: 0)
        }
        .padding(.vertical, 20)
        .frame(width: 600, height: 520)
        .onAppear { refreshScreenSaverSelection() }
        .background(Color.black)
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
    }
    
    // MARK: - Subviews
    
    private var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            Image("Logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 120)
                .padding(.leading, 20)
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 12) {
                Text("Hazel")
                    .font(.custom("GeistPixel-Square", size: 28))
                    .foregroundColor(.white)
                
                Text("v1.1")
                    .font(.custom("GeistPixel-Square", size: 15))
                    .foregroundColor(.gray)
                
                HStack(spacing: 12) {
                    Link(destination: AppConstants.githubURL) {
                        Image("GitHubLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    }
                    .padding(8)
                    .background(Color.white)
                    .cornerRadius(8)
                    .help("Visit the GitHub repository")
                }
            }
            .padding(.trailing, 20)
        }
        .padding(.top, 20)
    }
    
    private var githubImage: Image {
        if let url = Bundle.main.url(forResource: "GitHub_Invertocat_Black", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "link")
    }
    
    private var wallpaperScrollView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 16) {
                AddCard {
                    showingFileImporter = true
                }
                .fileImporter(
                    isPresented: $showingFileImporter,
                    allowedContentTypes: AppConstants.allowedMovieTypes,
                    allowsMultipleSelection: true,
                    onCompletion: handleFileImport
                )
                
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
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.custom("GeistPixel-Square", size: 13))
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    private var homeScreenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Home Screen")
            wallpaperScrollView
        }
    }

    private var screenSaverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Screen Saver")
            HStack(spacing: 12) {
                screenSaverStatusView
                Spacer()
                Button("Open System Settings…") {
                    openScreenSaverSettings()
                }
                .font(.custom("GeistPixel-Square", size: 12))
            }
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var screenSaverStatusView: some View {
        switch screenSaverSelection {
        case .hazelWallpaper(let id):
            if let item = store.wallpapers.first(where: { $0.id == id }) {
                HStack(spacing: 10) {
                    if let image = store.loadThumbnailImage(for: item) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 64, height: 36)
                            .clipped()
                            .cornerRadius(4)
                    }
                    Text(item.title)
                        .font(.custom("GeistPixel-Square", size: 12))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            } else {
                Text("Set to a Hazel wallpaper")
                    .font(.custom("GeistPixel-Square", size: 12))
                    .foregroundColor(.white)
            }
        case .otherApp:
            Text("Set to another app's wallpaper")
                .font(.custom("GeistPixel-Square", size: 12))
                .foregroundColor(.gray)
        case .notAnAerial:
            Text("Not set to a Hazel wallpaper")
                .font(.custom("GeistPixel-Square", size: 12))
                .foregroundColor(.gray)
        case .unknown:
            Text("Couldn't read the current screen saver")
                .font(.custom("GeistPixel-Square", size: 12))
                .foregroundColor(.gray)
        }
    }

    private var lockScreenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Lock Screen")
            Text("Follows your Screen Saver — macOS has no separate lock screen wallpaper.")
                .font(.custom("GeistPixel-Square", size: 12))
                .foregroundColor(.gray)
                .padding(.horizontal, 20)
        }
    }

    /// Reading a small plist is fast enough to do inline; keeping it synchronous
    /// avoids a state race between the read finishing and the view redrawing.
    private func refreshScreenSaverSelection() {
        screenSaverSelection = WallpaperStoreRegistrar.shared
            .currentScreenSaverSelection(library: store.wallpapers)
    }

    /// Opens System Settings at the Screen Saver pane. If the deep link is not
    /// honoured on this macOS version, fall back to opening System Settings
    /// unscoped — never leave the user with a button that does nothing.
    private func openScreenSaverSettings() {
        if let paneURL = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension"),
           NSWorkspace.shared.open(paneURL) {
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
        
        // Modern macOS Window Styling
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        newPanel.title = "hazel"
        newPanel.titleVisibility = .hidden // Hides the text title for a cleaner look
        newPanel.titlebarAppearsTransparent = true // Merges the titlebar with the content
        newPanel.isMovableByWindowBackground = true // User can drag the window from anywhere
        newPanel.contentView = hostingView
        newPanel.isReleasedWhenClosed = false
        newPanel.level = .floating // Keeps it above other windows
        newPanel.center()
        newPanel.delegate = self
        
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closePanel() {
        panel?.close()
    }
    
    // Listen for the user clicking the red 'X' button
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
