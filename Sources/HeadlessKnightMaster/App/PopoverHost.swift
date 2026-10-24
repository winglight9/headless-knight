import AppKit
import Combine
import SwiftUI

/// The only window in the product: one popover pinned to the status item.
@MainActor
final class PopoverHost: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let hosting: NSHostingController<AnyView>
    private var cancellables: Set<AnyCancellable> = []

    static let contentWidth: CGFloat = 300

    init(state: AppState) {
        hosting = NSHostingController(rootView: AnyView(RootView().environmentObject(state)))
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        hosting.view.frame = NSRect(x: 0, y: 0, width: PopoverHost.contentWidth, height: 220)

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.resize()
                }
            }
            .store(in: &cancellables)
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        resize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        resize()
        popover.contentViewController?.view.window?.makeKey()
    }

    func hide() {
        popover.performClose(nil)
    }

    private func resize() {
        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        let fitting = view.fittingSize
        let height = max(120, ceil(fitting.height))
        if abs(popover.contentSize.height - height) > 0.5 || popover.contentSize.width != PopoverHost.contentWidth {
            popover.contentSize = NSSize(width: PopoverHost.contentWidth, height: height)
        }
        if abs(view.frame.height - height) > 0.5 {
            view.setFrameSize(NSSize(width: PopoverHost.contentWidth, height: height))
        }
    }
}
