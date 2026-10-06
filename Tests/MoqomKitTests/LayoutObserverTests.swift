import Foundation
import Testing

@testable import MoqomCore
@testable import MoqomKit

#if canImport(SwiftUI)
    @MainActor
    struct LayoutObserverTests {
        private func box(_ width: Double) -> RenderBox {
            RenderBox(width: width, height: width * 16 / 9, scale: 3)
        }

        @Test("a replaced tile's withdrawal does not delete its replacement's box")
        func aSupersededWithdrawalIsIgnored() {
            // What a layout change looks like from here. SwiftUI builds the new tile before it
            // takes the old one away, so the two arrive in this order — and unconditionally
            // honouring the second one deleted a box that was on screen. The planner was then
            // told the participant was not being drawn, unsubscribed, and never heard
            // otherwise, because the surviving tile's geometry had not changed since its first
            // report. Measured on two phones: the picture stopped the instant the stage was
            // switched, with every counter on both devices reading healthy.
            let observer = LayoutObserver()
            let who = identity("alice")
            let old = UUID()
            let new = UUID()

            observer.report(box(200), for: who, from: old)
            observer.report(box(320), for: who, from: new)
            observer.withdraw(who, from: old)

            #expect(observer.current[who] == box(320))
        }

        @Test("a tile that leaves without a replacement is withdrawn")
        func anUnsupersededWithdrawalStands() {
            // The other half, and the reason this is a token rather than simply never
            // withdrawing: a participant whose tile is gone must stop being subscribed to, or
            // a gallery that drops somebody keeps paying for their video indefinitely.
            let observer = LayoutObserver()
            let who = identity("alice")
            let only = UUID()

            observer.report(box(200), for: who, from: only)
            observer.withdraw(who, from: only)

            #expect(observer.current[who] == nil)
        }

        @Test("one host drawn twice is subscribed for the larger view")
        func theBiggestBoxWins() {
            // The same person in a gallery tile and on the stage at once. A rung chosen for the
            // 320pt view serves the 100pt one by downscaling; the other way round fills the
            // stage with a thumbnail, which is the whole reason size is reported at all.
            let observer = LayoutObserver()
            let who = identity("alice")

            observer.report(box(100), for: who, from: UUID())
            observer.report(box(320), for: who, from: UUID())

            #expect(observer.current[who] == box(320))
            #expect(observer.reportCount[who] == 2)
        }

        @Test("losing the larger view leaves the smaller one still drawn")
        func theSurvivorKeepsTheSubscription() {
            // Closing the stage must not unsubscribe somebody still visible in the gallery, and
            // it must drop to the rung the gallery actually needs rather than keeping the
            // stage's. Order matters here: the box that goes is the one that was being served.
            let observer = LayoutObserver()
            let who = identity("alice")
            let tile = UUID()
            let stage = UUID()

            observer.report(box(100), for: who, from: tile)
            observer.report(box(320), for: who, from: stage)
            observer.withdraw(who, from: stage)

            #expect(observer.current[who] == box(100))
        }

        @Test("a host nobody can see is not kept alive by a large stale box")
        func visibilityOutranksSize() {
            // A view scrolled out of a list keeps the size it had, so comparing area alone
            // would let a big box nobody is looking at outrank a small one somebody is. The
            // planner drops video for anything not visible, so getting this backwards spends a
            // large rung on a tile that is not on screen.
            let observer = LayoutObserver()
            let who = identity("alice")
            let scrolledAway = RenderBox(
                width: 320, height: 569, scale: 3, visibility: .offScreen
            )

            observer.report(scrolledAway, for: who, from: UUID())
            observer.report(box(100), for: who, from: UUID())

            #expect(observer.current[who] == box(100))
        }

        @Test("the last view to leave stops the subscription")
        func theLastWithdrawalStands() {
            // Two views and two withdrawals. The participant survives the first, because
            // somebody is still drawing them, and goes on the second — otherwise a gallery that
            // once showed somebody twice pays for their video for the rest of the call.
            let observer = LayoutObserver()
            let who = identity("alice")
            let tile = UUID()
            let stage = UUID()

            observer.report(box(100), for: who, from: tile)
            observer.report(box(320), for: who, from: stage)

            observer.withdraw(who, from: tile)
            #expect(observer.current[who] == box(320))

            observer.withdraw(who, from: stage)
            #expect(observer.current[who] == nil)
        }

        @Test("a caller with no token still withdraws")
        func anUntokenedWithdrawalStands() {
            // The public API predates the token and is used by callers that own the whole
            // layout — Picture in Picture hands over a complete set — so it keeps its meaning.
            let observer = LayoutObserver()
            let who = identity("alice")

            observer.report(box(200), for: who, from: UUID())
            observer.withdraw(who)

            #expect(observer.current[who] == nil)
        }
    }
#endif
