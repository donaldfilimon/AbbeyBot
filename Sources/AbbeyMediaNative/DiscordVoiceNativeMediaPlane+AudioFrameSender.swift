import AbbeyCore

/// Phase 6a capture composition: the portable `DiscordVoiceCaptureLoop`
/// drives the Phase 5 protected send path through this conformance.
///
/// `DiscordVoiceNativeMediaPlane.sendAudioFrame(pcm:)` already fails closed
/// without an installed generation and an attested DAVE session, so composing
/// a capture source through this boundary can never bypass DAVE or AEAD
/// protection, and a capture loop started before negotiation completes sends
/// nothing.
extension DiscordVoiceNativeMediaPlane: DiscordVoiceAudioFrameSender {}
