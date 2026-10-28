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
