import SwiftUI
import AbbeyCore

struct DiscordView: View {
    @Environment(AbbeyEngine.self) private var engine
    @Bindable private var config = AppConfig.shared
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var voiceGuildId = ""
    @State private var voiceChannelId = ""

    var body: some View {
        Form {
            Section("Connection") {
                SecureField("Bot token", text: $config.discordBotToken)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in Keychain (service com.donaldfilimon.AbbeyBot). Env: DISCORD_BOT_TOKEN")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("State") {
                    Text(stateLabel)
                        .foregroundStyle(stateColor)
                }
                if let botId = engine.discordBotUserId {
                    LabeledContent("Bot user") { Text(botId).font(.caption.monospaced()) }
                }
                if let err = engine.discordLastError ?? statusMessage {
                    Text(err).foregroundStyle(.red).font(.caption)
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

            Section("Voice presence") {
                Text(DiscordCopy.voiceStatus(
                    guildId: engine.discordVoiceGuildId,
                    channelId: engine.discordVoiceChannelId
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(DiscordCopy.voicePresenceOnly)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                TextField("Guild ID", text: $voiceGuildId)
                    .textFieldStyle(.roundedBorder)
                TextField("Voice channel ID", text: $voiceChannelId)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Join") {
                        Task {
                            isBusy = true
                            let guild = voiceGuildId.isEmpty ? config.discordDevGuildId : voiceGuildId
                            statusMessage = await engine.joinVoice(guildId: guild, channelId: voiceChannelId)
                            isBusy = false
                        }
                    }
                    .disabled(engine.discordState != .connected || voiceChannelId.isEmpty || isBusy)

                    Button("Leave") {
                        Task {
                            isBusy = true
                            let guild = voiceGuildId.isEmpty
                                ? (engine.discordVoiceGuildId ?? config.discordDevGuildId)
                                : voiceGuildId
                            statusMessage = await engine.leaveVoice(guildId: guild.isEmpty ? nil : guild)
                            isBusy = false
                        }
                    }
                    .disabled(engine.discordState != .connected || isBusy)
                }
            }

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
            if voiceGuildId.isEmpty, !config.discordDevGuildId.isEmpty {
                voiceGuildId = config.discordDevGuildId
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await engine.refreshDiscordStatus()
            }
        }
    }

    private var stateLabel: String {
        engine.discordState.displayName
    }

    private var stateColor: Color {
        switch engine.discordState {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

}
