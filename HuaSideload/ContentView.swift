import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var link = WatchLink()
    // Changing the language re-renders the screen; L() reads the same setting
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.current.rawValue
    @State private var copied = false
    @State private var message = ""
    @FocusState private var messageFocused: Bool
    @State private var pickingMusic = false
    @State private var pickingWatchFace = false
    // Filming mode: only what a video needs (no log controls, no feature sections, no identity buttons).
    // Offered only when a feature asks for it (WatchFeature.offersFilmMode); the plain app never shows it.
    @AppStorage("filmModeV2") private var filmModeOn = false
    private var filmModeOffered: Bool { link.features.contains { $0.offersFilmMode } }
    private var filmMode: Bool { filmModeOffered && filmModeOn }

    enum Tab: Hashable { case watch, install, features, log }
    @State private var tab: Tab = .watch

    var body: some View {
        TabView(selection: $tab) {
            page(AppInfo.displayName) {
                statusSection
                if link.isPaired && !filmMode,
                   let feature = link.features.compactMap({ $0 as? HermesFeature }).first {
                    VoiceFavoritesSection(feature: feature)
                }
                if link.connectedName == nil && !link.isConnecting {
                    devicesSection
                } else {
                    watchSection
                    if link.isPaired { notificationSection }
                    if link.hasSavedPairing && !filmMode {
                        Section {
                            Button(L("Forget pairing", "Eşleşmeyi unut"), role: .destructive) { link.forgetPairing() }
                        } footer: {
                            Text(L("Use this if the watch was reset or pairing broke. The next pairing starts from the PIN step.",
                                   "Saat sıfırlandıysa ya da eşleşme bozulduysa kullan. Sonraki eşleşme PIN adımından başlar."))
                        }
                    }
                }
            }
            .tabItem { Label(L("Watch", "Saat"), systemImage: "watch.analog") }
            .tag(Tab.watch)

            page(L("Install", "Yükle")) {
                if link.isPaired {
                    watchAppsSection
                    watchFaceSection
                    if !filmMode { musicSection }
                } else {
                    pairFirstSection
                }
            }
            .tabItem { Label(L("Install", "Yükle"), systemImage: "square.and.arrow.down") }
            .tag(Tab.install)

            page(L("Features", "Özellikler")) {
                if link.isPaired {
                    WatchSpeakerSection(speaker: link.speaker)
                    // Feature sections (navigation, remote control etc.); never in filming mode
                    if !filmMode {
                        ForEach(link.features.indices, id: \.self) { index in
                            link.features[index].sections()
                        }
                    }
                } else {
                    pairFirstSection
                }
            }
            .tabItem { Label(L("Features", "Özellikler"), systemImage: "sparkles") }
            .tag(Tab.features)

            page(L("Log", "Log")) {
                logSection
            }
            .tabItem { Label(L("Log", "Log"), systemImage: "list.bullet.rectangle") }
            .tag(Tab.log)
        }
        // While filming, identities (UDID, serial number, MAC) always stay masked, in the log too
        .onAppear { if filmMode { link.revealIdentity = false } }
        .onChange(of: language) { _, _ in
            link.features.compactMap { $0 as? HermesFeature }.first?.sendFavorites()
        }
        .onChange(of: filmMode) { _, on in if on { link.revealIdentity = false } }
    }

    // One tab: a list with the title and the shared toolbar (filming mode, language)
    private func page<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            List { content() }
                // Feature sections don't know about the language: rebuild the list when it changes
                .id(language)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(title)
                .toolbar {
                    if filmModeOffered {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { filmModeOn.toggle() } label: {
                                Label(L("Filming", "Çekim"), systemImage: filmMode ? "video.fill" : "video")
                                    .labelStyle(.titleAndIcon)
                            }
                            .tint(filmMode ? .red : nil)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker(L("Language", "Dil"), selection: $language) {
                                ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                        } label: {
                            Image(systemName: "globe")
                        }
                        .accessibilityLabel(L("Language", "Dil"))
                    }
                }
        }
    }

    private var pairFirstSection: some View {
        Section {
            Button(L("Pair with the watch first", "Önce saatle eşleş")) { tab = .watch }
                .fontWeight(.semibold)
        } footer: {
            Text(L("This needs an encrypted connection to the watch. Connect and pair on the Watch tab.",
                   "Bunun için saatle şifreli bağlantı gerekiyor. Saat sekmesinden bağlan ve eşleş."))
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            if !filmMode {
                LabeledContent(L("Bluetooth", "Bluetooth"), value: link.bluetoothState)
            }
            LabeledContent(L("Watch", "Saat"), value: link.connectedName ?? (link.isConnecting ? L("Connecting…", "Bağlanıyor…") : L("Not connected", "Bağlı değil")))
            LabeledContent(L("Pairing", "Eşleşme"), value: link.isPaired ? L("Encrypted connection", "Şifreli bağlantı kuruldu")
                           : (link.huaweiChannelReady ? L("Channel ready, not paired", "Kanal hazır, eşleşilmedi") : L("None", "Yok")))
            if let battery = link.battery {
                LabeledContent(L("Battery", "Pil"), value: "\(battery)%")
            }
            if !filmMode {
                ForEach(link.watchInfo, id: \.self) { Text(link.display($0)).font(.callout) }
            }
            // In filming mode only once paired (an identity left over from the last session must not show before pairing)
            if let udid = link.watchUDID, link.isPaired || !filmMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("UDID (for the debug profile)", "UDID (geliştirici profili için)")).font(.caption).foregroundStyle(.secondary)
                    Text(link.revealIdentity ? udid : String(repeating: "•", count: 16))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if !filmMode {
                    Button(L("Copy UDID", "UDID'yi kopyala")) { UIPasteboard.general.string = udid }
                }
            }
        } header: {
            HStack {
                Text(L("Status", "Durum"))
                Spacer()
                if !filmMode {
                    Button(link.revealIdentity ? L("Hide identity", "Kimliği gizle") : L("Show identity", "Kimliği göster")) {
                        link.revealIdentity.toggle()
                    }
                    .font(.caption)
                }
            }
            .textCase(nil)
        } footer: {
            if !filmMode {
                Text(L("UDID, serial number and MAC addresses are hidden on screen and in the log (e.g. while filming). \"Show identity\" reveals them.",
                       "UDID, seri no ve MAC adresleri ekranda ve kayıtlarda gizli tutulur (video çekerken görünmesin diye). \"Kimliği göster\" ile açılır."))
            }
        }
    }

    private var devicesSection: some View {
        Section {
            Button(link.isScanning ? L("Scanning…", "Aranıyor…") : L("Find watch", "Saati ara")) { link.startScan() }
                .disabled(link.isScanning)
            ForEach(link.devices) { device in
                Button { link.connect(device) } label: { DeviceRow(device: device) }
            }
        } header: {
            Text(L("Devices", "Cihazlar"))
        } footer: {
            Text(L("If the watch is connected to Huawei Health it shows up as \"connected to phone\". Tap it.",
                   "Saat Huawei Health'e bağlıysa \"telefona bağlı\" olarak görünür. Ona dokun."))
        }
    }

    private var watchSection: some View {
        Section {
            if let busy = link.busy {
                HStack { ProgressView(); Text(busy).foregroundStyle(.secondary) }
            }
            if !link.isPaired {
                Button(link.hasSavedPairing ? L("Pair (saved key)", "Eşleş (kayıtlı anahtarla)") : L("Pair", "Eşleş")) { link.pair() }
                    .disabled(!link.huaweiChannelReady || link.busy != nil)
                    .fontWeight(.semibold)
            } else if !filmMode {
                Button(L("Refresh battery and watch info", "Pil ve saat bilgisini yenile")) { link.refresh() }
                    .disabled(link.busy != nil)
            }
            Button(L("Disconnect", "Bağlantıyı kes"), role: .destructive) { link.disconnect() }
        } header: {
            Text(L("Watch", "Saat"))
        } footer: {
            if !link.isPaired && !link.hasSavedPairing && !filmMode {
                Text(L("Close Huawei Health before pairing (swipe it up in the app switcher). The watch may ask for confirmation the first time.",
                       "Eşleşmeden önce Huawei Health'i kapat (uygulama değiştiriciden yukarı kaydır). İlk eşleşmede saatin ekranında onay çıkabilir."))
            }
        }
    }

    private var visibleApps: [BundledWatchApp] {
        guard filmMode else { return WatchAppCatalog.all }
        let hidden = Set(link.features.flatMap(\.filmModeHiddenApps))
        return WatchAppCatalog.all.filter { !hidden.contains($0.name) }
    }

    private var watchAppsSection: some View {
        Section {
            if let progress = link.watchAppProgress {
                ProgressView(value: progress) { Text(L("Uploading… \(Int(progress * 100))%", "Yükleniyor… %\(Int(progress * 100))")) }
            }
            if filmMode, let status = link.appInstallStatus, link.watchAppProgress == nil {
                Label(status.text, systemImage: status.ok == true ? "checkmark.circle.fill" : status.ok == false ? "xmark.octagon.fill" : "hourglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(status.ok == true ? .green : status.ok == false ? .red : .secondary)
            }
            ForEach(visibleApps) { app in
                Button { link.installWatchApp(app) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Install \(app.name) on the watch", "\(app.name) uygulamasını saate kur")).fontWeight(.semibold)
                        Text("\(app.version) · \(app.data.count / 1024) KB").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(link.busy != nil)
            }
            ForEach(link.installedApps) { app in
                HStack {
                    VStack(alignment: .leading) {
                        Text(app.name.isEmpty ? app.package : app.name)
                        Text("\(app.package) · \(app.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Delete", "Sil"), role: .destructive) { link.deleteWatchApp(app) }
                        .buttonStyle(.borderless)
                        .disabled(link.busy != nil)
                }
            }
            Button(L("Show apps on the watch", "Saatteki uygulamaları göster")) { link.loadInstalledApps() }
                .disabled(link.busy != nil)
        } header: {
            Text(L("Watch apps", "Saat uygulamaları"))
        } footer: {
            if WatchAppCatalog.all.isEmpty && !filmMode {
                Text(L("No watch app is bundled yet. Apps built with tools/build-watch-app.sh land in WatchApps/ and show up here with an \"Install\" button (see README).",
                       "Uygulamanın içinde saat uygulaması yok. tools/build-watch-app.sh ile derlenen .bin dosyaları WatchApps/ klasörüne düşer ve burada \"Kur\" düğmesi olarak çıkar (README)."))
            }
        }
    }

    private var watchFaceSection: some View {
        Section {
            if let status = link.watchFaceStatus {
                if let progress = link.watchAppProgress {
                    ProgressView(value: progress) { Text(status + " " + L("\(Int(progress * 100))%", "%\(Int(progress * 100))")).font(.callout) }
                } else {
                    Text(status).font(.callout)
                }
            }
            ForEach(WatchFaceCatalog.all, id: \.self) { url in
                let name = url.deletingPathExtension().lastPathComponent
                Button(L("Install the \(name) watch face", "\(name) kadranını saate kur")) { link.installWatchFace(url, title: name) }
                    .disabled(link.busy != nil)
                    .fontWeight(.semibold)
            }
            if !filmMode {
                Button(L("Install a watch face (.hwt)", "Saate kadran yükle (.hwt)")) { pickingWatchFace = true }
                    .disabled(link.busy != nil)
                    .fontWeight(WatchFaceCatalog.all.isEmpty ? .semibold : .regular)
            }
        } header: {
            Text(L("Watch faces", "Kadranlar"))
        } footer: {
            if !filmMode {
                Text(L("Watch faces made with Huawei Theme Studio (.hwt). After the upload, touch and hold the watch face on the watch and pick the new one.",
                       "Huawei Theme Studio ile yapılan kadranlar (.hwt). Yükleme bitince saatte kadrana basılı tut ve yenisini seç."))
            }
        }
        .fileImporter(isPresented: $pickingWatchFace, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { link.installWatchFace(url) }
        }
    }

    private var musicSection: some View {
        Section {
            if let status = link.musicUploadStatus {
                Text(status).font(.callout)
            }
            Button(L("Upload music to the watch", "Saate müzik yükle")) { pickingMusic = true }
                .disabled(link.busy != nil)
                .fontWeight(.semibold)
            if let storage = link.musicStorage {
                LabeledContent(L("On the watch", "Saatte"),
                               value: L("\(storage.songs)/\(storage.maxSongs) songs · \(storage.freeMB) MB free",
                                        "\(storage.songs)/\(storage.maxSongs) şarkı · \(storage.freeMB) MB boş"))
            }
            Button(L("Show the watch's music storage", "Saatin müzik hafızasını göster")) { link.loadMusicStorage() }
                .disabled(link.busy != nil)
        } header: {
            Text(L("Watch music player", "Saatin müzik çaları"))
        } footer: {
            Text(L("MP3, M4A, AAC, FLAC, WAV or OPUS files go to the watch's storage and play from the watch's own Music app without the phone. DRM-protected songs (Spotify, Apple Music) cannot be uploaded. Large files take a few minutes.",
                   "MP3, M4A, AAC, FLAC, WAV ya da OPUS dosyaları saatin hafızasına gider; saatin kendi Müzik uygulamasından telefonsuz çalınır. DRM'li (Spotify, Apple Music) şarkılar yüklenemez. Büyük dosyalar birkaç dakika sürer."))
        }
        .fileImporter(isPresented: $pickingMusic, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { link.uploadMusic(urls) }
        }
    }

    private var notificationSection: some View {
        Section(L("Send a notification to the watch", "Saate bildirim gönder")) {
            TextField(L("Message", "Mesaj"), text: $message, axis: .vertical)
                .lineLimit(1...4)
                .focused($messageFocused)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button(L("Done", "Bitti")) { messageFocused = false }
                    }
                }
            Button(L("Send", "Gönder")) {
                messageFocused = false
                link.sendMessage(message)
            }
                .disabled(link.busy != nil || message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var logSection: some View {
        Section {
            ForEach(link.log.reversed()) { LogRow(entry: $0, text: link.display($0.text)) }
        } header: {
            HStack {
                Text(L("Log (newest first)", "Log (en yeni üstte)"))
                Spacer()
                Button(L("Clear", "Temizle"), systemImage: "trash") { link.clearLog() }
                    .labelStyle(.iconOnly)
                    .disabled(link.log.isEmpty)
                if !filmMode {
                Button(copied ? L("Copied", "Kopyalandı") : L("Copy", "Kopyala")) {
                    UIPasteboard.general.string = link.logText
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                ShareLink(item: link.logText) { Image(systemName: "square.and.arrow.up") }
                }
            }
            .textCase(nil)
        }
    }
}

private struct DeviceRow: View {
    let device: FoundDevice

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .fontWeight(device.looksHuawei ? .semibold : .regular)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    if device.looksHuawei { Text("Huawei").foregroundStyle(.orange) }
                    if device.systemConnected { Text(L("connected to phone", "telefona bağlı")).foregroundStyle(.green) }
                }
                .font(.caption)
            }
            Spacer()
            if let rssi = device.rssi {
                Text("\(rssi) dBm").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
    }

    private var color: Color {
        switch entry.kind {
        case .info: return .primary
        case .sent: return .blue
        case .received: return .purple
        case .success: return .green
        case .error: return .red
        }
    }
}
