import SwiftUI

// A feature plugged into HuaSideload. The core does the Bluetooth connection, pairing, installing/removing watch apps,
// uploading music to the watch and messaging with watch apps. Everything on top of that is a WatchFeature.
//
// To keep your own features out of this repo, build them in a separate project that compiles this core plus your files,
// and define an NSObject class named @objc(HuaSideloadPrivateFeatures) implementing WatchFeatureProvider.
// WatchFeatures.load() finds it at runtime (README > "Keeping your own features in a separate project").
@MainActor
protocol WatchFeature: AnyObject {
    // Packages of the watch apps it talks to (incoming messages are routed by these)
    var watchPackages: [String] { get }
    // Whether this feature drives the watch's built-in music screen (service 0x25); at most one feature
    var ownsMusicScreen: Bool { get }

    func attach(to host: WatchFeatureHost)
    func watchPaired()
    func connectionLost()
    // A JSON message from a watch app; return true if handled
    func handle(_ message: [String: Any], from package: String) async -> Bool
    func musicScreenOpened()
    func musicButton(_ button: MusicControl.Button?, volume: Int?)
    // Sections shown on the main screen below Status
    func sections() -> AnyView
    // Filming mode (a clean main screen for screen recordings): the toolbar button only shows if a feature offers it
    var offersFilmMode: Bool { get }
    // Bundled watch apps (by name, i.e. the .bin file name) hidden from the main screen in filming mode
    var filmModeHiddenApps: [String] { get }
}

extension WatchFeature {
    var ownsMusicScreen: Bool { false }
    func watchPaired() {}
    func connectionLost() {}
    func musicScreenOpened() {}
    func musicButton(_ button: MusicControl.Button?, volume: Int?) {}
    func sections() -> AnyView { AnyView(EmptyView()) }
    var offersFilmMode: Bool { false }
    var filmModeHiddenApps: [String] { [] }
}

// What features can use from the core
@MainActor
protocol WatchFeatureHost: AnyObject {
    var isPaired: Bool { get }
    // Bridge for messaging a watch app (the package must belong to a .bin bundled in the app)
    func bridge(for package: String) -> WatchAppBridge?
    // The two lines, play/pause icon and volume (percent) on the watch's built-in music screen
    func showOnMusicScreen(top: String, main: String, playing: Bool, volumePercent: Int)
    // A vibrating notification on the watch
    func notify(title: String, text: String)
    // Phone audio through the watch speaker (rings the watch; see WatchSpeaker)
    var speaker: WatchSpeaker { get }
    // Events from the watch wake the app in the background; this asks iOS for time until the work is done
    func inBackground(_ name: String, _ work: @escaping () async -> Void)
    func log(_ kind: LogKind, _ text: String)
}

@MainActor
protocol WatchFeatureProvider {
    func makeFeatures() -> [WatchFeature]
}

@MainActor
enum WatchFeatures {
    static func load() -> [WatchFeature] {
        var features: [WatchFeature] = [HelloFeature(), HermesFeature()]
        if let type = NSClassFromString("HuaSideloadPrivateFeatures") as? NSObject.Type,
           let provider = type.init() as? WatchFeatureProvider {
            features += provider.makeFeatures()
        }
        return features
    }
}
