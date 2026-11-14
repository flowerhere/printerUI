import SwiftUI
import UIKit

/// Share Extension 的進入點：以 SwiftUI 畫分享面板。
final class ShareViewController: UIViewController {
    private var model: ShareModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(
            providers: Self.collectProviders(from: extensionContext),
            onFinish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }
        )
        self.model = model

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { await model.loadAttachments() }
    }

    private static func collectProviders(from context: NSExtensionContext?) -> [NSItemProvider] {
        let items = context?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return items.flatMap { $0.attachments ?? [] }
    }
}
