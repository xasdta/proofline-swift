#if canImport(SwiftUI)
import SwiftUI
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(tvOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Submits a normalized code; the flag is true when it came from the clipboard.
public typealias CodeSubmitter = @Sendable (_ code: String, _ pasted: Bool) async -> CodeResult

/// Shared state for the code entry views: input normalization, one submission at a time, and a
/// user-facing status line.
@MainActor
final class CodeEntryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case submitting
        case finished(CodeResult)
    }

    @Published var text = "" {
        didSet {
            // The shown result described the previous text.
            if clearsResultOnEdit, text != oldValue, case .finished = phase { phase = .idle }
        }
    }
    @Published private(set) var phase: Phase = .idle

    /// The user-facing text (status messages, labels).
    let strings: ProoflineCodeEntryStrings
    /// Whether editing the text after a result goes back to idle (`ProoflineCodeEntryView`).
    private let clearsResultOnEdit: Bool
    private let submitter: CodeSubmitter
    private let onResult: @MainActor (CodeResult) -> Void
    /// Whether the result is announced to VoiceOver (off when the host hides the status line and
    /// presents the result itself).
    private let announcesResult: Bool
    private let announcer: @MainActor (String) -> Void

    init(submitter: @escaping CodeSubmitter, strings: ProoflineCodeEntryStrings = ProoflineCodeEntryStrings(),
         announcesResult: Bool = true, clearsResultOnEdit: Bool = false,
         announcer: @escaping @MainActor (String) -> Void = CodeEntryModel.postAccessibilityAnnouncement,
         onResult: @escaping @MainActor (CodeResult) -> Void) {
        self.submitter = submitter
        self.strings = strings
        self.clearsResultOnEdit = clearsResultOnEdit
        self.announcesResult = announcesResult
        self.announcer = announcer
        self.onResult = onResult
    }

    /// Asks VoiceOver (and other assistive technologies) to read the message now. A status line that
    /// merely appears is not read out, so the result of a submission is announced explicitly
    /// (WCAG 2.2 SC 4.1.3 Status Messages).
    static func postAccessibilityAnnouncement(_ message: String) {
        #if os(iOS) || os(tvOS) || os(visionOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        // `NSApp` is nil outside an app (no NSApplication is created just to announce).
        if let app = NSApp as NSApplication?, let window = app.keyWindow ?? app.mainWindow {
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        #endif
    }

    static let defaultSubmitter: CodeSubmitter = { code, pasted in
        await Proofline.submitCode(code, pasted: pasted)
    }

    var isSubmitting: Bool { phase == .submitting }
    var canSubmit: Bool { !isSubmitting && ProoflineInput.normalizeCode(text) != nil }

    func submitTyped() async {
        await submit(text, pasted: false)
    }

    /// Clipboard text arrives only after the user tapped the system paste control.
    func submitPasted(_ clipboard: String) async {
        if let code = ProoflineInput.normalizeCode(clipboard) { text = code }
        await submit(clipboard, pasted: true)
    }

    /// Ignored while a submission is in flight (double taps send one request).
    @discardableResult
    func submit(_ raw: String, pasted: Bool) async -> CodeResult? {
        guard !isSubmitting else { return nil }
        guard let code = ProoflineInput.normalizeCode(raw) else {
            return finish(.error(message: "Enter a code of 1 to \(ProoflineInput.maxCodeLength) characters"))
        }
        phase = .submitting
        return finish(await submitter(code, pasted))
    }

    private func finish(_ result: CodeResult) -> CodeResult {
        phase = .finished(result)
        if announcesResult, let message = statusMessage { announcer(message) }
        onResult(result)
        return result
    }

    /// The phase as the public state the views draw.
    var state: ProoflineCodeEntryState {
        switch phase {
        case .idle: return .idle
        case .submitting: return .submitting
        case let .finished(result): return ProoflineCodeEntryState(result)
        }
    }

    /// The message for a finished submission; nil while idle or submitting.
    var statusMessage: String? {
        guard case .finished = phase else { return nil }
        return strings.message(for: state)
    }
}

/// Text field plus Apply button for a creator code, with the SDK's own styling. Works on every
/// platform; it is also the `PasteCodeButton` fallback before iOS 16. For a field that takes your
/// app's styling or layout, use `ProoflineCodeEntryView`.
public struct CodeEntryField: View {
    @StateObject private var model: CodeEntryModel
    private let placeholder: String?
    private let showsStatus: Bool

    /// - Parameters:
    ///   - placeholder: the field's placeholder; `strings.placeholder` when nil.
    ///   - strings: user-facing text; the localised defaults when omitted.
    public init(placeholder: String? = nil, showsStatus: Bool = true,
                strings: ProoflineCodeEntryStrings = ProoflineCodeEntryStrings(),
                onResult: @escaping @MainActor (CodeResult) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: CodeEntryModel(submitter: CodeEntryModel.defaultSubmitter, strings: strings,
                                                          announcesResult: showsStatus, onResult: onResult))
        self.placeholder = placeholder
        self.showsStatus = showsStatus
    }

    init(model: CodeEntryModel, placeholder: String? = nil, showsStatus: Bool = true) {
        _model = StateObject(wrappedValue: model)
        self.placeholder = placeholder
        self.showsStatus = showsStatus
    }

    public var body: some View {
        CodeEntryContent(model: model, placeholder: placeholder ?? model.strings.placeholder, showsStatus: showsStatus)
    }
}

/// SwiftUI paste button for creator codes. On iOS 16+ it wraps `UIPasteControl`, so reading the
/// clipboard needs the user's tap but shows no paste-permission prompt. Earlier iOS versions and
/// other platforms get `CodeEntryField`. Either way the code goes to `Proofline.submitCode`, which
/// opens Apple's redemption sheet for offer codes.
public struct PasteCodeButton: View {
    @StateObject private var model: CodeEntryModel
    private let showsStatus: Bool

    /// - Parameter strings: user-facing text; the localised defaults when omitted.
    public init(showsStatus: Bool = true, strings: ProoflineCodeEntryStrings = ProoflineCodeEntryStrings(),
                onResult: @escaping @MainActor (CodeResult) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: CodeEntryModel(submitter: CodeEntryModel.defaultSubmitter, strings: strings,
                                                          announcesResult: showsStatus, onResult: onResult))
        self.showsStatus = showsStatus
    }

    init(model: CodeEntryModel, showsStatus: Bool = true) {
        _model = StateObject(wrappedValue: model)
        self.showsStatus = showsStatus
    }

    public var body: some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            VStack(alignment: .leading, spacing: 8) {
                PasteControl { text in Task { await model.submitPasted(text) } }
                    .disabled(model.isSubmitting)
                    .accessibilityHint(Text(model.strings.pasteHint))
                StatusLine(model: model, showsStatus: showsStatus)
            }
        } else {
            CodeEntryContent(model: model, placeholder: model.strings.placeholder, showsStatus: showsStatus)
        }
        #else
        CodeEntryContent(model: model, placeholder: model.strings.placeholder, showsStatus: showsStatus)
        #endif
    }
}

struct CodeEntryContent: View {
    @ObservedObject var model: CodeEntryModel
    let placeholder: String
    let showsStatus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(placeholder, text: $model.text)
                    .modifier(CodeFieldStyle())
                    .submitLabel(.done)
                    .onSubmit { Task { await model.submitTyped() } }
                Button(model.strings.submit) { Task { await model.submitTyped() } }
                    .disabled(!model.canSubmit)
            }
            StatusLine(model: model, showsStatus: showsStatus)
        }
    }
}

struct StatusLine: View {
    @ObservedObject var model: CodeEntryModel
    let showsStatus: Bool

    var body: some View {
        if model.isSubmitting {
            ProgressView()
                .accessibilityLabel(Text(model.strings.submitting))
        } else if showsStatus, let message = model.statusMessage {
            // Read out when it appears by `CodeEntryModel`'s announcement.
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}

struct CodeFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
        #else
        content
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
        #endif
    }
}

#if os(iOS)
/// `UIPasteControl` bridged into SwiftUI.
@available(iOS 16.0, *)
struct PasteControl: UIViewRepresentable {
    let onPaste: @MainActor (String) -> Void

    func makeUIView(context: Context) -> PasteTargetView {
        let view = PasteTargetView(frame: .zero)
        view.onPaste = onPaste
        return view
    }

    func updateUIView(_ view: PasteTargetView, context: Context) {
        view.onPaste = onPaste
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasteTargetView, context: Context) -> CGSize? {
        let width = proposal.width.map { min(max($0, PasteTargetView.minimumSide), PasteTargetView.preferredSize.width) }
        return CGSize(width: width ?? PasteTargetView.preferredSize.width, height: PasteTargetView.preferredSize.height)
    }
}

/// Paste target for the control: accepts plain text and forwards it on the main actor.
@available(iOS 16.0, *)
final class PasteTargetView: UIView {
    /// `UIPasteControl` draws out of process and reports no intrinsic size (zero), so the wrapper
    /// supplies one: a 44 pt touch target wide enough for the "Paste" icon and label.
    static let preferredSize = CGSize(width: 120, height: 44)
    static let minimumSide: CGFloat = 44

    var onPaste: (@MainActor (String) -> Void)?
    let control: UIPasteControl

    override init(frame: CGRect) {
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        control = UIPasteControl(configuration: config)
        super.init(frame: frame)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier,
                                                                              UTType.text.identifier])
        control.target = self
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize { Self.preferredSize }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        itemProviders.contains { $0.canLoadObject(ofClass: String.self) }
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }),
              let handler = onPaste else { return }
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            guard let value else { return }
            Task { @MainActor in handler(value) }
        }
    }
}
#endif
#endif
