import AVFoundation
import SwiftUI
import UIKit

/// Native system menu. On iOS 26 and later this is the Liquid Glass menu: text rows and a check, no icons.
struct FlashSystemMenu: UIViewRepresentable {
    var mode: AVCaptureDevice.FlashMode
    var glyph: PhiGlyph
    var enabled: Bool
    var reason: String?
    var openOnAppear: Bool
    var onSelect: (AVCaptureDevice.FlashMode) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIView(context: Context) -> FlashMenuButton {
        let button = FlashMenuButton(type: .custom)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "闪光灯"
        return button
    }

    func updateUIView(_ button: FlashMenuButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let image = UIImage(named: glyph.rawValue)?.withRenderingMode(.alwaysTemplate)
        var configuration = UIButton.Configuration.plain()
        configuration.image = image
        configuration.baseForegroundColor = UIColor(red: 244.0 / 255.0, green: 243.0 / 255.0, blue: 238.0 / 255.0, alpha: 1)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        button.configuration = configuration
        button.menu = context.coordinator.menu(selection: mode, enabled: enabled, reason: reason)
        button.openOnAppear = openOnAppear
        button.accessibilityValue = FlashSystemMenu.title(for: mode)
        if openOnAppear {
            button.openMenuIfNeeded()
        }
    }

    static func title(for mode: AVCaptureDevice.FlashMode) -> String {
        switch mode {
        case .on: return "开启"
        case .auto: return "自动"
        default: return "关闭"
        }
    }

    final class Coordinator {
        var onSelect: (AVCaptureDevice.FlashMode) -> Void

        init(onSelect: @escaping (AVCaptureDevice.FlashMode) -> Void) {
            self.onSelect = onSelect
        }

        func menu(selection: AVCaptureDevice.FlashMode, enabled: Bool, reason: String?) -> UIMenu {
            let rows: [(AVCaptureDevice.FlashMode, String)] = [
                (.off, "关闭"),
                (.auto, "自动"),
                (.on, "开启")
            ]
            var children: [UIMenuElement] = []
            for row in rows {
                let action = UIAction(title: row.1, state: row.0 == selection ? .on : .off) { [weak self] _ in
                    self?.onSelect(row.0)
                }
                if enabled == false {
                    action.attributes = .disabled
                }
                children.append(action)
            }
            if enabled == false, let reason, reason.isEmpty == false {
                let note = UIAction(title: reason, attributes: .disabled) { _ in }
                children.append(note)
            }
            return UIMenu(title: "", options: .displayInline, children: children)
        }
    }
}

final class FlashMenuButton: UIButton {
    var openOnAppear = false
    private var didOpen = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        openMenuIfNeeded()
    }

    func openMenuIfNeeded() {
        guard openOnAppear, didOpen == false, window != nil else { return }
        didOpen = true
        DispatchQueue.main.async { [weak self] in
            self?.performPrimaryAction()
        }
    }
}
