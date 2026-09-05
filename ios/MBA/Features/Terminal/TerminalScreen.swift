import SwiftUI
import UIKit

/// Affichage d'une session terminal, clavier compris.
struct TerminalScreen: View {
    let hostID: Int
    let hostName: String
    var container: String?
    var resuming: TerminalSession?

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var connection = TerminalConnection()
    @State private var fontSize: Double = 10
    @State private var ttl: TerminalTTL = .thirtyMinutes
    @State private var isKeyboardActive = false
    @State private var controlArmed = false
    @State private var showsClosureAlert = false

    /// Marge de chaque côté du canevas, retirée du calcul des colonnes.
    private static let horizontalInset: CGFloat = 6

    private var metrics: (width: Double, height: Double) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // « M » est la référence d'avance sur une police à pas fixe.
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        return (width, font.lineHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            terminalCanvas
            keyBar
        }
        .background(Color.terminalBackground)
        .navigationTitle(connection.label ?? container ?? hostName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        // La barre d'onglets recouvrirait la rangée de touches spéciales, et le
        // titre de navigation resterait noir sur fond sombre.
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(.dark)
        .toolbar { toolbarContent }
        .task {
            guard let profile = session.activeProfile else { return }
            connection.connect(profile: profile, hostID: hostID, container: container,
                               ttl: resuming == nil ? ttl : .thirtyMinutes,
                               resuming: resuming?.id)
        }
        .onDisappear {
            // On se détache sans fermer : le shell continue côté serveur.
            connection.disconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            connection.disconnect()
        }
        .onChange(of: connection.phase) { _, phase in
            if case .closed(let reason) = phase, reason != nil { showsClosureAlert = true }
        }
        .alert("Session terminée", isPresented: $showsClosureAlert) {
            Button("Fermer") { dismiss() }
        } message: {
            if case .closed(let reason) = connection.phase, let reason {
                Text(reason)
            }
        }
    }

    // MARK: - Canevas

    private var terminalCanvas: some View {
        GeometryReader { geometry in
            let size = metrics
            // La marge horizontale doit sortir du calcul : la compter donnerait une
            // ou deux colonnes de trop, et la dernière serait rognée par SwiftUI
            // avec des points de suspension au lieu d'être repliée par le shell.
            let usableWidth = geometry.size.width - Self.horizontalInset * 2
            let columns = max(20, Int(usableWidth / size.width))
            let rows = max(6, Int(geometry.size.height / size.height))

            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(connection.emulator.displayLines(includingScrollback: true)) { line in
                            TerminalLineView(line: line, fontSize: fontSize,
                                             lineHeight: size.height)
                                .id(line.id)
                        }
                        // Ancre de bas de page : viser la dernière ligne ne suffit
                        // pas quand elle est vide.
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Self.horizontalInset)
                    .padding(.vertical, 4)
                }
                .scrollDismissesKeyboard(.never)
                .onChange(of: connection.emulator.revision) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: columns) { _, _ in connection.resize(columns: columns, rows: rows) }
            .onChange(of: rows) { _, _ in connection.resize(columns: columns, rows: rows) }
            .task(id: "\(columns)x\(rows)") {
                connection.resize(columns: columns, rows: rows)
            }
            .overlay {
                if case .connecting = connection.phase {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .background(
                TerminalKeyboardCapture(isActive: $isKeyboardActive) { text in
                    guard !controlArmed else {
                        if let character = text.first {
                            connection.sendKey(.control(character))
                        }
                        controlArmed = false
                        return
                    }
                    connection.send(text)
                } onDeleteBackward: {
                    connection.sendKey(.backspace)
                } onSpecialKey: { key in
                    connection.sendKey(key)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { isKeyboardActive = true }
        }
    }

    // MARK: - Barre de touches

    private var keyBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    KeyCap(label: "^", isArmed: controlArmed) { controlArmed.toggle() }
                    KeyCap(label: "esc") { connection.sendKey(.escape) }
                    KeyCap(label: "⇥") { connection.sendKey(.tab) }
                    Divider().frame(height: 22).overlay(Color.white.opacity(0.15))
                    KeyCap(label: "←") { connection.sendKey(.left) }
                    KeyCap(label: "↓") { connection.sendKey(.down) }
                    KeyCap(label: "↑") { connection.sendKey(.up) }
                    KeyCap(label: "→") { connection.sendKey(.right) }
                    Divider().frame(height: 22).overlay(Color.white.opacity(0.15))
                    KeyCap(label: "^C") { connection.sendKey(.control("C")) }
                    KeyCap(label: "^D") { connection.sendKey(.control("D")) }
                    KeyCap(label: "^Z") { connection.sendKey(.control("Z")) }
                    KeyCap(label: "^L") { connection.sendKey(.control("L")) }
                    KeyCap(label: "⇞") { connection.sendKey(.pageUp) }
                    KeyCap(label: "⇟") { connection.sendKey(.pageDown) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(Color(.sRGB, red: 0.09, green: 0.11, blue: 0.14, opacity: 1))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Taille du texte") {
                    Picker("Taille", selection: $fontSize) {
                        Text("Très petit").tag(8.0)
                        Text("Petit").tag(10.0)
                        Text("Moyen").tag(12.0)
                        Text("Grand").tag(14.0)
                    }
                }
                Section("Survie après fermeture") {
                    Picker("Durée", selection: $ttl) {
                        ForEach(TerminalTTL.allCases) { Text($0.label).tag($0) }
                    }
                }
                Divider()
                Button("Effacer l'écran", systemImage: "eraser") {
                    connection.sendKey(.control("L"))
                }
                Button(isKeyboardActive ? "Masquer le clavier" : "Afficher le clavier",
                       systemImage: "keyboard") {
                    isKeyboardActive.toggle()
                }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
            .onChange(of: ttl) { _, value in connection.setTTL(value) }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if case .connected(let resumed) = connection.phase {
                StatusBadge(text: resumed ? "Reprise" : "Direct", color: Palette.ok)
            }
        }
    }
}

/// Une ligne de terminal, en fragments de style homogène.
private struct TerminalLineView: View {
    let line: TerminalDisplayLine
    let fontSize: Double
    let lineHeight: Double

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(line.runs.enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(.system(size: fontSize, weight: run.style.bold ? .bold : .regular,
                                  design: .monospaced))
                    .italic(run.style.italic)
                    .underline(run.style.underline)
                    .foregroundStyle(foreground(run.style))
                    .background(background(run.style))
                    .opacity(run.style.faint ? 0.6 : 1)
            }
        }
        .frame(height: lineHeight, alignment: .leading)
        .textSelection(.enabled)
    }

    private func foreground(_ style: TerminalStyle) -> Color {
        let source = style.inverse ? style.background : style.foreground
        if style.inverse, case .default = source { return Color.terminalBackground }
        return source.color(isBackground: false, bold: style.bold) ?? Color.terminalForeground
    }

    private func background(_ style: TerminalStyle) -> Color {
        let source = style.inverse ? style.foreground : style.background
        if style.inverse, case .default = source { return Color.terminalForeground }
        return source.color(isBackground: true, bold: false) ?? .clear
    }
}

private struct KeyCap: View {
    let label: String
    var isArmed: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(isArmed ? Color.terminalBackground : Color.terminalForeground)
                .frame(minWidth: 34, minHeight: 30)
                .background(isArmed ? Color.accentColor : Color.white.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Capture clavier

/// Capte les frappes sans passer par un `TextField`.
///
/// Un champ de texte imposerait sa propre logique d'édition — autocorrection,
/// composition, curseur — là où un terminal veut chaque octet tel quel. `UIKeyInput`
/// donne exactement `insertText` et `deleteBackward`, et `pressesBegan` récupère
/// les flèches et les combinaisons d'un clavier matériel sur iPad.
private struct TerminalKeyboardCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    let onText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onSpecialKey: (TerminalKey) -> Void

    func makeUIView(context: Context) -> KeyInputView {
        let view = KeyInputView()
        view.onText = onText
        view.onDeleteBackward = onDeleteBackward
        view.onSpecialKey = onSpecialKey
        return view
    }

    func updateUIView(_ view: KeyInputView, context: Context) {
        view.onText = onText
        view.onDeleteBackward = onDeleteBackward
        view.onSpecialKey = onSpecialKey
        if isActive, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    final class KeyInputView: UIView, UIKeyInput {
        var onText: ((String) -> Void)?
        var onDeleteBackward: (() -> Void)?
        var onSpecialKey: ((TerminalKey) -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        // MARK: UIKeyInput

        var hasText: Bool { true }

        func insertText(_ text: String) {
            // Le clavier iOS envoie « \n » pour la touche retour ; un tty attend
            // un retour chariot.
            onText?(text == "\n" ? "\r" : text)
        }

        func deleteBackward() {
            onDeleteBackward?()
        }

        var keyboardType: UIKeyboardType {
            get { .asciiCapable }
            set { _ = newValue }
        }

        var autocorrectionType: UITextAutocorrectionType {
            get { .no }
            set { _ = newValue }
        }

        var autocapitalizationType: UITextAutocapitalizationType {
            get { .none }
            set { _ = newValue }
        }

        var spellCheckingType: UITextSpellCheckingType {
            get { .no }
            set { _ = newValue }
        }

        var smartQuotesType: UITextSmartQuotesType {
            get { .no }
            set { _ = newValue }
        }

        var smartDashesType: UITextSmartDashesType {
            get { .no }
            set { _ = newValue }
        }

        var smartInsertDeleteType: UITextSmartInsertDeleteType {
            get { .no }
            set { _ = newValue }
        }

        // MARK: Clavier matériel

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var handled = false
            for press in presses {
                guard let key = press.key else { continue }
                if key.modifierFlags.contains(.control),
                   let character = key.charactersIgnoringModifiers.first,
                   character.isLetter {
                    onSpecialKey?(.control(character))
                    handled = true
                    continue
                }
                switch key.keyCode {
                case .keyboardUpArrow: onSpecialKey?(.up); handled = true
                case .keyboardDownArrow: onSpecialKey?(.down); handled = true
                case .keyboardLeftArrow: onSpecialKey?(.left); handled = true
                case .keyboardRightArrow: onSpecialKey?(.right); handled = true
                case .keyboardEscape: onSpecialKey?(.escape); handled = true
                case .keyboardTab: onSpecialKey?(.tab); handled = true
                case .keyboardHome: onSpecialKey?(.home); handled = true
                case .keyboardEnd: onSpecialKey?(.end); handled = true
                case .keyboardPageUp: onSpecialKey?(.pageUp); handled = true
                case .keyboardPageDown: onSpecialKey?(.pageDown); handled = true
                default: break
                }
            }
            if !handled {
                super.pressesBegan(presses, with: event)
            }
        }
    }
}
