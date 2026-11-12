#if canImport(SwiftUI)
import SwiftUI

/// What `ProoflineCodeEntryView` gives its content to draw: the text binding, the current state and
/// the submit action. Build any layout from it.
@MainActor
public struct ProoflineCodeEntryConfiguration {
    /// The code text; bind your text field to it.
    public let code: Binding<String>
    /// What to show: idle, submitting, or the outcome of the last submission. Goes back to `.idle`
    /// when the user edits the code after a result.
    public let state: ProoflineCodeEntryState
    /// `strings.message(for: state)`: nil while idle.
    public let message: String?
    /// The strings the view was created with (placeholder, button title, accessibility labels).
    public let strings: ProoflineCodeEntryStrings
    /// False while a submission is in flight or the text is not a code (empty, or longer than 64).
    public let canSubmit: Bool
    private let action: @MainActor () -> Void

    public var isSubmitting: Bool { state == .submitting }

    init(code: Binding<String>, state: ProoflineCodeEntryState, strings: ProoflineCodeEntryStrings,
         canSubmit: Bool, action: @escaping @MainActor () -> Void) {
        self.code = code
        self.state = state
        self.message = strings.message(for: state)
        self.strings = strings
        self.canSubmit = canSubmit
        self.action = action
    }

    /// Submit the current text through `Proofline.submitCode`. Does nothing while `canSubmit` is
    /// false, so it is safe to call from a keyboard "done" action as well as a button.
    public func submit() {
        if canSubmit { action() }
    }
}

/// A ready-made creator-code screen element: text field, submit button, progress, and a status
/// line for success / "code not found" / expired / offline / failure.
///
/// The code goes to `Proofline.submitCode` (the same path as `CodeEntryField` and
/// `PasteCodeButton`), which opens Apple's redemption sheet for offer codes. The view never reads
/// the clipboard; pair it with `PasteCodeButton` for one-tap paste.
///
/// The default content sets no font, colour, text-field style or button style, so the usual
/// modifiers on the view (`.font`, `.tint`, `.textFieldStyle`, `.buttonStyle`, `.foregroundStyle`)
/// style it:
///
/// ```swift
/// ProoflineCodeEntryView(onResult: { result in
///     if case .accepted = result { dismiss() }
/// })
/// .textFieldStyle(.roundedBorder)
/// .buttonStyle(.borderedProminent)
/// ```
///
/// For a different layout, pass `content`; it receives a `ProoflineCodeEntryConfiguration`. All text
/// comes from `ProoflineCodeEntryStrings` (localisable, see that type).
public struct ProoflineCodeEntryView<Content: View>: View {
    @StateObject private var model: CodeEntryModel
    private let content: @MainActor (ProoflineCodeEntryConfiguration) -> Content

    /// - Parameters:
    ///   - strings: user-facing text; the localised defaults when omitted. Read once, when the view
    ///     first appears.
    ///   - announcesResult: post the result message as an accessibility announcement (VoiceOver
    ///     does not read a status line that merely appears). Turn off when you announce it yourself.
    ///   - onResult: called on the main actor with every result, including local validation errors.
    ///   - content: draws the view from its configuration.
    public init(strings: ProoflineCodeEntryStrings = ProoflineCodeEntryStrings(),
                announcesResult: Bool = true,
                onResult: @escaping @MainActor (CodeResult) -> Void = { _ in },
                @ViewBuilder content: @escaping @MainActor (ProoflineCodeEntryConfiguration) -> Content) {
        _model = StateObject(wrappedValue: CodeEntryModel(submitter: CodeEntryModel.defaultSubmitter,
                                                          strings: strings, announcesResult: announcesResult,
                                                          clearsResultOnEdit: true, onResult: onResult))
        self.content = content
    }

    init(model: CodeEntryModel,
         @ViewBuilder content: @escaping @MainActor (ProoflineCodeEntryConfiguration) -> Content) {
        _model = StateObject(wrappedValue: model)
        self.content = content
    }

    public var body: some View {
        content(ProoflineCodeEntryConfiguration(
            code: $model.text, state: model.state, strings: model.strings, canSubmit: model.canSubmit,
            action: { [model] in Task { await model.submitTyped() } }
        ))
    }
}

extension ProoflineCodeEntryView where Content == ProoflineCodeEntryDefaultContent {
    /// The view with its default, unstyled content.
    public init(strings: ProoflineCodeEntryStrings = ProoflineCodeEntryStrings(),
                announcesResult: Bool = true,
                onResult: @escaping @MainActor (CodeResult) -> Void = { _ in }) {
        self.init(strings: strings, announcesResult: announcesResult, onResult: onResult) {
            ProoflineCodeEntryDefaultContent($0)
        }
    }

    init(model: CodeEntryModel) {
        self.init(model: model) { ProoflineCodeEntryDefaultContent($0) }
    }
}

/// The default content of `ProoflineCodeEntryView`: a text field and a submit button in a row,
/// with a progress indicator or the status message below. Deliberately unstyled (see
/// `ProoflineCodeEntryView`); usable inside your own `content` closure too.
public struct ProoflineCodeEntryDefaultContent: View {
    private let configuration: ProoflineCodeEntryConfiguration

    public init(_ configuration: ProoflineCodeEntryConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField(configuration.strings.placeholder, text: configuration.code)
                    .modifier(CodeInputBehavior())
                    .accessibilityLabel(Text(configuration.strings.fieldLabel))
                    .submitLabel(.done)
                    .onSubmit { configuration.submit() }
                Button(configuration.strings.submit) { configuration.submit() }
                    .disabled(!configuration.canSubmit)
            }
            if configuration.isSubmitting {
                ProgressView()
                    .accessibilityLabel(Text(configuration.strings.submitting))
            } else if let message = configuration.message {
                // Read out when it appears by `CodeEntryModel`'s announcement.
                Text(message)
            }
        }
    }
}

/// Keyboard behaviour for a code field (no visual styling): codes are not words.
struct CodeInputBehavior: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        #else
        content
            .autocorrectionDisabled()
        #endif
    }
}
#endif
