# Abbey delayed rewards: reactions, deleted replies, moderation confirmations

Date: 2026-09-16. Status: approved design; slices 1-4 implemented and unit-tested, not live-proven.
Owner: Donald (decisions), agent sessions (implementation).

## Problem

`DQNAgent` chooses a strategy (answer / clarify / retrieve / refuse) for every ingested
message. `IngestScorer` trains it only on an immediate heuristic reward, recorded as a
terminal contextual-bandit sample. Nothing a human does afterwards reaches the model.
`AGENTS.md` and `DQNAgent.swift` both named that gap. This design adds three delayed
human signals and one operator switch.

## Decisions

| Question | Decision |
|---|---|
| Which moderation outcomes count | Deleted replies **and** confirmed moderation actions |
| How a confirmation links to samples | By target user and guild (option 1 of 3) |
| Operator control | `ABBEY_DELAYED_REWARDS`, default on |
| Where it lives | `dev/active/AbbeyBot` (Swift/DiscordBM), both server and desktop graphs, except confirmations (desktop only) |

Rejected: an explicit request token from a flagged reply to a moderation action (no such
flow exists today; building it is new UI, not learning), and deletion-only (drops a
chosen signal). Audit-log attribution of deletions was not chosen; a deletion is counted
regardless of who deleted.

## Model

Every delayed reward is a **second terminal sample** for the same `(state, action)` that
ingest already recorded: `Experience(state, action, reward, nextState: state, done: true)`.
It is not an MDP transition and does not bootstrap. `IngestScorer` is not changed.

A **staged sample** is `(authorId, guildId, state, action, stagedAt)`, keyed by the user's message
id. It becomes **bound** when Abbey's reply to that message is delivered, keyed by the
reply's message id. Every staged or bound sample pays out **at most once** across all
signals, then is removed.

## Components

### `DelayedRewardLedger` (actor, `AbbeyCore/Engine`) — exists after slice 1

- `stage(sourceMessageId:authorId:state:action:now:)` — called by ingest.
- `bind(sourceMessageId:replyMessageId:now:) -> Bool` — called after a reply is delivered.
- `reward(replyMessageId:reactorId:botUserId:emojiName:isCustomEmoji:now:) -> Experience?`
  — reaction signal (slice 1).
- `consumeReplyDeletion(replyMessageId:now:) -> Experience?` — slice 3.
- `consumeModeration(targetUserId:guildId:now:) -> [Experience]` — slice 4.
- Samples carry `guildId`; `consumeModeration` scans both tables (at most 1,024 entries)
  instead of keeping a secondary author index, so there is no index to keep consistent
  (slice 4; changed from the approved in-chat design during implementation).
- `isEnabled` fixed at init from config; when false, `stage` records nothing, so every
  signal is a no-op and re-enabling never replays history (slice 2).

### Ingress adapters (`AbbeyCore/Discord`)

- `ReactionRewardIngress.apply` — MESSAGE_REACTION_ADD (slice 1).
- `ReplyDeletionIngress.apply` — MESSAGE_DELETE **and MESSAGE_DELETE_BULK**, both
  delivered on the existing `.guildMessages` intent (slice 3). A purge arrives as a bulk
  delete, so handling only the single event would let purged replies escape the signal.
- `ModerationRewardIngress.apply` — shared adapter the desktop listener calls (slice 4).
- `DiscordEventHooks` gains `onMessageReactionAdd` (slice 1), `onMessageDelete` and
  `onMessageDeleteBulk` (slice 3), each defaulted to a no-op; `AbbeyGatewayHandler`
  forwards all three.
- `MessageIngress` reports `(sourceMessageId, replyMessageId)` through `noteReply` after
  a successful send; a reply body that fails to decode loses only that link (slice 1).

### Moderation listener (desktop, `AbbeyBotApp/AbbeyEngine`) — slice 4

On `.destructiveActionConfirmed(kind, targetUserId, guildId)` from the existing
`EventBus`, call `consumeModeration` and feed each sample to the agent.
`.destructiveActionCancelled` produces nothing. `ConfirmationGate` publishes
`.destructiveActionConfirmed` for every approved action, including the immediate approval
when confirmation is disabled (UserDefaults key `ABBEY_CONFIRMATION_REQUIRED`, default on;
not read from the environment), so a kick that goes ahead is rewarded either way. (Before
2026-09-16 the disabled path published no confirmation event, so it produced no reward and
went uncounted in the desktop metrics.) `BotRuntime` has no `ConfirmationGate`, so
the server graph has no moderation signal; that asymmetry is documented, not hidden.

### Configuration — slice 2

`AppConfig.delayedRewardsEnabled`, following the existing boolean pattern
(`dryRun`, `decentralizationEnabled`): environment variable `ABBEY_DELAYED_REWARDS`
first, then a UserDefaults key, then the default `true`. Because the default is on, only
the recognised false tokens `0`, `false`, `no`, `off` (case-insensitive, trimmed) disable
it; any other value leaves it on. Surfaced in `/status` output and the desktop Discord
view.

Deviation from the in-chat design: section 2 said an unrecognised value would raise a
"validation warning". `AppConfig` has no warning channel; `validateForStartup` can only
throw, and failing startup over a feature switch is disproportionate. Unrecognised
values are therefore treated as "on", matching the default, and `/status` shows the
effective value so a typo is visible.

## Rewards

| Signal | Condition | Reward |
|---|---|---|
| Reaction | positive emoji from the addressed user on a bound reply | +1 |
| Reaction | negative emoji from the addressed user on a bound reply | −1 |
| Reaction | any other emoji, custom emoji, another user, the bot | none (sample kept) |
| Reply deleted | bound reply deleted, by anyone | −1.5 |
| Moderation confirmed | target's sample with strategy answer or clarify | −1 |
| Moderation confirmed | target's sample with strategy refuse | +1 |
| Moderation confirmed | target's sample with strategy retrieve | none (sample kept) |
| Moderation cancelled | any | none |

Emoji tables live in `ReactionReward` (slice 1): positive 👍 ❤️ ❤ 🔥 🎉 ✅ 💯 🙏,
negative 👎 ❌ 😕 😡 🙄.

## Bounds

- Staged and bound tables: 512 entries each, 24-hour lifetime. On a full insert, expired
  entries are pruned first, then the oldest is evicted.
- One moderation confirmation pays out at most 20 samples, newest first, and only
  samples younger than 24 hours.
- Non-Discord ingest (HTTP, social envelopes) stages samples that are never bound; they
  age out under the same bounds.

## Error handling

Every path fails closed, producing no reward rather than an invented one: unknown or
expired ids, no matching samples for a moderated user, a disabled switch. Malformed samples are still
rejected by `DQNAgent.remember`'s validity check. No new path writes to Discord, so there
is no partial-failure state. A moderation confirmation while Discord is disconnected
still applies; it needs only the ledger and the agent.

Known upstream limitation: DiscordBM 1.16.2 decodes `MessageReactionAdd.member` as
required, and Discord omits it for DM reactions, so DM reactions fail to decode inside
DiscordBM and never reach Abbey. Report upstream; do not work around it here.

## Testing

Swift Testing, `Tests/AbbeyCoreTests/DelayedRewardLedgerTests.swift` plus a desktop test.

- Slice 1 (done): emoji table; addressed-user reaction yields one terminal sample, then
  nothing; unknown reply, other user and bot ignored; neutral emoji keeps the sample;
  expiry at stage and at reward; bind without stage; capacity eviction; a decoded
  gateway payload trains a `DQNAgent` exactly once.
- Slice 2: config parsing (unset → on; `0`/`false`/`no`/`off` → off; other → on);
  disabled ledger stages nothing and every signal returns nothing.
- Slice 3: deleting a bound reply yields −1.5 once; unknown reply ignored; reaction
  after deletion and deletion after reaction both yield nothing; a decoded
  MESSAGE_DELETE payload trains the agent once.
- Slice 4: a target with answer, refuse and retrieve samples yields −1 and +1 and keeps
  retrieve; other users and other guilds untouched; 20-sample cap; 24-hour cutoff;
  desktop test (`AbbeyEngineModerationRewardTests`) that a confirmed kick through the
  real `ConfirmationGate` consumes the sample and grows the agent's buffer, and a
  cancelled one does neither.

Gate for every slice: `unset TOOLCHAINS; bash Scripts/verify-all.sh`, exit code read
from the log.

## Live evidence

Recorded in `tasks/todo.md`. Needs a bot token and a private test guild from Donald.
Until every step passes, docs say "unit-tested, not live-proven".

1. Send a message; Abbey replies.
2. React 👍 as the author; replay buffer count in `/status` rises by exactly 1.
3. On a second reply, delete it; count rises by 1 and the journal shows −1.5.
4. From the desktop app, kick a throwaway account Abbey answered; on confirm the
   journal shows −1; on cancel it shows nothing.
5. Set `ABBEY_DELAYED_REWARDS=0`, restart, repeat step 2; nothing is added.

## Slices

1. Reaction rewards (implemented on `codex/reaction-reward-learning-20260916`).
2. `ABBEY_DELAYED_REWARDS` switch, applied to slice 1.
3. Reply-deletion signal.
4. Moderation-confirmation signal and author index.

Slices 1 and 2 are separate commits; slices 3 and 4 share one commit because both
extend the same ledger file. All on the same `codex/*` branch and one pull request, per
the repository's review-branch rule. Merging is Donald's call.

## Test isolation

`AbbeyEngine` builds its `DQNAgent` against the real `~/.abbey` checkpoint and experience
store. Its init now accepts an injected agent, and the desktop moderation tests pass an
in-memory one, so they neither read nor append to the operator's learning history.
(Found when the first draft of that test appended one synthetic sample to
`~/.abbey/dqn-experience.jsonl`; the line was removed.) Other existing suites still
write under `~/.abbey` during `verify-all`; that pre-dates this work and is tracked
separately.
