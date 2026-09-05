import SwiftUI

/// Couleur d'un caractère, telle que l'exprime une séquence SGR.
enum TerminalColor: Equatable, Sendable {
    case `default`
    case indexed(Int)
    case rgb(UInt8, UInt8, UInt8)
}

struct TerminalStyle: Equatable, Sendable {
    var foreground: TerminalColor = .default
    var background: TerminalColor = .default
    var bold = false
    var faint = false
    var italic = false
    var underline = false
    var inverse = false

    static let plain = TerminalStyle()
}

struct TerminalCell: Equatable, Sendable {
    var character: Character = " "
    var style: TerminalStyle = .plain

    static let blank = TerminalCell()
}

/// Émulateur VT100/xterm réduit à ce qu'un shell d'administration utilise.
///
/// Couvre le déplacement du curseur, les effacements, l'insertion et la
/// suppression de lignes, la région de défilement, les attributs SGR (16
/// couleurs, 256 couleurs, vraies couleurs) et l'écran alterné — ce dernier est
/// ce qui rend `htop`, `vim` ou `less` utilisables plutôt que défilants.
///
/// Volontairement hors périmètre : jeux de caractères DEC autres qu'ASCII et
/// tracé de lignes, souris, et réponses aux interrogations d'état. Une bordure
/// de tableau `htop` peut donc apparaître en lettres au lieu de filets.
@MainActor
@Observable
final class TerminalEmulator {
    private(set) var columns: Int
    private(set) var rows: Int

    /// Grille visible, `rows` lignes de `columns` cellules.
    private(set) var grid: [[TerminalCell]]
    /// Lignes sorties par le haut, conservées pour le défilement arrière.
    private(set) var scrollback: [[TerminalCell]] = []

    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var isCursorVisible = true
    /// Titre posé par une séquence OSC — le shell y met souvent `user@host:cwd`.
    private(set) var title: String?

    /// Incrémenté à chaque salve appliquée : la vue s'y abonne pour se redessiner
    /// une fois par lot, au lieu d'une fois par caractère.
    private(set) var revision = 0

    private var style = TerminalStyle.plain
    private var savedCursor: (row: Int, column: Int)?
    private var scrollTop = 0
    private var scrollBottom: Int
    private var wrapPending = false
    private var autoWrap = true

    /// Écran alterné : sauvegarde de l'écran principal pendant qu'une
    /// application plein écran occupe le terminal.
    private var mainScreen: (grid: [[TerminalCell]], cursor: (Int, Int))?

    private static let scrollbackLimit = 2000

    private enum ParserState {
        case ground
        case escape
        /// Paramètres d'une séquence CSI en cours d'accumulation.
        case csi(parameters: String, intermediates: String)
        /// Séquence OSC — on ne retient que le titre.
        case osc(buffer: String)
        /// Octet à ignorer après une séquence de sélection de jeu de caractères.
        case charset
    }

    private var state: ParserState = .ground

    init(columns: Int = 80, rows: Int = 24) {
        let width = max(2, columns)
        let height = max(2, rows)
        self.columns = width
        self.rows = height
        self.scrollBottom = height - 1
        self.grid = Array(repeating: Array(repeating: .blank, count: width), count: height)
    }

    // MARK: - Entrée

    func feed(_ text: String) {
        // On parcourt les scalaires, pas les `Character` : en Swift, « \r\n » est
        // un seul grapheme cluster. Itérer les caractères le livrerait comme une
        // unité que ni « \r » ni « \n » ne reconnaît, et le retour à la ligne
        // finirait imprimé dans une cellule au lieu d'être exécuté.
        for scalar in text.unicodeScalars {
            consume(Character(scalar))
        }
        revision &+= 1
    }

    func reset() {
        grid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        scrollback.removeAll()
        cursorRow = 0
        cursorColumn = 0
        style = .plain
        scrollTop = 0
        scrollBottom = rows - 1
        mainScreen = nil
        state = .ground
        wrapPending = false
        revision &+= 1
    }

    /// Redimensionne la grille en conservant le contenu aligné en haut.
    ///
    /// Le réajustement ne reformate pas les lignes déjà écrites : réenvelopper un
    /// historique arbitraire produit plus de dégâts visuels qu'un simple recadrage,
    /// et le shell redessine de lui-même après le `SIGWINCH`.
    func resize(columns newColumns: Int, rows newRows: Int) {
        let targetColumns = max(2, newColumns)
        let targetRows = max(2, newRows)
        guard targetColumns != columns || targetRows != rows else { return }

        var resized = grid.map { line -> [TerminalCell] in
            var line = line
            if line.count > targetColumns {
                line.removeLast(line.count - targetColumns)
            } else if line.count < targetColumns {
                line.append(contentsOf: Array(repeating: .blank, count: targetColumns - line.count))
            }
            return line
        }
        if resized.count > targetRows {
            // Les lignes qui sortent par le haut rejoignent l'historique.
            let excess = resized.count - targetRows
            scrollback.append(contentsOf: resized.prefix(excess))
            trimScrollback()
            resized.removeFirst(excess)
        } else if resized.count < targetRows {
            resized.append(contentsOf: Array(
                repeating: Array(repeating: .blank, count: targetColumns),
                count: targetRows - resized.count))
        }

        columns = targetColumns
        rows = targetRows
        grid = resized
        scrollTop = 0
        scrollBottom = rows - 1
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        revision &+= 1
    }

    // MARK: - Analyse

    private func consume(_ character: Character) {
        switch state {
        case .ground:
            ground(character)
        case .escape:
            escape(character)
        case .csi(let parameters, let intermediates):
            csi(character, parameters: parameters, intermediates: intermediates)
        case .osc(let buffer):
            osc(character, buffer: buffer)
        case .charset:
            state = .ground
        }
    }

    private func ground(_ character: Character) {
        switch character {
        case "\u{1B}":
            state = .escape
        case "\r":
            cursorColumn = 0
            wrapPending = false
        case "\n", "\u{0B}", "\u{0C}":
            lineFeed()
        case "\u{08}":
            if cursorColumn > 0 { cursorColumn -= 1 }
            wrapPending = false
        case "\t":
            // Tabulations tous les 8 caractères, comme un tty par défaut.
            cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8)
        case "\u{07}":
            break   // cloche : rien à faire de visible
        default:
            guard !character.isASCII || character.asciiValue.map({ $0 >= 0x20 }) ?? true else { return }
            put(character)
        }
    }

    private func escape(_ character: Character) {
        switch character {
        case "[":
            state = .csi(parameters: "", intermediates: "")
        case "]":
            state = .osc(buffer: "")
        case "(", ")", "*", "+":
            state = .charset
        case "M":
            reverseIndex()
            state = .ground
        case "D":
            lineFeed()
            state = .ground
        case "E":
            cursorColumn = 0
            lineFeed()
            state = .ground
        case "7":
            savedCursor = (cursorRow, cursorColumn)
            state = .ground
        case "8":
            if let savedCursor {
                cursorRow = min(savedCursor.row, rows - 1)
                cursorColumn = min(savedCursor.column, columns - 1)
            }
            state = .ground
        case "c":
            reset()
            state = .ground
        default:
            state = .ground
        }
    }

    private func csi(_ character: Character, parameters: String, intermediates: String) {
        if character.isNumber || character == ";" || character == ":" {
            state = .csi(parameters: parameters + String(character), intermediates: intermediates)
            return
        }
        if character == "?" || character == ">" || character == "<" || character == "!" {
            state = .csi(parameters: parameters, intermediates: intermediates + String(character))
            return
        }
        state = .ground
        apply(final: character, parameters: parameters, isPrivate: !intermediates.isEmpty)
    }

    private func osc(_ character: Character, buffer: String) {
        if character == "\u{07}" || character == "\u{1B}" || character == "\u{9C}" {
            // `0;titre` et `2;titre` posent tous deux le titre de fenêtre.
            let parts = buffer.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "0" || parts[0] == "2" {
                title = String(parts[1])
            }
            state = character == "\u{1B}" ? .escape : .ground
            return
        }
        state = .osc(buffer: buffer + String(character))
    }

    // MARK: - Commandes CSI

    private func apply(final: Character, parameters: String, isPrivate: Bool) {
        let values = parameters
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        func value(_ index: Int, default fallback: Int = 1) -> Int {
            guard index < values.count, values[index] > 0 else { return fallback }
            return values[index]
        }

        switch final {
        case "A": cursorRow = max(scrollTop, cursorRow - value(0)); wrapPending = false
        case "B": cursorRow = min(scrollBottom, cursorRow + value(0)); wrapPending = false
        case "C": cursorColumn = min(columns - 1, cursorColumn + value(0)); wrapPending = false
        case "D": cursorColumn = max(0, cursorColumn - value(0)); wrapPending = false
        case "E":
            cursorRow = min(scrollBottom, cursorRow + value(0))
            cursorColumn = 0
        case "F":
            cursorRow = max(scrollTop, cursorRow - value(0))
            cursorColumn = 0
        case "G", "`":
            cursorColumn = min(columns - 1, value(0) - 1)
            wrapPending = false
        case "d":
            cursorRow = min(rows - 1, value(0) - 1)
            wrapPending = false
        case "H", "f":
            cursorRow = min(rows - 1, value(0) - 1)
            cursorColumn = min(columns - 1, value(1) - 1)
            wrapPending = false
        case "J": eraseInDisplay(values.first ?? 0)
        case "K": eraseInLine(values.first ?? 0)
        case "L": insertLines(value(0))
        case "M": deleteLines(value(0))
        case "P": deleteCharacters(value(0))
        case "@": insertCharacters(value(0))
        case "X": eraseCharacters(value(0))
        case "S": scrollUp(value(0))
        case "T": scrollDown(value(0))
        case "m": selectGraphicRendition(values.isEmpty ? [0] : values, raw: parameters)
        case "r":
            let top = (values.count > 0 && values[0] > 0) ? values[0] - 1 : 0
            let bottom = (values.count > 1 && values[1] > 0) ? values[1] - 1 : rows - 1
            if top < bottom, bottom < rows {
                scrollTop = top
                scrollBottom = bottom
            }
            cursorRow = scrollTop
            cursorColumn = 0
        case "h" where isPrivate: setPrivateMode(values, enabled: true)
        case "l" where isPrivate: setPrivateMode(values, enabled: false)
        case "s": savedCursor = (cursorRow, cursorColumn)
        case "u":
            if let savedCursor {
                cursorRow = min(savedCursor.row, rows - 1)
                cursorColumn = min(savedCursor.column, columns - 1)
            }
        default:
            break
        }
    }

    private func setPrivateMode(_ values: [Int], enabled: Bool) {
        for mode in values {
            switch mode {
            case 7:
                autoWrap = enabled
            case 25:
                isCursorVisible = enabled
            case 47, 1047, 1049:
                enabled ? enterAlternateScreen() : leaveAlternateScreen()
            default:
                break   // souris, collage parenthésé, etc.
            }
        }
    }

    private func enterAlternateScreen() {
        guard mainScreen == nil else { return }
        mainScreen = (grid, (cursorRow, cursorColumn))
        grid = Array(repeating: Array(repeating: .blank, count: columns), count: rows)
        cursorRow = 0
        cursorColumn = 0
    }

    private func leaveAlternateScreen() {
        guard let saved = mainScreen else { return }
        grid = saved.grid
        cursorRow = min(saved.cursor.0, rows - 1)
        cursorColumn = min(saved.cursor.1, columns - 1)
        mainScreen = nil
    }

    // MARK: - Attributs

    private func selectGraphicRendition(_ values: [Int], raw: String) {
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: style = .plain
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = .indexed(code - 30)
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(code - 40)
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(code - 90 + 8)
            case 100...107: style.background = .indexed(code - 100 + 8)
            case 38, 48:
                // `38;5;n` (palette) ou `38;2;r;g;b` (vraies couleurs).
                let isForeground = code == 38
                guard index + 1 < values.count else { index = values.count; break }
                let selector = values[index + 1]
                if selector == 5, index + 2 < values.count {
                    let color = TerminalColor.indexed(values[index + 2])
                    isForeground ? (style.foreground = color) : (style.background = color)
                    index += 2
                } else if selector == 2, index + 4 < values.count {
                    let color = TerminalColor.rgb(UInt8(clamping: values[index + 2]),
                                                 UInt8(clamping: values[index + 3]),
                                                 UInt8(clamping: values[index + 4]))
                    isForeground ? (style.foreground = color) : (style.background = color)
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    // MARK: - Écriture et défilement

    private func put(_ character: Character) {
        if wrapPending, autoWrap {
            cursorColumn = 0
            lineFeed()
            wrapPending = false
        }
        guard cursorRow < rows, cursorColumn < columns else { return }
        grid[cursorRow][cursorColumn] = TerminalCell(character: character, style: style)
        if cursorColumn == columns - 1 {
            // On ne passe pas à la ligne tout de suite : un `\r` reçu juste après
            // doit ramener sur la même ligne, pas sur la suivante.
            wrapPending = true
        } else {
            cursorColumn += 1
        }
    }

    private func lineFeed() {
        wrapPending = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private func reverseIndex() {
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    private func scrollUp(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        // Seule une région couvrant tout l'écran principal alimente l'historique :
        // le défilement d'une sous-région appartient à l'application.
        let feedsScrollback = mainScreen == nil && scrollTop == 0 && scrollBottom == rows - 1
        for _ in 0..<count {
            let removed = grid.remove(at: scrollTop)
            if feedsScrollback { scrollback.append(removed) }
            grid.insert(Array(repeating: .blank, count: columns), at: scrollBottom)
        }
        if feedsScrollback { trimScrollback() }
    }

    private func scrollDown(_ count: Int) {
        let count = min(count, scrollBottom - scrollTop + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: .blank, count: columns), at: scrollTop)
        }
    }

    private func trimScrollback() {
        if scrollback.count > Self.scrollbackLimit {
            scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
        }
    }

    // MARK: - Effacements

    private func eraseInDisplay(_ mode: Int) {
        let blankLine = Array(repeating: TerminalCell(character: " ", style: style), count: columns)
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows { grid[row] = blankLine }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { grid[row] = blankLine }
        case 2, 3:
            if mode == 3 { scrollback.removeAll() }
            for row in 0..<rows { grid[row] = blankLine }
        default:
            break
        }
    }

    private func eraseInLine(_ mode: Int) {
        guard cursorRow < rows else { return }
        let blank = TerminalCell(character: " ", style: style)
        switch mode {
        case 0: for column in cursorColumn..<columns { grid[cursorRow][column] = blank }
        case 1: for column in 0...min(cursorColumn, columns - 1) { grid[cursorRow][column] = blank }
        case 2: grid[cursorRow] = Array(repeating: blank, count: columns)
        default: break
        }
    }

    private func eraseCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        let blank = TerminalCell(character: " ", style: style)
        for column in cursorColumn..<min(columns, cursorColumn + count) {
            grid[cursorRow][column] = blank
        }
    }

    private func insertLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            grid.remove(at: scrollBottom)
            grid.insert(Array(repeating: .blank, count: columns), at: cursorRow)
        }
    }

    private func deleteLines(_ count: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        for _ in 0..<min(count, scrollBottom - cursorRow + 1) {
            grid.remove(at: cursorRow)
            grid.insert(Array(repeating: .blank, count: columns), at: scrollBottom)
        }
    }

    private func insertCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        for _ in 0..<count {
            grid[cursorRow].insert(TerminalCell(character: " ", style: style), at: cursorColumn)
            grid[cursorRow].removeLast()
        }
    }

    private func deleteCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        for _ in 0..<count {
            guard cursorColumn < grid[cursorRow].count else { break }
            grid[cursorRow].remove(at: cursorColumn)
            grid[cursorRow].append(TerminalCell(character: " ", style: style))
        }
    }

    // MARK: - Rendu

    /// Lignes prêtes à afficher, historique compris.
    ///
    /// Les cellules sont regroupées en séries de même style : une ligne de 120
    /// caractères devient deux ou trois fragments, pas 120 — ce qui change tout
    /// pour le coût de rendu.
    func displayLines(includingScrollback: Bool) -> [TerminalDisplayLine] {
        let source = includingScrollback ? scrollback + grid : grid
        let scrollbackCount = includingScrollback ? scrollback.count : 0
        return source.enumerated().map { index, cells in
            TerminalDisplayLine(id: index, runs: runs(of: cells),
                                isCursorLine: index - scrollbackCount == cursorRow)
        }
    }

    private func runs(of cells: [TerminalCell]) -> [TerminalRun] {
        // On ignore les blancs de fin : les afficher étirerait chaque ligne à la
        // largeur de la grille et casserait la sélection de texte.
        var trimmed = cells
        while let last = trimmed.last, last.character == " ", last.style.background == .default {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return [] }

        var result: [TerminalRun] = []
        var text = String(trimmed[0].character)
        var current = trimmed[0].style
        for cell in trimmed.dropFirst() {
            if cell.style == current {
                text.append(cell.character)
            } else {
                result.append(TerminalRun(text: text, style: current))
                text = String(cell.character)
                current = cell.style
            }
        }
        result.append(TerminalRun(text: text, style: current))
        return result
    }
}

struct TerminalDisplayLine: Identifiable {
    let id: Int
    let runs: [TerminalRun]
    let isCursorLine: Bool

    var plainText: String { runs.map(\.text).joined() }
}

struct TerminalRun: Identifiable {
    let text: String
    let style: TerminalStyle
    var id: String { text }
}

// MARK: - Palette

extension TerminalColor {
    /// Palette xterm : 16 couleurs de base, cube 6×6×6, puis 24 gris.
    func color(isBackground: Bool, bold: Bool) -> Color? {
        switch self {
        case .default:
            return isBackground ? nil : Color.terminalForeground
        case .rgb(let red, let green, let blue):
            return Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255,
                         blue: Double(blue) / 255, opacity: 1)
        case .indexed(let index):
            if index < 16 {
                // Le gras éclaircit les huit couleurs sombres, comme un vrai xterm.
                let effective = (bold && index < 8) ? index + 8 : index
                return Color.terminalPalette[min(effective, 15)]
            }
            if index < 232 {
                let offset = index - 16
                let steps: [Double] = [0, 0.373, 0.529, 0.686, 0.843, 1]
                return Color(.sRGB,
                             red: steps[(offset / 36) % 6],
                             green: steps[(offset / 6) % 6],
                             blue: steps[offset % 6], opacity: 1)
            }
            let level = Double(index - 232) / 23
            return Color(.sRGB, red: level, green: level, blue: level, opacity: 1)
        }
    }
}

extension Color {
    /// Couleurs du terminal : fond sombre constant, quel que soit le thème du
    /// système. Un shell sur fond clair se lit mal, et l'habitude visuelle d'un
    /// administrateur compte plus ici que la cohérence avec le reste de l'app.
    static let terminalBackground = Color(.sRGB, red: 0.055, green: 0.067, blue: 0.09, opacity: 1)
    static let terminalForeground = Color(.sRGB, red: 0.878, green: 0.902, blue: 0.941, opacity: 1)

    static let terminalPalette: [Color] = [
        Color(.sRGB, red: 0.18, green: 0.20, blue: 0.25, opacity: 1),   // noir
        Color(.sRGB, red: 0.94, green: 0.33, blue: 0.40, opacity: 1),   // rouge
        Color(.sRGB, red: 0.34, green: 0.83, blue: 0.55, opacity: 1),   // vert
        Color(.sRGB, red: 0.95, green: 0.75, blue: 0.35, opacity: 1),   // jaune
        Color(.sRGB, red: 0.38, green: 0.65, blue: 0.96, opacity: 1),   // bleu
        Color(.sRGB, red: 0.78, green: 0.55, blue: 0.96, opacity: 1),   // magenta
        Color(.sRGB, red: 0.32, green: 0.80, blue: 0.83, opacity: 1),   // cyan
        Color(.sRGB, red: 0.80, green: 0.83, blue: 0.87, opacity: 1),   // blanc
        Color(.sRGB, red: 0.36, green: 0.40, blue: 0.47, opacity: 1),   // gris
        Color(.sRGB, red: 0.98, green: 0.48, blue: 0.53, opacity: 1),
        Color(.sRGB, red: 0.51, green: 0.90, blue: 0.66, opacity: 1),
        Color(.sRGB, red: 0.98, green: 0.84, blue: 0.50, opacity: 1),
        Color(.sRGB, red: 0.53, green: 0.75, blue: 0.98, opacity: 1),
        Color(.sRGB, red: 0.86, green: 0.68, blue: 0.98, opacity: 1),
        Color(.sRGB, red: 0.48, green: 0.88, blue: 0.91, opacity: 1),
        Color(.sRGB, red: 0.96, green: 0.97, blue: 0.98, opacity: 1),
    ]
}
