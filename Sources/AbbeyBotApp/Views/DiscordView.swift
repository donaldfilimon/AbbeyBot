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
    @State private var pendingVoiceFlags: PendingVoiceFlags?

    var body: some View {
        Form {
            connectionSection
            slashCommandsSection
            voiceTransportSection
            privacySection
            localCaptureSection
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
        .onDisappear {
            Task { await engine.mediaSession.stopLocalCaptureWhenViewDisappears() }
        }
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

            LabeledContent("Connection phase") { Text(engine.mediaSession.connectionPhaseLabel) }
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

            Divider()

            Text("Gateway presence only — self-mute/self-deaf change what Discord and other members see, not what is heard. There is no Opus/UDP audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Probe transport above always ends by leaving (DAVE media is unavailable), so these stay disabled after it. They enable only while presence is held via Discord's `/voice join` slash command.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            LabeledContent("Presence") { Text(engine.mediaSession.muteDeafenLabel) }
            HStack {
                Toggle("Self-mute", isOn: muteBinding)
                    .accessibilityLabel("Discord self-mute presence")
                Toggle("Self-deafen", isOn: deafenBinding)
                    .accessibilityLabel("Discord self-deafen presence")
            }
            .disabled(
                !engine.mediaSession.voicePresenceConfirmed
                    || engine.mediaSession.isOperationInFlight
            )
            .onChange(of: confirmedVoiceFlags) { _, confirmed in
                // Discord's echo caught up with the requested pair — hand the
                // toggles back to confirmed state.
                if pendingVoiceFlags == confirmed { pendingVoiceFlags = nil }
            }
            .onChange(of: engine.mediaSession.voicePresenceConfirmed) { _, confirmed in
                if !confirmed { pendingVoiceFlags = nil }
            }
            Text("Toggles show your requested state until Discord's echo confirms it (polled every 2s).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The operator's requested mute/deafen pair while Discord's echo is still
    /// pending. Both bindings read and extend this pair so two quick toggles
    /// compose (mute-on then deafen-on sends `(true,false)` then `(true,true)`)
    /// instead of each combining with the other's stale confirmed value and
    /// silently undoing the first change.
    private struct PendingVoiceFlags: Equatable {
        var selfMute: Bool
        var selfDeaf: Bool
    }

    private var confirmedVoiceFlags: PendingVoiceFlags {
        PendingVoiceFlags(
            selfMute: engine.mediaSession.voiceSelfMute,
            selfDeaf: engine.mediaSession.voiceSelfDeaf
        )
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { pendingVoiceFlags?.selfMute ?? engine.mediaSession.voiceSelfMute },
            set: { value in
                var desired = pendingVoiceFlags ?? confirmedVoiceFlags
                desired.selfMute = value
                sendVoiceFlags(desired)
            }
        )
    }

    private var deafenBinding: Binding<Bool> {
        Binding(
            get: { pendingVoiceFlags?.selfDeaf ?? engine.mediaSession.voiceSelfDeaf },
            set: { value in
                var desired = pendingVoiceFlags ?? confirmedVoiceFlags
                desired.selfDeaf = value
                sendVoiceFlags(desired)
            }
        )
    }

    private func sendVoiceFlags(_ desired: PendingVoiceFlags) {
        pendingVoiceFlags = desired
        Task {
            statusMessage = await engine.setVoiceMuteDeafen(
                selfMute: desired.selfMute,
                selfDeaf: desired.selfDeaf
            )
            if engine.mediaSession.operatorError != nil {
                // The request failed — resync the toggles to Discord's
                // confirmed state instead of pinning a pair that never lands.
                pendingVoiceFlags = nil
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
    private var localCaptureSection: some View {
        Section("Local video capture — preview only") {
            Text(MediaSessionCopy.localPreviewOnly)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(engine.mediaSession.localCaptureActive ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(
                    engine.mediaSession.localCaptureActive
                        ? "Local capture active — nothing is transmitted"
                        : "Local capture stopped"
                )
                .font(.caption)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                engine.mediaSession.localCaptureActive
                    ? "Local capture active, nothing is transmitted"
                    : "Local capture stopped"
            )

            ControlGroup {
                Button("Start camera (local preview)") {
                    Task { await engine.mediaSession.startCameraCapture() }
                }
                .help("Start LOCAL camera capture with an in-app preview. Frames are never transmitted.")
                .disabled(
                    engine.mediaSession.mediaDisabled
                        || engine.mediaSession.isOperationInFlight
                        || engine.mediaSession.localVideoCaptureActive
                )

                Button("Start screen capture (local only)") {
                    Task { await engine.mediaSession.startScreenCapture() }
                }
                .help("Start LOCAL screen capture. Frames are never transmitted.")
                .disabled(
                    engine.mediaSession.mediaDisabled
                        || engine.mediaSession.isOperationInFlight
                        || engine.mediaSession.localVideoCaptureActive
                )

                Button("Stop local capture", role: .destructive) {
                    Task { await engine.mediaSession.stopLocalCapture() }
                }
                .help("Stop local capture immediately via the kill switch. Discord signaling is untouched.")
                .disabled(!engine.mediaSession.localCaptureActive || engine.mediaSession.isOperationInFlight)
            }

            if let preview = engine.mediaSession.cameraPreviewImage {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Local camera preview — not transmitted")
            } else if engine.mediaSession.runtime.cameraCapturing {
                Text("Camera capture is active locally; waiting for the first preview frame…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
