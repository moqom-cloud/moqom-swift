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
