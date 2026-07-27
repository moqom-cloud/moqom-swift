import Foundation
import Testing

@testable import MoqomKit

@Suite("Session lifecycle")
struct SessionStateMachineTests {
    private func connected() -> SessionStateMachine {
        var machine = SessionStateMachine()
        machine.handle(.connectRequested(at: .zero))
        machine.handle(.connected(at: .zero))
        return machine
    }

    @Test("a thirty-second tunnel is a glitch, not an exit")
    func transientBlipIsInvisible() {
        var machine = connected()
        machine.handle(.transportLost(at: .seconds(10)))
        machine.handle(.tick(at: .seconds(40)))

        #expect(machine.state == .reconnecting(since: .seconds(10)))

        machine.handle(.connected(at: .seconds(41)))
        #expect(machine.state == .established)
    }

    @Test("resumption starts a new group, because the gap lost frames")
    func resumptionStartsANewGroup() {
        var machine = connected()
        machine.handle(.transportLost(at: .seconds(1)))
        let effects = machine.handle(.connected(at: .seconds(5)))

        #expect(effects.contains(.startNewGroup))
        #expect(effects.contains(.publishPresence(.connected)))
    }

    @Test("a long absence becomes away, and the slot is still held")
    func extendedAbsenceBecomesAway() {
        var machine = connected()
        machine.handle(.transportLost(at: .seconds(10)))
        let effects = machine.handle(.tick(at: .seconds(100)))

        #expect(machine.state == .away(since: .seconds(10)))
        #expect(effects == [.publishPresence(.away)])
    }

    @Test("only past the away window does the session actually end")
    func awayWindowEventuallyCloses() {
        var machine = connected()
        machine.handle(.transportLost(at: .zero))
        machine.handle(.tick(at: .seconds(91)))
        #expect(machine.state == .away(since: .zero))

        let effects = machine.handle(.tick(at: .seconds(241)))
        #expect(machine.state == .closed(.networkFailure))
        #expect(effects.contains(.deliverTerminal(.networkFailure)))
    }

    @Test("a failed retry does not reset the clock that decides away")
    func retriesDoNotResetTheClock() {
        // A flapping link produces a transport loss on every attempt. If each
        // one restarted the window, the session would never resolve to away and
        // the participant would sit in "reconnecting" indefinitely.
        var machine = connected()
        machine.handle(.transportLost(at: .seconds(0)))
        for second in stride(from: 10, through: 80, by: 10) {
            machine.handle(.transportLost(at: .seconds(second)))
        }
        machine.handle(.tick(at: .seconds(91)))

        #expect(machine.state == .away(since: .zero))
    }

    @Test("backoff grows and is capped")
    func backoffIsBounded() {
        var machine = connected()
        machine.handle(.transportLost(at: .zero))
        let first = machine.currentBackoff
        for attempt in 1 ... 12 {
            machine.handle(.transportLost(at: .seconds(attempt)))
        }

        #expect(first == .milliseconds(250))
        #expect(machine.currentBackoff == machine.policy.maximumBackoff)
    }

    @Test("backgrounding is published without ending anything")
    func backgroundingIsItsOwnState() {
        // iOS suspends networking shortly after backgrounding, so a host
        // checking a message otherwise looks exactly like a host whose phone
        // died. The room needs to be able to tell.
        var machine = connected()
        let effects = machine.handle(.appBackgrounded(at: .seconds(1)))

        #expect(machine.state == .established)
        #expect(effects == [.publishPresence(.backgrounded)])
    }

    @Test("a participant who backgrounded and then dropped reads as backgrounded")
    func backgroundedThenLost() {
        var machine = connected()
        machine.handle(.appBackgrounded(at: .seconds(1)))
        machine.handle(.transportLost(at: .seconds(2)))
        let effects = machine.handle(.tick(at: .seconds(100)))

        #expect(effects == [.publishPresence(.backgrounded)])
    }

    @Test("the four terminal states stay distinguishable")
    func terminalStatesAreDistinct() {
        let reasons: [TerminalEvent] = [
            .moderated(.adultContent), .hostEnded, .networkFailure, .tokenExpired,
        ]
        for event in reasons {
            var machine = connected()
            machine.handle(.terminated(event, at: .zero))
            #expect(machine.state == .closed(event))
        }

        #expect(TerminalEvent.networkFailure.isRetryable)
        #expect(!TerminalEvent.hostEnded.isRetryable)
        #expect(!TerminalEvent.tokenExpired.isRetryable)
        #expect(!TerminalEvent.moderated(.harassment).isRetryable)
    }

    @Test("nothing happens after close")
    func closedIsTerminal() {
        var machine = connected()
        machine.handle(.terminated(.hostEnded, at: .zero))
        let effects = machine.handle(.transportLost(at: .seconds(1)))

        #expect(effects.isEmpty)
        #expect(machine.state == .closed(.hostEnded))
    }

    @Test("a moderated termination carries a payload the SDK never parses")
    func moderationCarriesTenantPayload() {
        let payload = Data("appeal-id=42".utf8)
        let event = TerminalEvent.moderated(.tenantPolicy, tenantPayload: payload)

        #expect(event.tenantPayload == payload)
        #expect(event.localizationKey == "moqom.terminal.moderated.tenantPolicy")
        #expect(!event.defaultDisplayString.isEmpty)
    }
}
