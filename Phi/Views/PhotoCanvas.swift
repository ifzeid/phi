import SwiftUI
import UIKit

/// Full screen width. Height is `width / (width ÷ height)` even when the parent is shorter.
/// That keeps the photo the same size on the camera, the album, and the editor.
struct PhotoCanvas<Content: View>: View {
    var widthOverHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        FullWidthPhotoLayout(widthOverHeight: widthOverHeight) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .clipped()
    }
}

private struct FullWidthPhotoLayout: Layout {
    var widthOverHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 390
        let ratio = max(widthOverHeight, 0.01)
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = sizeThatFits(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews, cache: &cache)
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(width: size.width, height: size.height))
        }
    }
}

enum ScreenEdge {
    static var windowTop: CGFloat {
        let window = keyWindow
        let safe = window?.safeAreaInsets.top ?? 0
        return safe > 1 ? safe : 59
    }

    static var windowBottom: CGFloat {
        let window = keyWindow
        let safe = window?.safeAreaInsets.bottom ?? 0
        return safe > 1 ? safe : 34
    }

    private static var keyWindow: UIWindow? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    /// From the physical top to the first control. Clears the island, then the Figma 12pt, and drops the hidden status-bar row.
    static var topContent: CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        let safe = window?.safeAreaInsets.top ?? 0
        guard safe > 1 else { return 12 }
        let status = scene?.statusBarManager?.statusBarFrame.height ?? 0
        let statusPortion = status > 1 ? min(status, safe * 0.4) : 20
        return max(12, safe - statusPortion + 12)
    }
}

struct UnderIsland: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.top, ScreenEdge.topContent)
            .ignoresSafeArea(edges: .top)
    }
}

struct HiddenSystemChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .background(StatusBarHiddenController())
    }
}

/// Makes `prefersStatusBarHidden` true. The plist must allow view-controller status bar appearance.
struct StatusBarHiddenController: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.setNeedsStatusBarAppearanceUpdate()
    }

    final class Controller: UIViewController {
        override var prefersStatusBarHidden: Bool { true }
        override var prefersHomeIndicatorAutoHidden: Bool { true }
        override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
    }
}
