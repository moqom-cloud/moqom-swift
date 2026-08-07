import Foundation
import Testing

@testable import MoqomKit

@Suite("Lip sync")
struct LipSyncTests {
    private let bounds = (floor: Duration.zero, ceiling: Duration.milliseconds(500))

    @Test("A voice within the lead allowance asks nothing of the picture")
    func aShallowVoiceCostsNothing() {
        #expect(LipSync.floor(voice: .zero, bounds: bounds) == .zero)
        #expect(LipSync.floor(voice: .milliseconds(30), bounds: bounds) == .zero)
        #expect(LipSync.floor(voice: LipSync.pictureMayLead, bounds: bounds) == .zero)
    }

    @Test("Past the allowance the picture follows the voice, less the allowance")
    func aDeepVoiceDragsThePictureWithIt() {
        #expect(LipSync.floor(voice: .milliseconds(109), bounds: bounds) == .milliseconds(49))
        #expect(LipSync.floor(voice: .milliseconds(200), bounds: bounds) == .milliseconds(140))
    }

    /// The measurement that prompted this: a leg holding 109ms of voice was making its picture
    /// wait the same 109ms, and the picture's own arrivals only ever needed about 21ms.
    @Test("The measured call would have been sixty milliseconds faster")
    func theMeasuredCall() {
        let was = Duration.milliseconds(109)
        let now = LipSync.floor(voice: was, bounds: bounds)
        #expect(was - now == LipSync.pictureMayLead)
    }

    @Test("The application's own floor is never undercut")
    func theApplicationsFloorHolds() {
        let asked = (floor: Duration.milliseconds(80), ceiling: Duration.milliseconds(500))
        #expect(LipSync.floor(voice: .zero, bounds: asked) == .milliseconds(80))
        #expect(LipSync.floor(voice: .milliseconds(100), bounds: asked) == .milliseconds(80))
        #expect(LipSync.floor(voice: .milliseconds(300), bounds: asked) == .milliseconds(240))
    }

    /// A voice buffer this deep means the link is in trouble. Following it would put the same
    /// half second on the picture, so the two are allowed to come apart instead.
    @Test("A voice in trouble does not drag the picture past the ceiling")
    func theCeilingHolds() {
        #expect(LipSync.floor(voice: .seconds(2), bounds: bounds) == .milliseconds(500))
    }

    @Test("The floor only ever rises with the voice")
    func itIsMonotonic() {
        var last = Duration.zero
        for ms in stride(from: 0, through: 600, by: 10) {
            let floor = LipSync.floor(voice: .milliseconds(ms), bounds: bounds)
            #expect(floor >= last)
            last = floor
        }
    }

    /// The asymmetry is the point. The picture may be shown ahead of the voice, and is never
    /// asked to wait longer than the voice does.
    ///
    /// The lead stays within the allowance while the ceiling is not in play. Past it the two are
    /// meant to come apart — see ``theCeilingHolds`` — so the allowance no longer describes them.
    @Test("The picture leads and never lags")
    func onlyOneDirection() {
        for ms in stride(from: 0, through: 600, by: 10) {
            let voice = Duration.milliseconds(ms)
            let floor = LipSync.floor(voice: voice, bounds: bounds)
            #expect(floor <= voice)
            if floor < bounds.ceiling {
                #expect(voice - floor <= LipSync.pictureMayLead)
            }
        }
    }
}
