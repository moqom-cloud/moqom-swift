// A scrolling feed of live rooms.
//
// What makes a feed feel live is that the next room is already playing when it
// slides in. That means the rooms either side of the one on screen are joined,
// subscribed and decoding before anyone looks at them, at a size that costs
// little, and that the picture they are drawing can be shown in the card and in
// the full room at once without a second decode or a wait for a keyframe.
//
// So each room in the window gets one ``VideoRenderer`` with
// ``VideoRenderer/mirrorsInstantly`` on. The card shows its layer; the room view
// takes a presenter; both draw the same decoded IOSurface.
//
// Preloaded rooms are joined relay-only. Scrolling past a room must never tell
// the people in it this device's IP address, and a viewer has no direct path to
// offer anyway.

import Foundation
import MoqomCore

#if canImport(AVFoundation) && canImport(VideoToolbox)

    /// Keeps the rooms next to the one on screen joined and playing.
    ///
    /// ```swift
    /// let feed = RoomFeed(session: session, rooms: rooms)
    /// feed.focus(on: 0)
    /// // In a card: feed.entry(for: room)?.renderer.layer
    /// // On tap: let live = try await feed.open(room)
    /// ```
    ///
    /// Each preloaded room is a viewer session, metered like any other while it is open.
    @MainActor
    public final class RoomFeed {
        public struct Options: Sendable {
            /// Rooms after the focused one to keep playing.
            public var ahead = 1
            /// Rooms before the focused one to keep playing.
            public var behind = 1
            /// The focused room's host, drawn full screen.
            public var focused = RenderBox(width: 390, height: 844, scale: 3)
            /// Every other room in the window, which only needs to look right as it slides in.
            public var adjacent = RenderBox(width: 195, height: 422, scale: 2)

            public init() {}
        }

        /// One room in the window.
        @MainActor
        public final class Entry {
            public let room: RoomID
            /// Draws the room's top host. Put ``VideoRenderer/layer`` in the card, and take
            /// ``VideoRenderer/addPresenter()`` for anywhere else the same picture should be.
            public let renderer = VideoRenderer()
            public private(set) var session: RoomSession?
            /// Who is being drawn, once the room has someone on stage.
            public private(set) var host: ParticipantIdentity?

            fileprivate var box: RenderBox
            fileprivate var task: Task<Void, Never>?

            fileprivate init(room: RoomID, box: RenderBox) {
                self.room = room
                self.box = box
                renderer.mirrorsInstantly = true
            }

            fileprivate func start(in moqom: MoqomSession) {
                let room = room
                task = Task { [weak self] in
                    let session: RoomSession
                    do {
                        session = try await moqom.join(room: room, directPolicy: .relayOnly)
                    } catch {
                        return
                    }
                    guard let self, !Task.isCancelled else { return }
                    self.session = session
                    await self.play(session)
                }
            }

            fileprivate func resize(to box: RenderBox) {
                guard box != self.box else { return }
                self.box = box
                guard let session, let host else { return }
                Task { await session.updateLayout([host: box]) }
            }

            /// Draw the room's top host, following each new stream of their frames.
            private func play(_ session: RoomSession) async {
                while !Task.isCancelled {
                    guard let host = await firstOnStage(in: session) else { return }
                    self.host = host
                    await session.updateLayout([host: box])

                    var frames: AsyncStream<DepacketisedFrame>?
                    while frames == nil, !Task.isCancelled {
                        frames = await session.frames(from: host)
                        if frames == nil { try? await Task.sleep(for: .milliseconds(100)) }
                    }
                    guard let frames else { return }
                    if let codec = await session.codec(of: host) { renderer.setCodec(codec) }

                    for await frame in frames {
                        if Task.isCancelled { return }
                        try? renderer.enqueue(frame)
                    }
                    if !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                }
            }

            private func firstOnStage(in session: RoomSession) async -> ParticipantIdentity? {
                while !Task.isCancelled {
                    if let first = await session.galleryLayout.first?.identity { return first }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                return nil
            }

            fileprivate func stop() {
                task?.cancel()
                task = nil
                renderer.flush()
            }
        }

        private let moqom: MoqomSession
        public var options: Options
        public private(set) var rooms: [RoomID]
        private var entries: [RoomID: Entry] = [:]
        private var opened: Set<RoomID> = []
        private var focusIndex: Int?

        public init(session: MoqomSession, rooms: [RoomID], options: Options = Options()) {
            moqom = session
            self.rooms = rooms
            self.options = options
        }

        /// The room at `index` is on screen.
        ///
        /// Joins what the window now covers and leaves what it has moved well past: a room one
        /// step outside the window is kept, so scrolling back and forth over a boundary doesn't
        /// join and leave the same room each time.
        public func focus(on index: Int) {
            guard rooms.indices.contains(index) else { return }
            focusIndex = index
            let wanted = window(around: index, margin: 0)
            let kept = window(around: index, margin: 1)

            for (room, entry) in entries where !kept.contains(room) && !opened.contains(room) {
                drop(entry)
            }
            for (offset, room) in rooms.enumerated() where wanted.contains(room) {
                let box = offset == index ? options.focused : options.adjacent
                if let entry = entries[room] {
                    entry.resize(to: box)
                } else {
                    let entry = Entry(room: room, box: box)
                    entries[room] = entry
                    entry.start(in: moqom)
                }
            }
        }

        /// Replace the list, as when the feed loads more. The window is recomputed around the
        /// room that was focused, wherever it now is.
        public func setRooms(_ rooms: [RoomID]) {
            let current = focusIndex.flatMap { self.rooms.indices.contains($0) ? self.rooms[$0] : nil }
            self.rooms = rooms
            if let current, let index = rooms.firstIndex(of: current) {
                focus(on: index)
            } else if !rooms.isEmpty {
                focus(on: 0)
            }
        }

        /// The room's entry while it's in the window.
        public func entry(for room: RoomID) -> Entry? { entries[room] }

        /// Take a room out of the feed's hands, to show it in full.
        ///
        /// The feed stops leaving it when the window moves; the renderer keeps playing, so the
        /// room view can mirror it with no gap. Hand it back with ``release(_:)``.
        public func open(_ room: RoomID) async throws(MoqomError) -> RoomSession {
            opened.insert(room)
            if let session = entries[room]?.session { return session }
            return try await moqom.join(room: room, directPolicy: .relayOnly)
        }

        /// Give a room back to the feed, which leaves it if the window has moved on.
        public func release(_ room: RoomID) {
            opened.remove(room)
            if let focusIndex { focus(on: focusIndex) }
        }

        /// Leave every room the feed is holding, opened ones included.
        public func close() {
            for entry in entries.values { drop(entry) }
            let moqom = moqom
            for room in opened { Task { await moqom.leave(room: room) } }
            opened.removeAll()
            focusIndex = nil
        }

        private func window(around index: Int, margin: Int) -> Set<RoomID> {
            let low = max(0, index - options.behind - margin)
            let high = min(rooms.count - 1, index + options.ahead + margin)
            guard low <= high else { return [] }
            return Set(rooms[low ... high])
        }

        private func drop(_ entry: Entry) {
            entries[entry.room] = nil
            entry.stop()
            let moqom = moqom
            let room = entry.room
            Task { await moqom.leave(room: room) }
        }
    }
#endif
