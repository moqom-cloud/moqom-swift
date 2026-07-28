// The extension's entry point.
//
// A widget extension rather than anything in the app: a Live Activity's UI is
// rendered out of process, by the system, while the app is suspended or not
// running at all. That is why `BroadcastActivityWidget` can only read
// `context.state` and cannot reach into `RoomModel` — there is no room in this
// process, and the 4 KB of state ActivityKit carries across is the whole of what
// the card knows.

import SwiftUI
import WidgetKit

@main
struct MoqomRoomWidgets: WidgetBundle {
    var body: some Widget {
        BroadcastActivityWidget()
    }
}
