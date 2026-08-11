// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import PreferencePanes
import SwiftUI
import WacomdriUI

/// Hosts the preferences UI inside System Settings.
///
/// Same views as the standalone app — only the container differs. macOS loads
/// third-party panes into a helper process rather than System Settings itself,
/// so this runs out of process and cannot take the whole settings app down with
/// it.
///
/// The Objective-C name is pinned because `NSPrincipalClass` in Info.plist is
/// resolved through the Objective-C runtime; without it Swift would mangle the
/// name and macOS would fail to find the class.
@objc(WacomdriPrefPane)
public final class WacomdriPrefPane: NSPreferencePane {
    private var model: PreferencesModel?

    public override func mainViewDidLoad() {
        super.mainViewDidLoad()

        let model = MainActor.assumeIsolated { PreferencesModel() }
        self.model = model

        let hosting = NSHostingView(rootView: PreferencesWindow(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        mainView.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: mainView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: mainView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
        ])
    }

    /// Polling for live tablet state only runs while the pane is on screen —
    /// there is no reason to keep an XPC conversation going with the agent once
    /// the user has moved on to another settings page.
    public override func didSelect() {
        MainActor.assumeIsolated { model?.start() }
    }

    public override func didUnselect() {
        MainActor.assumeIsolated { model?.stop() }
    }
}
