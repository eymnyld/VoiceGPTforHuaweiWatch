import AVFoundation
import NaturalLanguage
import Security
import Speech
import SwiftUI

enum WatchVoiceProvider: String, CaseIterable, Identifiable {
    case hermes, codex, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hermes: "Hermes Call"
        case .codex: "ChatGPT Voice"
        case .claude: "Claude Voice"
        }
    }
}

@MainActor
@Observable
final class HermesFeature: WatchFeature {
    private weak var host: WatchFeatureHost?
    private let synthesizer = AVSpeechSynthesizer()
    private let legacyPackage = "com.example.huasideload.fitlink"
    private let hermesPackage = "com.example.huasideload.voice"

    private var sessions = HermesSessions.load()
    private var voiceTask: Task<Void, Never>?
    private var voiceCallActive = false

    private var claudeHistory: [HermesAPI.Message] = []
    private(set) var voiceFavorites = Set(
        (UserDefaults.standard.stringArray(forKey: "voice.favorites") ?? ["codex", "hermes"])
            .compactMap(WatchVoiceProvider.init(rawValue:))
    )
    var defaultVoice: WatchVoiceProvider = {
        let defaults = UserDefaults.standard
        return defaults.string(forKey: "voice.default").flatMap(WatchVoiceProvider.init(rawValue:))
            ?? ((defaults.object(forKey: "hermes.codexVoice") as? Bool ?? true) ? .codex : .hermes)
    }() {
        didSet { UserDefaults.standard.set(defaultVoice.rawValue, forKey: "voice.default") }
    }

    func toggleFavorite(_ provider: WatchVoiceProvider) {
        if !voiceFavorites.insert(provider).inserted { voiceFavorites.remove(provider) }
        UserDefaults.standard.set(voiceFavorites.map(\.rawValue), forKey: "voice.favorites")
        sendFavorites()
    }

    func sendFavorites() {
        host?.bridge(for: hermesPackage)?.send([
            "t": "voice-favorites", "s": voiceFavorites.map(\.rawValue).sorted().joined(separator: ","),
            "lang": AppLanguage.current.rawValue
        ])
    }

    func startVoice(_ provider: WatchVoiceProvider) async {
        switch provider {
        case .codex: await startCodexVoice()
        case .hermes, .claude: await startVoiceChat(provider: provider)
        }
    }

    var apiKey = ""
    private(set) var answer = ""
    private(set) var error: String?
    private(set) var sending = false
    var watchPackages: [String] { [hermesPackage, legacyPackage] }

    func attach(to host: WatchFeatureHost) {
        self.host = host
    }

    func sections() -> AnyView {
        AnyView(Group {
            VoiceProviderSettings(feature: self)
            HermesSection(feature: self)
        })
    }

    func handle(_ message: [String: Any], from package: String) async -> Bool {
        guard watchPackages.contains(package), let type = message["t"] as? String else { return false }
        switch type {
        case "hermes-latest":
            if package == hermesPackage {
                showSession(to: package)
            } else {
                sendToWatch(answer.isEmpty ? L("No Hermes reply yet.", "Henüz Hermes yanıtı yok.") : answer, to: package)
            }
        case "hermes-new", "hermes-next":
            guard package == hermesPackage else { return false }
            guard !sending, !voiceCallActive else {
                sendToWatch(L("Finish the active request or voice chat first.", "Önce açık isteği veya sesli sohbeti bitir."), to: package)
                return true
            }
            if type == "hermes-new" { sessions.add() }
            else { sessions.selected = (sessions.selected + 1) % sessions.histories.count }
            sessions.save()
            showSession(to: package)
        case "hermes-speak":
            if package == hermesPackage { speakOnWatch() }
            else { speak() }
        case "hermes-dictate":
            guard package == hermesPackage else { return false }
            await startVoice(defaultVoice)
        case "voice-favorites":
            guard package == hermesPackage else { return false }
            sendFavorites()
        case "voice-start":
            guard package == hermesPackage, let name = message["s"] as? String,
                  let provider = WatchVoiceProvider(rawValue: name) else { return false }
            await startVoice(provider)
        case "hermes-ask":
            guard let prompt = message["s"] as? String else { return true }
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 120 else {
                sendToWatch(L("Enter up to 120 characters.", "En fazla 120 karakter yaz."), to: package)
                return true
            }
            guard !sending, !voiceCallActive else {
                sendToWatch(L("Finish the active request or voice chat first.", "Önce açık isteği veya sesli sohbeti bitir."), to: package)
                return true
            }
            let defaults = UserDefaults.standard
            let savedServer = defaults.string(forKey: "hermes.server") ?? ""
            await ask(text, server: savedServer,
                      readAloud: package != hermesPackage && defaults.bool(forKey: "hermes.readAloud"), watchPackage: package)
            if let error { sendToWatch(error, to: package) }
        default:
            return false
        }
        return true
    }

    func ask(_ prompt: String, server: String, readAloud: Bool, watchPackage: String? = nil, onToolStart: (@MainActor () -> Void)? = nil) async {
        guard !sending, !voiceCallActive || onToolStart != nil else { return }
        error = nil
        sending = true
        defer { sending = false }

        do {
            let userMessage = HermesAPI.Message(role: "user", content: prompt)
            let isWatchSession = watchPackage == hermesPackage
            let messages = (isWatchSession ? sessions.histories[sessions.selected] : []) + [userMessage]
            let reply = try await HermesAPI.ask(messages, server: server, apiKey: apiKey, onToolStart: onToolStart)
            try Task.checkCancellation()
            answer = reply
            if isWatchSession {
                sessions.histories[sessions.selected] = Array((messages + [
                    HermesAPI.Message(role: "assistant", content: String(reply.prefix(4000)))
                ]).suffix(16))
                sessions.save()
            }
            if let watchPackage {
                sendToWatch(reply, to: watchPackage)
            } else {
                for package in watchPackages {
                    sendToWatch(reply, to: package)
                }
            }
            if readAloud { speak() }
        } catch {
            guard !Task.isCancelled else { return }
            let message = HermesAPI.describe(error)
            self.error = message
            let diagnostic = error as NSError
            host?.log(.error, "Hermes: \(message) [\(diagnostic.domain) \(diagnostic.code)]")
        }
    }

    func speak() {
        guard !voiceCallActive else { return }
        speak(answer)
    }

    private func speak(_ text: String, enqueue: Bool = false) {
        guard !text.isEmpty else { return }
        if !enqueue { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.usesApplicationAudioSession = true
        let utterance = AVSpeechUtterance(string: text)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage {
            utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        }
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func showSession(to package: String) {
        let label = L("Session", "Oturum") + " \(sessions.selected + 1)/\(sessions.histories.count)"
        sendToWatch(label + " · " + (sessions.lastAnswer ?? L("Write a new message.", "Yeni mesaj yaz.")), to: package)
    }

    private func speakOnWatch() {
        guard let text = sessions.lastAnswer, let speaker = host?.speaker else {
            sendToWatch(L("No reply in this session yet.", "Bu oturumda henüz yanıt yok."), to: hermesPackage)
            return
        }
        let started = speaker.ringForHermes(ready: { [weak self] in
            self?.speak(text)
        }, ended: { [weak self] in
            self?.stopSpeaking()
        })
        sendToWatch(started ? L("Answer on your watch and hang up when you are done.", "Aramayı saatten aç. Dinleyince kapat.") : L("Check that the watch is connected for calls.", "Saatin arama bağlantısını kontrol et."), to: hermesPackage)
    }

    private func startCodexVoice() async {
        guard !voiceCallActive, !sending, let speaker = host?.speaker, speaker.state == .idle else {
            sendToWatch(L("End the active voice call first.", "Önce açık ses oturumunu kapat."), to: hermesPackage)
            return
        }
        let address = UserDefaults.standard.string(forKey: "voice.codexURL") ?? ""
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "wss", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            sendToWatch(L("Enter a valid Codex WSS address on the iPhone.", "iPhone’da geçerli bir Codex WSS adresi gir."), to: hermesPackage)
            return
        }
        let key = VoiceKeychain.load(account: "voice.codex." + url.absoluteString)
        guard let key, !key.isEmpty else {
            sendToWatch(L("The Codex bridge key is missing on the iPhone.", "iPhone’da Codex köprü anahtarı eksik."), to: hermesPackage)
            return
        }
        voiceCallActive = true
        guard await AVAudioApplication.requestRecordPermission() else {
            voiceCallActive = false
            sendToWatch(L("Allow microphone access on the iPhone.", "iPhone’da mikrofon izni ver."), to: hermesPackage)
            return
        }

        let audio = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let socket = HermesAPI.codexSocket(url: url, key: key)
        let started = speaker.ringForHermes(input: { buffer in
            if let pcm = Self.codexPCM(buffer) { audio.continuation.yield(pcm) }
        }, playCallAudio: true, ready: { [weak self, weak speaker] in
            guard let self, let speaker else { return }
            self.voiceTask = Task {
                await self.runCodexVoice(socket: socket, audio: audio.stream, speaker: speaker)
            }
        }, ended: { [weak self] in
            audio.continuation.finish()
            self?.voiceTask?.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            self?.voiceTask = nil
            self?.voiceCallActive = false
            self?.stopSpeaking()
        })
        if !started {
            audio.continuation.finish()
            voiceCallActive = false
        }
        sendToWatch(started ? L("Answer the call on your watch to start Codex Voice.", "Codex Voice için aramayı saatten aç.") : L("Check that the watch is connected for calls.", "Saatin arama bağlantısını kontrol et."), to: hermesPackage)
    }

    private func runCodexVoice(socket: URLSessionWebSocketTask, audio: AsyncStream<Data>, speaker: WatchSpeaker) async {
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        do {
            guard case .string("ready") = try await socket.receive() else { throw URLError(.badServerResponse) }
            sendToWatch(L("Codex Voice connected.", "Codex Voice bağlı."), to: hermesPackage)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await frame in audio {
                        try Task.checkCancellation()
                        try await socket.send(.data(frame))
                    }
                }
                group.addTask { @MainActor in
                    while !Task.isCancelled {
                        switch try await socket.receive() {
                        case .data(let pcm): speaker.playCallPCM(pcm)
                        case .string("error"): throw URLError(.badServerResponse)
                        default: break
                        }
                    }
                }
                defer {
                    socket.cancel(with: .goingAway, reason: nil)
                    group.cancelAll()
                }
                try await group.next()
            }
        } catch {
            guard !Task.isCancelled, speaker.state == .playing else { return }
            let failure = error as NSError
            host?.log(.error, "Codex Voice: \(failure.domain) \(failure.code)")
            sendToWatch(L("Could not connect to Codex Voice, or the connection was lost.", "Codex Voice bağlantısı kurulamadı veya kesildi."), to: hermesPackage)
            await sayInCall(L("Codex Voice disconnected. Check the bridge URL and network connection.", "Codex Voice bağlantısı kesildi. Köprü adresini ve ağ bağlantısını kontrol et."), speaker: speaker)
            if !Task.isCancelled { speaker.stop() }
        }
    }

    nonisolated private static func codexPCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let input = buffer.floatChannelData?[0], buffer.frameLength > 0,
              buffer.format.sampleRate > 0 else { return nil }
        let step = buffer.format.sampleRate / 16_000
        let count = Int(Double(buffer.frameLength) / step)
        guard count > 0, count <= 4096 else { return nil }
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * step
            let lower = Int(position)
            let upper = min(lower + 1, Int(buffer.frameLength) - 1)
            let sample = input[lower] + Float(position - Double(lower)) * (input[upper] - input[lower])
            if sample.isFinite {
                samples[i] = Int16(max(-1, min(1, sample)) * 32767).littleEndian
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func startVoiceChat(provider: WatchVoiceProvider) async {
        guard !voiceCallActive, !sending, let speaker = host?.speaker, speaker.state == .idle else {
            sendToWatch(L("End the active voice call first.", "Önce açık ses oturumunu kapat."), to: hermesPackage)
            return
        }
        let claude: ClaudeConfiguration?
        if provider == .claude {
            guard let configuration = ClaudeConfiguration.load() else {
                sendToWatch(L("Set the Claude address, model and key on the iPhone.", "iPhone’da Claude adresini, modelini ve anahtarını ayarla."), to: hermesPackage)
                return
            }
            claude = configuration
            claudeHistory.removeAll()
        } else {
            claude = nil
        }
        voiceCallActive = true
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized, await AVAudioApplication.requestRecordPermission(),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: AppLanguage.current == .turkish ? "tr-TR" : "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            voiceCallActive = false
            sendToWatch(L("Check microphone access and offline English speech recognition on the iPhone.", "iPhone’da mikrofon izni ve çevrimdışı Türkçe konuşma tanımayı kontrol et."), to: hermesPackage)
            return
        }

        let capture = HermesVoiceCapture()
        let started = speaker.ringForHermes(input: capture.append, ready: { [weak self, weak speaker] in
            guard let self, let speaker else { return }
            self.voiceTask = Task {
                await self.runVoiceChat(recognizer: recognizer, capture: capture, speaker: speaker, claude: claude)
            }
        }, ended: { [weak self] in
            capture.setRequest(nil)
            guard let self else { return }
            self.voiceTask?.cancel()
            self.voiceTask = nil
            self.voiceCallActive = false
            self.stopSpeaking()
            self.showSession(to: self.hermesPackage)
        })
        if !started { voiceCallActive = false }
        sendToWatch(started ? L("Answer the call on your watch to start voice chat.", "Sesli sohbet için aramayı saatten aç.") : L("Check that the watch is connected for calls.", "Saatin arama bağlantısını kontrol et."), to: hermesPackage)
    }

    private func runVoiceChat(recognizer: SFSpeechRecognizer, capture: HermesVoiceCapture, speaker: WatchSpeaker, claude: ClaudeConfiguration?) async {
        func canTalk() -> Bool {
            !Task.isCancelled && speaker.state == .playing && speaker.hasWatchAudio
        }

        await sayInCall(L("I’m listening.", "Dinliyorum."), speaker: speaker)
        var announcedSilence = false
        while canTalk() {
            let turn = await listenForTurn(recognizer: recognizer, capture: capture)
            guard canTalk() else { return }
            guard !turn.isEmpty else {
                if !announcedSilence {
                    announcedSilence = true
                    await sayInCall(L("I didn’t hear anything. I’m still listening.", "Ses alamadım. Dinlemeye devam ediyorum."), speaker: speaker)
                } else {
                    // Avoid restarting in a tight loop if recognition fails immediately.
                    try? await Task.sleep(for: .milliseconds(500))
                }
                continue
            }
            announcedSilence = false
            if let claude {
                do {
                    let messages = claudeHistory + [.init(role: "user", content: turn)]
                    let reply = try await claude.ask(messages)
                    guard canTalk() else { return }
                    claudeHistory = Array((messages + [.init(role: "assistant", content: reply)]).suffix(16))
                    sendToWatch(reply, to: hermesPackage)
                    await sayInCall(reply, speaker: speaker)
                } catch {
                    guard canTalk() else { return }
                    let message = L("Could not get a Claude response. ", "Claude yanıtı alınamadı. ") + error.localizedDescription
                    sendToWatch(message, to: hermesPackage)
                    await sayInCall(message, speaker: speaker)
                }
                continue
            }
            let server = UserDefaults.standard.string(forKey: "hermes.server") ?? ""
            var announcedTool = false
            let thinking = Task {
                try? await Task.sleep(for: .seconds(2))
                guard canTalk(), !announcedTool else { return }
                speak(L("I’m thinking.", "Düşünüyorum."), enqueue: true)
            }
            await ask(turn, server: server,
                      readAloud: false, watchPackage: hermesPackage, onToolStart: {
                guard canTalk(), !announcedTool else { return }
                announcedTool = true
                thinking.cancel()
                self.speak(L("I’m using a tool.", "Bir araç kullanıyorum."), enqueue: true)
            })
            thinking.cancel()
            guard canTalk() else { return }
            if let error {
                sendToWatch(error, to: hermesPackage)
                await sayInCall(error, speaker: speaker)
            } else {
                await sayInCall(answer, speaker: speaker)
            }
        }
    }

    private func sayInCall(_ text: String, speaker: WatchSpeaker) async {
        guard !Task.isCancelled, speaker.state == .playing, speaker.hasWatchAudio else { return }
        speak(text, enqueue: true)
        while synthesizer.isSpeaking && !Task.isCancelled && speaker.hasWatchAudio {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Leave a small gap so the microphone does not catch the end of playback.
        try? await Task.sleep(for: .milliseconds(250))
    }

    private func listenForTurn(recognizer: SFSpeechRecognizer, capture: HermesVoiceCapture) async -> String {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(20)
        var lastChange = clock.now
        var transcript = ""
        var finished = false
        let recognition = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            DispatchQueue.main.async {
                if let text, !text.isEmpty, transcript != text {
                    transcript = text
                    lastChange = clock.now
                }
                finished = done
            }
        }
        capture.setRequest(request)
        defer {
            capture.setRequest(nil)
            recognition.cancel()
        }
        while !Task.isCancelled && !finished && clock.now < deadline {
            if !transcript.isEmpty && clock.now - lastChange >= .milliseconds(1800) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        capture.setRequest(nil)
        if !Task.isCancelled && !finished && !transcript.isEmpty {
            request.endAudio()
            let finalDeadline = clock.now + .milliseconds(750)
            while !Task.isCancelled && !finished && clock.now < finalDeadline {
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendToWatch(_ text: String, to package: String) {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var preview = ""
        for character in collapsed.prefix(120) {
            guard preview.utf8.count + String(character).utf8.count <= 280 else { break }
            preview.append(character)
        }
        if preview != collapsed { preview.append("…") }
        host?.bridge(for: package)?.send(["t": "hermes-reply", "s": preview])
    }
}

// The audio tap runs off the main thread. Disarm capture before playback or endAudio().
private final class HermesVoiceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func setRequest(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        request = value
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        request?.append(buffer)
    }
}

struct VoiceFavoritesSection: View {
    let feature: HermesFeature
    var body: some View {
        let favorites = WatchVoiceProvider.allCases.filter { feature.voiceFavorites.contains($0) }
        if !favorites.isEmpty {
            Section(L("Voice Favorites", "Ses favorileri")) {
                ForEach(favorites) { provider in
                    Button(provider.title, systemImage: "phone.waveform") {
                        Task { await feature.startVoice(provider) }
                    }
                }
            }
        }
    }
}

private struct VoiceProviderSettings: View {
    @Bindable var feature: HermesFeature
    @AppStorage("voice.codexURL") private var codexURL = ""
    @AppStorage("voice.claudeURL") private var claudeURL = ClaudeConfiguration.defaultURL
    @AppStorage("voice.claudeModel") private var claudeModel = ""
    @AppStorage("voice.claudeGateway") private var claudeGateway = false
    @State private var codexKey = ""
    @State private var claudeKey = ""
    @State private var keyStatus = ""

    var body: some View {
        Section(L("Voice Providers", "Ses sağlayıcıları")) {
            Picker(L("Default voice provider", "Varsayılan sesli sohbet"), selection: $feature.defaultVoice) {
                ForEach(WatchVoiceProvider.allCases) { Text($0.title).tag($0) }
            }
            ForEach(WatchVoiceProvider.allCases) { provider in
                HStack {
                    Button(provider.title, systemImage: "phone.waveform") {
                        Task { await feature.startVoice(provider) }
                    }
                    Spacer()
                    Button {
                        feature.toggleFavorite(provider)
                    } label: {
                        let isFavorite = feature.voiceFavorites.contains(provider)
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .accessibilityLabel(isFavorite ? L("Remove from favorites", "Favoriden çıkar") : L("Add to favorites", "Favoriye ekle"))
                    }
                }
                .buttonStyle(.borderless)
            }
            DisclosureGroup(L("ChatGPT Voice Settings", "ChatGPT Voice ayarları")) {
                TextField(L("WSS bridge URL", "WSS köprü adresi"), text: $codexURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                keyEditor(L("Bridge key", "Köprü anahtarı"), value: $codexKey, account: account("codex", address: codexURL))
            }
            DisclosureGroup(L("Claude Voice Settings", "Claude Voice ayarları")) {
                Toggle(L("OpenAI-compatible gateway", "OpenAI uyumlu ağ geçidi"), isOn: $claudeGateway)
                TextField(L("HTTPS URL", "HTTPS adresi"), text: $claudeURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(L("Model ID", "Model kimliği"), text: $claudeModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                keyEditor(L("API key", "API anahtarı"), value: $claudeKey, account: account("claude", address: claudeURL))
                Text(L("The iPhone reads Claude’s response aloud on the watch.", "Claude’un yanıtı iPhone’da seslendirilir ve saatten çalar."))
            }
            if !keyStatus.isEmpty { Text(keyStatus) }
        }
    }

    private func account(_ provider: String, address: String) -> String {
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return "voice." + provider + "." + (URL(string: cleaned)?.absoluteString ?? cleaned)
    }

    @ViewBuilder
    private func keyEditor(_ label: String, value: Binding<String>, account: String) -> some View {
        SecureField(label, text: value)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button(L("Save key", "Anahtarı kaydet")) {
            let key = value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let saved = VoiceKeychain.save(key, account: account)
            keyStatus = saved ? L("Key saved.", "Anahtar kaydedildi.") : L("Could not save the key.", "Anahtar kaydedilemedi.")
            if saved { value.wrappedValue = "" }
        }
        .disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct ClaudeConfiguration {
    static let defaultURL = "https://api.anthropic.com/v1/messages"
    private static let session = URLSession(
        configuration: .ephemeral, delegate: NoClaudeRedirects(), delegateQueue: nil
    )
    let url: URL
    let model: String
    let key: String
    let gateway: Bool

    static func load() -> Self? {
        let defaults = UserDefaults.standard
        let address = (defaults.string(forKey: "voice.claudeURL") ?? defaultURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (defaults.string(forKey: "voice.claudeModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !model.isEmpty, let key = VoiceKeychain.load(account: "voice.claude." + url.absoluteString),
              !key.isEmpty else { return nil }
        return Self(url: url, model: model, key: key, gateway: defaults.bool(forKey: "voice.claudeGateway"))
    }

    func ask(_ messages: [HermesAPI.Message]) async throws -> String {
        if gateway {
            return try await HermesAPI.ask(messages, server: url.absoluteString, apiKey: key,
                                           onToolStart: nil, model: model)
        }
        struct Request: Encodable {
            let model: String
            let max_tokens = 512
            let messages: [HermesAPI.Message]
        }
        struct Response: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: messages))
        let (data, response) = try await Self.session.data(for: request)
        try HermesAPI.validate(response)
        let result = try JSONDecoder().decode(Response.self, from: data)
        let answer = result.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HermesAPI.Failure.emptyReply
        }
        return answer
    }
}

private final class NoClaudeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct HermesSection: View {
    @Bindable var feature: HermesFeature
    @AppStorage("hermes.server") private var server = ""
    @AppStorage("hermes.readAloud") private var readAloud = false
    @State private var prompt = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        Section("Hermes") {
            TextField(L("Hermes server URL (HTTPS)", "Hermes sunucu adresi (HTTPS)"), text: $server)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(L("Hermes API key", "Hermes API anahtarı"), text: $feature.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(L("Type or dictate a message", "Mesaj yaz veya klavyeden dikte et"), text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .focused($promptFocused)
            Toggle(L("Read replies aloud on iPhone", "Yanıtı iPhone’da sesli oku"), isOn: $readAloud)
            Button(L("Send to Hermes", "Hermes’e gönder"), systemImage: "paperplane") {
                let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                promptFocused = false
                Task { await feature.ask(message, server: server, readAloud: readAloud) }
            }
            .disabled(feature.sending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if feature.sending { ProgressView(L("Waiting for Hermes…", "Hermes yanıtı bekleniyor…")) }
            if let error = feature.error { Text(error).foregroundStyle(.red) }
            if !feature.answer.isEmpty {
                Text(feature.answer).textSelection(.enabled)
                Button(L("Read aloud", "Sesli oku"), systemImage: "speaker.wave.2", action: feature.speak)
                Button(L("Stop reading", "Okumayı durdur"), systemImage: "stop", action: feature.stopSpeaking)
            }
        }
    }
}

private enum HermesAPI {
    private static let session = URLSession(configuration: .ephemeral)

    static func codexSocket(url: URL, key: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: url, timeoutInterval: 35)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 8192
        return socket
    }

    struct Message: Codable {
        let role: String
        let content: String
    }

    struct Request: Encodable {
        let model: String
        let stream: Bool
        let messages: [Message]
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            let message: Message
        }
        let choices: [Choice]
    }

    enum Failure: LocalizedError {
        case invalidURL, missingKey, emptyReply
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: L("Enter the HTTPS address of the Hermes server.", "Hermes sunucusunun HTTPS adresini gir.")
            case .missingKey: L("Enter the Hermes API key.", "Hermes API anahtarını gir.")
            case .emptyReply: L("Hermes returned an empty or unreadable response.", "Hermes boş veya okunamayan bir yanıt verdi.")
            case .http(401): L("Hermes rejected the API key (401).", "Hermes API anahtarını kabul etmedi (401).")
            case .http(let status): L("The Hermes request failed", "Hermes isteği başarısız oldu") + " (HTTP \(status))."
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.localizedDescription }
        return error.localizedDescription
    }

    static func ask(_ messages: [Message], server: String, apiKey: String,
                    onToolStart: (@MainActor () -> Void)?, model: String = "hermes-agent") async throws -> String {
        guard var url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw Failure.invalidURL
        }
        if !url.path.hasSuffix("/v1/chat/completions") {
            if !url.path.hasSuffix("/v1") { url.appendPathComponent("v1") }
            url.appendPathComponent("chat/completions")
        }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.missingKey }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let stream = onToolStart != nil
        request.httpBody = try JSONEncoder().encode(Request(model: model, stream: stream, messages: messages))

        if let onToolStart {
            request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response)
            if response.mimeType == "text/event-stream" {
                var stream = ChatStream()
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    if try stream.consume(line) { await onToolStart() }
                    if stream.done { break }
                }
                return try stream.reply()
            }
            // Some compatible servers ignore the stream option and return JSON.
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return try decodeReply(data)
        }
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try decodeReply(data)
    }

    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.emptyReply }
        guard (200..<300).contains(http.statusCode) else { throw Failure.http(http.statusCode) }
    }

    private static func decodeReply(_ data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { throw Failure.emptyReply }
        return content
    }
    struct ChatStream {
        private struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String? }
                let delta: Delta?
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        private struct ToolProgress: Decodable { let status: String }

        private var event = ""
        private var content = ""
        private var finished = false
        private(set) var done = false

        // Hermes sends one JSON payload per data line.
        mutating func consume(_ line: String) throws -> Bool {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                return false
            }
            if line.isEmpty { event = "" }
            guard line.hasPrefix("data:") else { return false }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            let name = event
            event = ""
            if payload == "[DONE]" {
                done = true
                return false
            }
            let data = Data(payload.utf8)
            if name == "hermes.tool.progress" {
                return (try? JSONDecoder().decode(ToolProgress.self, from: data))?.status == "running"
            }
            guard name.isEmpty || name == "message",
                  let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
                  let choice = chunk.choices.first else { return false }
            if choice.finish_reason == "error" { throw Failure.emptyReply }
            if choice.finish_reason != nil { finished = true }
            content += choice.delta?.content ?? ""
            return false
        }

        func reply() throws -> String {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard done || finished, !text.isEmpty else { throw Failure.emptyReply }
            return text
        }
    }

}

private enum VoiceKeychain {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HuaSideload.Voice",
            kSecAttrAccount as String: account
        ]
    }

    static func load(account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) -> Bool {
        let query = query(account)
        if value.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            return result == errSecSuccess || result == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let result = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard result == errSecItemNotFound else { return result == errSecSuccess }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

private struct HermesSessions: Codable {
    var histories: [[HermesAPI.Message]] = [[]]
    var selected = 0

    var lastAnswer: String? { histories[selected].last(where: { $0.role == "assistant" })?.content }

    mutating func add() {
        histories.append([])
        if histories.count > 5 { histories.removeFirst() }
        selected = histories.count - 1
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "hermes.watchSessions"),
              let saved = try? JSONDecoder().decode(Self.self, from: data),
              saved.histories.indices.contains(saved.selected) else { return Self() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "hermes.watchSessions")
        }
    }
}
