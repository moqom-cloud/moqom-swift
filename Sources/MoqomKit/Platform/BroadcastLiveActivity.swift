// The ActivityKit half of a broadcast's Live Activity.
//
// Everything interesting about the policy is in ``BroadcastActivityThrottle``,
// which has no framework in it and can be tested. What is left here is the
// framework, plus the two pieces of plumbing that are easy to get wrong:
//
//   - The push token is an `AsyncSequence`, not a property. Reading
//     `activity.pushToken` after starting returns `nil` every time — the token
//     has not been minted yet — and the token rotates during the activity, so
//     an app that reads it once ends up with a control plane pushing to a dead
//     token and no error anywhere to explain the silence.
//   - An owed update has to actually arrive. When the throttle says to wait,
//     something has to come back later and apply the state, or a room where the
//     speaker changes once and then goes quiet shows the wrong name until it
//     ends.
//
// The card's own lifetime is not ours to control: the system runs a Live
// Activity for eight hours and then holds it stale for four more. A broadcast
// longer than that loses its card, and there is no API to renew one — the only
// remedy is to end it and request another, which the application must decide to
// do because it is a new entry in Notification Centre.

import Foundation
import MoqomCore

// `os(iOS)` rather than `canImport(ActivityKit)`: the module imports on macOS
// and every type in it is annotated unavailable there, so the weaker check
// compiles into a wall of availability errors rather than into nothing.
#if os(iOS)
    import ActivityKit

    /// A broadcast, as Notification Centre and the Dynamic Island see it.
    ///
    /// The static half. Everything here is fixed for the life of the card, so
    /// changing a room's title mid-broadcast means ending the activity and
    /// starting another — which is the correct behaviour, since the card is a
    /// notification and a notification that rewrote its own subject would be
    /// indistinguishable from a different one.
    ///
    /// > Note: A widget extension needs this exact type, which means importing
    /// > `MoqomKit` from the extension target. Declaring a matching type by hand
    /// > does not work: ActivityKit keys the activity on the type's identity,
    /// > and two structurally identical declarations in two modules are two
    /// > types, so the extension renders nothing and reports nothing.
    public struct MoqomBroadcastAttributes: ActivityAttributes {
        public typealias ContentState = BroadcastActivityState

        /// What to call the broadcast on the Lock Screen.
        public let title: String

        /// Who is running it, as a display name.
        public let host: String

        /// The room, so a tap can deep-link back into it.
        public let room: RoomID

        public init(title: String, host: String, room: RoomID) {
            self.title = title
            self.host = host
            self.room = room
        }
    }

    /// Starts, updates and ends the Live Activity for one broadcast.
    ///
    /// ```swift
    /// let card = BroadcastLiveActivity(logger: room.logger)
    /// try card.start(
    ///     MoqomBroadcastAttributes(title: "Launch day", host: "ana", room: room.room),
    ///     state: BroadcastActivityState(startedAt: .now)
    /// )
    /// card.follow(room)
    /// ```
    ///
    /// Updating is cheap to call. Everything is filtered through the throttle,
    /// so driving this from a per-second statistics sample — or from every room
    /// event — costs an ActivityKit update only when the card would change.
    @MainActor
    public final class BroadcastLiveActivity {
        /// Whether the user has left Live Activities on for this app.
        ///
        /// Per-app and revocable from Settings, so worth checking before
        /// building a card rather than treating a failure to start as a bug.
        public static var isPermitted: Bool {
            ActivityAuthorizationInfo().areActivitiesEnabled
        }

        /// Whether the app may push updates faster than the ordinary budget.
        ///
        /// Governed by `NSSupportsLiveActivitiesFrequentUpdates` in the app's
        /// Info.plist *and* by a user setting, which is why it is read at
        /// runtime rather than assumed from the build. A control plane pushing
        /// updates should be told this value, because the alternative is
        /// discovering the budget by exhausting it.
        public static var allowsFrequentUpdates: Bool {
            ActivityAuthorizationInfo().frequentPushesEnabled
        }

        /// Push tokens for this activity, as they are minted and rotated.
        ///
        /// Send each one to the control plane and retire the previous one.
        /// Empty unless the activity was started with `pushUpdates` on.
        public nonisolated var pushTokens: AsyncStream<Data> { tokenStream }

        /// The card's current contents, or `nil` if there is no card.
        public var showing: BroadcastActivityState? { throttle.showing }

        public var isRunning: Bool { activity != nil }

        private var activity: Activity<MoqomBroadcastAttributes>?
        private var throttle: BroadcastActivityThrottle
        private var owed: Task<Void, Never>?
        private var tokens: Task<Void, Never>?
        private let logger: MoqomLogger
        private nonisolated let tokenStream: AsyncStream<Data>
        private nonisolated let tokenContinuation: AsyncStream<Data>.Continuation

        public init(
            throttle: BroadcastActivityThrottle = BroadcastActivityThrottle(),
            logger: MoqomLogger = .silent
        ) {
            self.throttle = throttle
            self.logger = logger
            (tokenStream, tokenContinuation) = AsyncStream.makeStream(
                of: Data.self,
                bufferingPolicy: .bufferingNewest(1)
            )
        }

        deinit {
            owed?.cancel()
            tokens?.cancel()
            tokenContinuation.finish()
        }

        /// Put a card on the Lock Screen.
        ///
        /// - Parameter pushUpdates: Ask for a push token so the control plane
        ///   can update the card while the app is suspended. Worth it for a
        ///   viewer, who may put the phone down for an hour; unnecessary for a
        ///   broadcaster, whose app stays alive for as long as it is capturing.
        public func start(
            _ attributes: MoqomBroadcastAttributes,
            state: BroadcastActivityState,
            pushUpdates: Bool = false
        ) throws(MoqomError) {
            guard Self.isPermitted else {
                throw MoqomError.invalidState(
                    expected: "live activities permitted",
                    actual: "turned off for this app"
                )
            }
            guard activity == nil else {
                throw MoqomError.invalidState(expected: "no live activity", actual: "running")
            }

            do {
                let started = try Activity.request(
                    attributes: attributes,
                    content: content(for: state),
                    pushType: pushUpdates ? .token : nil
                )
                activity = started
                _ = throttle.consider(state, at: Self.now())
                logger.info(.room, "live activity started", [
                    LogField("activity", .text(started.id)),
                    LogField("push", .flag(pushUpdates)),
                ])
                if pushUpdates { observeTokens(of: started) }
            } catch {
                // `ActivityKit` throws `ActivityAuthorizationError`, whose cases
                // are about the user's settings and the system's limits rather
                // than about the room, so the detail belongs in the log and the
                // error the caller sees is simply that there is no card.
                logger.error(.room, "live activity refused", [
                    LogField("reason", .text(String(describing: error))),
                ])
                throw MoqomError.invalidState(
                    expected: "live activity started",
                    actual: "refused by ActivityKit"
                )
            }
        }

        /// Offer the card a new state.
        ///
        /// - Returns: Whether it went out now. `false` covers both "nothing
        ///   changed" and "scheduled for when the interval is up", which a
        ///   caller driving this from a timer does not need to tell apart.
        @discardableResult
        public func update(_ state: BroadcastActivityState) -> Bool {
            guard let activity else { return false }

            switch throttle.consider(state, at: Self.now()) {
            case .skip:
                return false

            case let .wait(delay):
                // Replaces any previously owed update rather than queueing
                // behind it. The card shows one thing, so the only update worth
                // keeping is the newest.
                owed?.cancel()
                owed = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                    self?.update(state)
                }
                return false

            case .send:
                owed?.cancel()
                owed = nil
                let content = content(for: state)
                Task { await activity.update(content) }
                return true
            }
        }

        /// Take the card down.
        ///
        /// - Parameter lingering: How long the final state stays visible.
        ///   A stream that ended deliberately should linger long enough to be
        ///   read; one the user themselves ended should not, because they
        ///   already know.
        public func end(
            _ state: BroadcastActivityState? = nil,
            lingering: Duration = .seconds(30)
        ) {
            guard let activity else { return }
            self.activity = nil
            owed?.cancel()
            owed = nil
            tokens?.cancel()
            tokens = nil

            var closing: ActivityContent<BroadcastActivityState>?
            if var final = state ?? throttle.showing {
                final.phase = .ended
                closing = content(for: final)
            }
            let dismissal = ActivityUIDismissalPolicy.after(.now + lingering.timeInterval)

            logger.info(.room, "live activity ended", [
                LogField("activity", .text(activity.id)),
            ])
            Task { await activity.end(closing, dismissalPolicy: dismissal) }
        }

        /// Take down every card this app has, including ones it no longer holds.
        ///
        /// ``end(_:lingering:)`` can only end the activity this instance started, and that
        /// is not the card most likely to be stuck. A Live Activity outlives the process
        /// that requested it — that is the feature — so a force quit, a crash, or a
        /// termination in the background leaves a card saying "live" with nothing left
        /// alive to update or end it, and the system will keep showing it for eight hours.
        /// Nothing in the new process holds a reference to it, so nothing can clean it up
        /// through the instance API.
        ///
        /// Worth calling before starting a card as well as from a control the user can
        /// reach: without it, a relaunch after a crash adds a second entry to Notification
        /// Centre rather than replacing the stale one.
        ///
        /// - Parameter lingering: How long the ended cards stay visible. Zero by default,
        ///   unlike ``end(_:lingering:)``: these are cards whose broadcast is already over,
        ///   and holding a final state to be read would be inventing a moment that has
        ///   passed.
        public static func endAll(lingering: Duration = .zero) async {
            let dismissal: ActivityUIDismissalPolicy = lingering == .zero
                ? .immediate
                : .after(.now + lingering.timeInterval)

            // Snapshotted rather than iterated live: ending an activity mutates the
            // collection this is walking.
            for activity in Array(Activity<MoqomBroadcastAttributes>.activities) {
                await activity.end(nil, dismissalPolicy: dismissal)
            }
        }

        /// Keep the card in step with a room, until the room ends.
        ///
        /// Driven from the statistics stream rather than from room events
        /// because everything the card draws is in a snapshot — the count, the
        /// quality, the lifecycle — and sampling one place keeps the card from
        /// showing a participant count from one instant beside a signal bar
        /// from another.
        ///
        /// - Returns: A task the caller may cancel. It also ends on its own when
        ///   the room does.
        @discardableResult
        public func follow(
            _ room: RoomSession,
            sampling interval: Duration = .seconds(1),
            speaker: @escaping @Sendable (ParticipantIdentity) -> String = { $0.username.value }
        ) -> Task<Void, Never> {
            Task { [weak self] in
                let me = room.identity
                for await snapshot in await room.statistics(every: interval) {
                    guard let self else { return }
                    let talking = await room.galleryLayout.first(where: \.isSpeaking)?.identity

                    // Read from the roster rather than from the publication.
                    // A muted broadcaster is still publishing — they are
                    // sending silence, and the audio track stays up so the
                    // unmute is instant — so "has an audio publication" and
                    // "can be heard" are different questions, and only the
                    // second one belongs on a Lock Screen.
                    let mine = await room.roster[me]
                    let muted = mine?.mute.selfMuted
                    let broadcasting = snapshot.publishing.isPublishing

                    let state = BroadcastActivityState(
                        phase: Self.phase(of: snapshot.lifecycle),
                        startedAt: Date.now - snapshot.uptime.timeInterval,
                        participants: snapshot.participantCount,
                        speaker: talking.map(speaker),
                        isRecording: await room.currentState.isRecording,
                        quality: snapshot.quality,
                        isMuted: broadcasting ? muted?.contains(.audio) ?? false : nil,
                        isCameraOff: broadcasting ? muted?.contains(.video) ?? false : nil
                    )

                    if state.phase == .ended {
                        end(state)
                        return
                    }
                    update(state)
                }
            }
        }

        private func content(
            for state: BroadcastActivityState
        ) -> ActivityContent<BroadcastActivityState> {
            ActivityContent(
                state: state,
                staleDate: .now + throttle.staleAfter.timeInterval,
                // Nudges this card above other apps' when several are competing
                // for the Dynamic Island, and only then; it does nothing when
                // ours is the only one. A live broadcast genuinely is more
                // time-critical than most of what shares that space.
                relevanceScore: state.phase == .live ? 100 : 50
            )
        }

        private func observeTokens(of activity: Activity<MoqomBroadcastAttributes>) {
            tokens = Task { [tokenContinuation, logger] in
                for await token in activity.pushTokenUpdates {
                    guard !Task.isCancelled else { return }
                    logger.debug(.room, "live activity push token rotated", [
                        LogField("bytes", .number(token.count)),
                    ])
                    tokenContinuation.yield(Data(token))
                }
            }
        }

        private static func now() -> MonotonicTime {
            .nanoseconds(DispatchTime.now().uptimeNanoseconds)
        }

        private static func phase(of lifecycle: RoomLifecycle) -> BroadcastActivityState.Phase {
            switch lifecycle {
            case .ended: .ended
            case .scheduled, .live, .actingHost: .live
            }
        }
    }

    private extension Duration {
        /// Seconds as a `TimeInterval`, for the two ActivityKit parameters that
        /// take wall-clock dates.
        var timeInterval: TimeInterval {
            let (seconds, attoseconds) = components
            return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
        }
    }
#endif
