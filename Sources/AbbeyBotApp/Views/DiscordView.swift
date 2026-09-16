import AbbeyCore
import AbbeyMediaMacOS
import SwiftUI

struct DiscordView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Environment(\.scenePhase) private var scenePhase
    @Bindable private var config = AppConfig.shared
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var voiceGuildId = ""
    @State private var voiceChannelId = ""
    @State private var pendingVoiceFlags: PendingVoiceFlags?
    @State private var authorizingManagerUserID = ""
    @State private var allParticipantsConsented = false
    @State private var consentAudioReceive = false
    @State private var consentCamera = false
    @State private var consentGoLive = false

    var body: some View {
        Form {
            connectionSection
            slashCommandsSection
            voiceTransportSection
            liveQualificationSection
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
                await engine.mediaSession.refreshQualification(
                    guildID: voiceGuildId,
                    channelID: voiceChannelId,
                    managerUserID: authorizingManagerUserID,
                    allCurrentParticipantsConsented: allParticipantsConsented
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task { await engine.mediaSession.closeQualification(.applicationBackgrounded) }
        }
        .onChange(of: allParticipantsConsented) { _, consented in
            guard !consented, engine.mediaSession.qualification.epoch != nil else { return }
            Task { await engine.mediaSession.closeQualification(.consentRevoked) }
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
            // Read from CommandSpec.all, which is what the button actually
            // publishes. The literal this replaced named seven of nineteen, so
            // the panel understated by twelve what pressing the button sends to
            // the guild, and nothing would have caught it drifting further.
            DisclosureGroup("Registers \(CommandSpec.all.count) commands") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CommandSpec.all, id: \.name) { spec in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("/\(spec.name)")
                                .font(.caption.monospaced())
                            Text(spec.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !spec.audienceNotes.isEmpty {
                                Text(spec.audienceNotes.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var voiceTransportSection: some View {
        Section("Voice signaling and transport") {
            Text("The ordinary probe validates Voice Gateway v8 and UDP while advertising DAVE version 0. A separate witnessed canary below is the only path that may advertise the audited DAVE version.")
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
                .help("Probe Discord signaling and UDP transport with DAVE version 0. No media is sent.")
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

            Text("Gateway presence controls — self-mute/self-deaf change what Discord and other members see. They are separate from the qualified media consent and kill switches below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("The ordinary probe always ends by leaving because it advertises DAVE 0. These controls enable only while presence is held via Discord's `/voice join` slash command.")
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

            Divider()

            Text("Receiving decrypts and plays the audio of everyone else in the channel. It is off until you turn it on, is never started by joining, and does not carry over to a new session.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Receive channel audio", isOn: receiveBinding)
                .accessibilityLabel("Decrypt and play other members' audio")
                .disabled(
                    !engine.mediaSession.snapshot.localMediaAvailable
                        || engine.mediaSession.isOperationInFlight
                )
            LabeledContent("Receiving") {
                Text(engine.mediaSession.snapshot.receiveActive ? "on" : "off")
            }
            if !engine.mediaSession.snapshot.localMediaAvailable {
                Text("Unavailable: this session has no composed playback path yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var liveQualificationSection: some View {
        Section("Live DAVE and H.264 qualification") {
            let state = engine.mediaSession.qualification
            LabeledContent("Canary build flag") {
                Text(state.canaryEnabled ? "enabled" : "disabled")
                    .foregroundStyle(state.canaryEnabled ? Color.orange : Color.secondary)
            }
            LabeledContent("Consent epoch") {
                Text(state.epoch == nil ? "closed" : "open")
                    .foregroundStyle(state.epoch == nil ? Color.secondary : Color.green)
            }
            LabeledContent("Observed human participants") {
                Text("\(engine.mediaSession.qualificationParticipantCount)")
            }
            LabeledContent("Current manager authorization") {
                Text(engine.mediaSession.qualificationManagerAuthorized ? "verified" : "not verified")
            }
            if let reason = state.lastCloseReason {
                LabeledContent("Last kill reason") { Text(reason.rawValue) }
            }
            if let epoch = state.epoch {
                LabeledContent("Epoch receipt") {
                    Text(String(epoch.hash.prefix(12)) + "…")
                        .font(.caption.monospaced())
                }
                LabeledContent("DAVE / codec") {
                    Text("v\(state.daveProtocolVersion ?? 0) · \(state.codec ?? "none")")
                }
            }

            TextField("Authorizing Discord manager user ID", text: $authorizingManagerUserID)
                .textFieldStyle(.roundedBorder)
            Toggle("Every currently observed participant consented", isOn: $allParticipantsConsented)
            Toggle("Consent: decrypt and play audio", isOn: $consentAudioReceive)
            Toggle("Consent: camera send and receive", isOn: $consentCamera)
            Toggle("Consent: Go Live screen send and receive", isOn: $consentGoLive)

            Text("Camera and Go Live consent are separate. Any participant move, permission change, reconnect, revocation, interruption, app backgrounding, or emergency stop closes the epoch and stops every lane.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ControlGroup {
                Button("Open epoch and join canary") {
                    Task {
                        await engine.mediaSession.openQualificationAndJoin(
                            guildID: voiceGuildId,
                            channelID: voiceChannelId,
                            managerUserID: authorizingManagerUserID,
                            allCurrentParticipantsConsented: allParticipantsConsented,
                            capabilities: selectedQualificationCapabilities
                        )
                    }
                }
                .disabled(
                    !state.canaryEnabled
                        || engine.discordState != .connected
                        || engine.mediaSession.isOperationInFlight
                        || voiceGuildId.isEmpty
                        || voiceChannelId.isEmpty
                        || authorizingManagerUserID.isEmpty
                        || !allParticipantsConsented
                )

                Button("Revoke consent", role: .destructive) {
                    allParticipantsConsented = false
                    Task { await engine.mediaSession.closeQualification(.consentRevoked) }
                }
                .disabled(state.epoch == nil)

                Button("Emergency media stop", role: .destructive) {
                    allParticipantsConsented = false
                    Task { await engine.mediaSession.closeQualification(.emergencyStop) }
                }
            }

            if engine.mediaSession.videoNegotiationObservations.isEmpty {
                Text("No content-free video negotiation metadata observed yet. H.264 promotion remains blocked.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(engine.mediaSession.videoNegotiationObservations.enumerated()), id: \.offset) { _, item in
                    LabeledContent("Opcode \(item.opcode) · \(item.fieldPath)") {
                        Text("\(item.codecLabel) PT \(item.payloadType) · DAVE \(item.daveProtocolVersion ?? 0)")
                            .font(.caption.monospaced())
                    }
                }
            }
        }
    }

    private var selectedQualificationCapabilities: Set<LiveMediaCapability> {
        var capabilities: Set<LiveMediaCapability> = [.audioSend]
        if consentAudioReceive { capabilities.insert(.audioReceive) }
        if consentCamera { capabilities.formUnion([.cameraSend, .cameraReceive]) }
        if consentGoLive { capabilities.formUnion([.screenSend, .screenReceive]) }
        return capabilities
    }

    /// Reads the controller's actual state rather than a local optimistic flag:
    /// a refused enable must show as still-off, not as on.
    private var receiveBinding: Binding<Bool> {
        Binding(
            get: { engine.mediaSession.snapshot.receiveActive },
            set: { value in
                Task { await engine.mediaSession.setReceiveEnabled(value) }
            }
        )
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
            Text("Meters remain zero until a qualified lane installs its bounded level stream; zero never implies consent or transmission.")
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
