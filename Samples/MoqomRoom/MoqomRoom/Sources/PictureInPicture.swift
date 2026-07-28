// Handing the SDK a source view, and each tile's renderer.
//
// Two pieces of glue, both of which exist because SwiftUI does not hand out
// `UIView`s and Picture in Picture needs two of them.
//
// The first is the source view. The system reads its frame and its visibility to
// decide whether to start the window automatically when the app is backgrounded,
// and it flies the window out of that rectangle and back into it. So it has to
// be the video, not a wrapper: a source view that resolves to nothing produces a
// feature that never triggers, with no error to say why.
//
// The second is the renderers. The SDK borrows the layer a tile is already
// drawing into rather than building a second one, because a second layer means a
// second hardware decode of a subscription that already exists. Only the tile
// knows when its renderer appears and goes away, so the tile is what registers.

import AVFoundation
import MoqomCore
import MoqomKit
import SwiftUI

#if os(iOS)
    /// Reports its own `UIView` to the room's Picture in Picture controller.
    ///
    /// Used as a `.background`, so it resolves to exactly the gallery's frame
    /// without drawing anything or intercepting a touch.
    struct PictureInPictureSource: UIViewRepresentable {
        let room: RoomModel

        func makeUIView(context _: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            room.pictureInPicture?.source = view
            return view
        }

        func updateUIView(_ view: UIView, context _: Context) {
            // Re-stated on update because the controller holds it weakly and a
            // navigation pop and push builds a new one.
            room.pictureInPicture?.source = view
        }
    }

    extension View {
        /// Fly the Picture in Picture window out of this view.
        func moqomPictureInPictureSource(_ room: RoomModel) -> some View {
            background { PictureInPictureSource(room: room) }
        }
    }
#else
    extension View {
        func moqomPictureInPictureSource(_: RoomModel) -> some View { self }
    }
#endif

/// The casts the sample offers, and what each one is for.
///
/// A sample's job here is to show that the choice exists and that it composes.
/// The SDK's ``PictureInPictureCast`` is a rule rather than a list, so these
/// five are five expressions of that rule and not five code paths.
enum CastChoice: String, CaseIterable, Identifiable, Sendable {
    case everyone = "Everyone"
    case host = "Host only"
    case guests = "Cohosts and guests"
    case speaker = "Whoever is talking"

    var id: String { rawValue }

    var cast: PictureInPictureCast {
        switch self {
        case .everyone: .stage
        case .host: .host
        case .guests: .cohostsAndGuests
        case .speaker: .speaker
        }
    }
}
