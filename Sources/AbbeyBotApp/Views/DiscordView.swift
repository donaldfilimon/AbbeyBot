import AbbeyCore
import AbbeyMediaMacOS
import SwiftUI

struct DiscordView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Bindable private var config = AppConfig.shared
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var voiceGuildId = ""
    @State private var voiceChannelId = ""

    var body: some View {
        Form {
            connectionSection
            slashCommandsSection
            voiceTransportSection
            privacySection
            deviceSection

            Section("Intents") {
                Text("guildMessages · messageContent · guildMembers · directMessages · guildMessageReactions · guildVoiceStates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Auto-connect on launch (liveDiscord mode)", isOn: $config.autoConnectOnLaunch)
            }

            Section("Session") {
                LabeledContent("Live Discord ingests") {
                    Text("\(engine.liveIngestCount)")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Discord")
        .task {
            await engine.refreshDiscordStatus()
            await engine.mediaSession.refreshPrivacyStatus()
            if voiceGuildId.isEmpty, !config.discordDevGuildId.isEmpty {
                voiceGuildId = config.discordDevGuildId
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await engine.refreshDiscordStatus()
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            SecureField("Bot token", text: $config.discordBotToken)
                .textFieldStyle(.roundedBorder)
            Text("Stored in Keychain (service com.donaldfilimon.AbbeyBot). Env: DISCORD_BOT_TOKEN")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("State") {
                Text(engine.discordState.displayName)
                    .foregroundStyle(stateColor)
            }
            if let botId = engine.discordBotUserId {
                LabeledContent("Bot user") { Text(botId).font(.caption.monospaced()) }
            }
            if let error = engine.discordLastError ?? statusMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button(engine.discordState == .connected ? "Reconnect" : "Connect") {
                    Task {
                        isBusy = true
                        config.operatingMode = .liveDiscord
                        await engine.connectDiscord()
                        isBusy = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.discordBotToken.isEmpty || isBusy)

                Button("Disconnect", role: .destructive) {
                    Task {
                        isBusy = true
                        await engine.disconnectDiscord()
                        isBusy = false
                    }
                }
                .disabled(engine.discordState == .disconnected || isBusy)
            }
        }
    }

    @ViewBuilder
    private var slashCommandsSection: some View {
        Section("Slash commands") {
            TextField("Dev guild ID (optional, instant register)", text: $config.discordDevGuildId)
                .textFieldStyle(.roundedBorder)
            Text("Env: DISCORD_DEV_GUILD_ID — leave empty for global registration (slower).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Register slash commands") {
                Task {
                    isBusy = true
                    do {
                        try await engine.registerSlashCommands()
                        statusMessage = "Commands registered."
                    } catch {
                        statusMessage = OperatorFacingError.message(error)
                    }
                    isBusy = false
                }
            }
            .disabled(engine.discordState != .connected || isBusy)
            Text("Commands: ask, rep, remember, forget, context, persona, voice")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var voiceTransportSection: some View {
        Section("Voice signaling and transport — no media") {
            Text("This explicit probe requests Discord voice credentials, opens Voice Gateway v8, performs persistent UDP discovery, selects transport, and then auto-leaves because production DAVE media is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Signaling") { Text(engine.mediaSession.signalingLabel) }
            LabeledContent("Transport") { Text(engine.mediaSession.transportLabel) }
            LabeledContent("DAVE") {
                Text(engine.mediaSession.daveLabel).foregroundStyle(.orange)
            }
            LabeledContent("Capture") {
                Text(engine.mediaSession.captureLabel).foregroundStyle(.secondary)
            }

            TextField("Guild ID", text: $voiceGuildId)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Discord voice guild ID")
            TextField("Voice channel ID", text: $voiceChannelId)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Discord voice channel ID")

            ControlGroup {
                Button("Probe transport") {
                    Task {
                        let guild = voiceGuildId.isEmpty ? config.discordDevGuildId : voiceGuildId
                        statusMessage = await engine.joinVoice(guildId: guild, channelId: voiceChannelId)
                    }
                }
                .help("Probe Discord signaling and UDP transport. No media is sent; AbbeyBot auto-leaves.")
                .disabled(
                    engine.discordState != .connected
                        || voiceChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || engine.mediaSession.isOperationInFlight
                )

                Button("Leave") {
                    Task { statusMessage = await engine.leaveVoice() }
                }
                .disabled(engine.mediaSession.snapshot.phase == .idle || engine.mediaSession.isOperationInFlight)

                Button("Disconnect transport") {
                    Task { statusMessage = await engine.disconnectVoiceTransport() }
                }
                .disabled(engine.mediaSession.snapshot.phase == .idle || engine.mediaSession.isOperationInFlight)

                Button("Stop all media", role: .destructive) {
                    Task { statusMessage = await engine.stopAllVoiceMedia() }
                }
                .help("Immediately stop local capture and await Discord voice transport teardown.")
            }

            if let error = engine.mediaSession.operatorError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section("Privacy checks") {
            Text("Permission prompts occur only after one of these buttons is pressed. Permission checks never start capture or transmit media.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(MediaPermissionKind.allCases, id: \.self) { kind in
                HStack {
                    LabeledContent(permissionTitle(kind)) {
                        Text(MediaSessionCopy.permission(engine.mediaSession.permissionStatus(kind)))
                    }
                    Spacer()
                    Button("Check / Request") {
                        Task { await engine.mediaSession.requestPermission(kind) }
                    }
                    .accessibilityLabel("Check or request \(permissionTitle(kind)) permission")
                    .disabled(engine.mediaSession.permissionInFlight != nil)
                }
            }

            if engine.mediaSession.mediaDisabled {
                Text("ABBEY_MEDIA_DISABLED=1: permissions are unavailable and requests are suppressed for this launch.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LabeledContent("Microphone capture") {
                Text(engine.mediaSession.runtime.microphoneCapturing ? "Active locally" : "Stopped")
            }
            LabeledContent("Camera capture") {
                Text(engine.mediaSession.runtime.cameraCapturing ? "Active locally" : "Stopped")
            }
            LabeledContent("Screen capture") {
                Text(engine.mediaSession.runtime.screenCapturing ? "Active locally" : "Stopped")
            }
            ProgressView(value: engine.mediaSession.runtime.inputLevel, total: 1)
                .accessibilityLabel("Local microphone level")
                .accessibilityValue("\(Int(engine.mediaSession.runtime.inputLevel * 100)) percent")
            ProgressView(value: engine.mediaSession.runtime.outputLevel, total: 1)
                .accessibilityLabel("Local playback level")
                .accessibilityValue("\(Int(engine.mediaSession.runtime.outputLevel * 100)) percent")
            Text("Meters remain at zero because capture/playback is not connected to Discord media.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section("Audio devices — session only") {
            Text(MediaSessionCopy.sessionOnlySelection)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh devices") {
                Task { await engine.mediaSession.refreshDevices() }
            }
            .disabled(engine.mediaSession.mediaDisabled)

            Picker("Input", selection: inputBinding) {
                Text("System default").tag("")
                ForEach(engine.mediaSession.devices.filter(\.supportsInput)) { device in
                    Text(device.isDefaultInput ? "\(device.name) (default)" : device.name)
                        .tag(device.id)
                }
            }
            .disabled(engine.mediaSession.mediaDisabled)

            Picker("Output", selection: outputBinding) {
                Text("System default").tag("")
                ForEach(engine.mediaSession.devices.filter(\.supportsOutput)) { device in
                    Text(device.isDefaultOutput ? "\(device.name) (default)" : device.name)
                        .tag(device.id)
                }
            }
            .disabled(engine.mediaSession.mediaDisabled)
        }
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { engine.mediaSession.selectedInputUID ?? "" },
            set: { value in
                Task { await engine.mediaSession.selectInput(uid: value.isEmpty ? nil : value) }
            }
        )
    }

    private var outputBinding: Binding<String> {
        Binding(
            get: { engine.mediaSession.selectedOutputUID ?? "" },
            set: { value in
                Task { await engine.mediaSession.selectOutput(uid: value.isEmpty ? nil : value) }
            }
        )
    }

    private var stateColor: Color {
        switch engine.discordState {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    private func permissionTitle(_ kind: MediaPermissionKind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .screen: "Screen recording"
        case .systemAudio: "System audio"
        }
    }
}
