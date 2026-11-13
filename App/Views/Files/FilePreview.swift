import AppKit
import PaddockKit
import SwiftUI

/// What the preview shows of one file.
enum PreviewContent {
    /// Text: your file and the copy's, by line.
    case text(TextDiff)
    /// A file that is the same on both sides (All files): its text.
    case plain([String])
    case image(original: NSImage?, copy: NSImage?)
    /// A symbolic link: the target on each side.
    case link(original: String?, copy: String?)
    /// No text and no picture: the sizes.
    case binary(original: Int64?, copy: Int64?)
    /// Neither side is on the disk any more.
    case missing
}

/// Reads both sides of a row from the disk, off the main thread.
enum PreviewLoader {
    /// Pictures above this size are not decoded for the preview.
    static let maxImageBytes = 40 * 1024 * 1024

    private struct Raw: Sendable {
        var original: Data?
        var copy: Data?
        var originalSize: Int64?
        var copySize: Int64?
    }

    private static func size(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    @MainActor
    static func load(_ row: FileRow, run: CopyRun) async -> PreviewContent {
        if let change = row.change, change.copy?.link != nil || change.original?.link != nil {
            return .link(original: change.original?.link, copy: change.copy?.link)
        }
        let copyURL = FilesPaths.url(FilesPaths.copyRoot(run), row.path)
        let originalURL = FilesPaths.url(FilesPaths.originalRoot(run), row.path)
        let isImage = FileIcons.isImage(row.path)
        let wantsOriginal = row.change != nil && row.change?.kind != .new
        let wantsCopy = row.change?.kind != .deleted
        let limit = isImage ? maxImageBytes : TextSniff.maxBytes
        let raw = await Task.detached(priority: .userInitiated) { () -> Raw in
            var sides = Raw()
            if wantsOriginal {
                sides.originalSize = PreviewLoader.size(originalURL)
                if let bytes = sides.originalSize, bytes <= limit { sides.original = try? Data(contentsOf: originalURL) }
            }
            if wantsCopy {
                sides.copySize = PreviewLoader.size(copyURL)
                if let bytes = sides.copySize, bytes <= limit { sides.copy = try? Data(contentsOf: copyURL) }
            }
            return sides
        }.value
        if raw.originalSize == nil, raw.copySize == nil { return .missing }
        if isImage {
            let original = raw.original.flatMap { NSImage(data: $0) }
            let copy = raw.copy.flatMap { NSImage(data: $0) }
            if original != nil || copy != nil { return .image(original: original, copy: copy) }
            return .binary(original: raw.originalSize, copy: raw.copySize)
        }
        // A side that is not there is an empty text: a new file is all
        // added lines, a deleted file all removed lines.
        let old = wantsOriginal ? raw.original : Data()
        let new = wantsCopy ? raw.copy : Data()
        guard let old, let new, TextSniff.isText(old), TextSniff.isText(new) else {
            return .binary(original: raw.originalSize, copy: raw.copySize)
        }
        let oldText = String(decoding: old, as: UTF8.self)
        let newText = String(decoding: new, as: UTF8.self)
        if row.change == nil { return .plain(TextSniff.lines(newText)) }
        return await Task.detached(priority: .userInitiated) { TextDiff(old: oldText, new: newText) }.value.asContent
    }
}

private extension TextDiff {
    var asContent: PreviewContent { .text(self) }
}

// MARK: - The preview pane

/// The right pane: the file that is selected, with its three actions, and
/// what changed in it.
@MainActor
struct FilePreview: View {
    let doc: ChangesDoc
    /// The selected rows.
    let rows: [FileRow]
    let actions: FileActions
    @State private var content: PreviewContent?
    @State private var loaded: String?
    @AppStorage("filesDiffUnified", store: LauncherDefaults.store) private var unified = false
    @AppStorage("filesDiffWhole", store: LauncherDefaults.store) private var whole = false
    @AppStorage("filesImageSlider", store: LauncherDefaults.store) private var slider = false

    var body: some View {
        Group {
            if rows.count == 1, let row = rows.first {
                VStack(spacing: 0) {
                    PreviewHeader(row: row, actions: actions)
                    Divider()
                    contentView(row)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .task(id: key(row)) {
                    if loaded != key(row) { content = nil }
                    let result = await PreviewLoader.load(row, run: doc.run)
                    guard !Task.isCancelled else { return }
                    content = result
                    loaded = key(row)
                }
            } else if rows.count > 1 {
                ManySelected(rows: rows, actions: actions)
            } else {
                PreviewSummary(doc: doc)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Preview"))
        .accessibilityIdentifier("files-preview")
    }

    /// The preview loads again when the file changes on either side.
    private func key(_ row: FileRow) -> String {
        let copySize: Int64 = row.change?.copy?.size ?? row.size ?? -1
        let copyTime: Double = row.change?.copy?.mtime?.timeIntervalSince1970 ?? row.time?.timeIntervalSince1970 ?? 0
        let originalSize: Int64 = row.change?.original?.size ?? -1
        let originalTime: Double = row.change?.original?.mtime?.timeIntervalSince1970 ?? 0
        let parts: [String] = [row.path, String(copySize), String(copyTime), String(originalSize), String(originalTime)]
        return parts.joined(separator: "|")
    }

    @ViewBuilder private func contentView(_ row: FileRow) -> some View {
        switch content {
        case nil:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(Text("Reading the file"))
        case .text(let diff)?:
            VStack(spacing: 0) {
                HStack(spacing: Space.m) {
                    Text(verbatim: FilesCopy.lineParts(added: diff.added, removed: diff.removed)
                        .map(\.localized).joined(separator: UIText(", ").localized))
                        .font(.callout)
                        .labelInk()
                        .accessibilityIdentifier("diff-stat")
                    Spacer(minLength: Space.s)
                    Toggle("Whole file", isOn: $whole)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("diff-whole-toggle")
                    Toggle("Unified", isOn: $unified)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityIdentifier("diff-unified-toggle")
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
                if diff.coarse {
                    Text("The two files are far apart: every line shows as removed and added.")
                        .font(.caption)
                        .labelInk()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs)
                }
                DiffView(diff: diff, unified: unified, whole: whole)
            }
        case .plain(let lines)?:
            PlainTextView(lines: lines)
        case .image(let original, let copy)?:
            ImageCompare(original: original, copy: copy, slider: $slider)
        case .link(let original, let copy)?:
            LinkPreview(original: original, copy: copy)
        case .binary(let original, let copy)?:
            NoPreview(row: row, original: original, copy: copy, actions: actions)
        case .missing?:
            PlainEmpty {
                Label { Text("The file is gone") } icon: { DecorativeSymbol(name: "questionmark.folder") }
            } description: {
                Text("It is neither in the copy nor in your folder any more.")
            } actions: {
                EmptyView()
            }
        }
    }
}

/// The head of the preview: the icon, the name, the path, the mark, the
/// sentence of a conflict, and Apply to original, Keep in the copy and
/// Discard.
@MainActor
private struct PreviewHeader: View {
    let row: FileRow
    let actions: FileActions

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.m) {
                FinderIcon(image: FileIcons.icon(row.path), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.name)
                        .font(.headline)
                        .labelInk()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("files-preview-title")
                    Text(verbatim: row.path)
                        .font(.caption)
                        .labelInk()
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Space.s)
                if row.mark != .same {
                    MarkLabel(mark: row.mark, font: .callout)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, 3)
                        .quietCapsule()
                        .accessibilityIdentifier("files-preview-mark")
                }
            }
            if row.mark == .conflict, let text = row.change?.conflictText {
                ProblemLine {
                    Text(verbatim: text).font(.callout).labelInk().fixedSize(horizontal: false, vertical: true)
                }
            }
            if row.change?.writing == true {
                Label {
                    Text("The agent is writing this file. Wait for it before you apply.")
                } icon: {
                    DecorativeSymbol(name: "pencil.line")
                }
                .font(.callout)
                .labelInk()
            }
            if row.isChange {
                HStack(spacing: Space.s) {
                    Button {
                        actions.apply([row.path])
                    } label: {
                        Label("Apply to Original…", systemImage: "arrow.down.doc")
                    }
                    .help(Text("Put this change into your folder (⌘↩)"))
                    .accessibilityIdentifier("files-row-apply")
                    Button {
                        actions.keep([row.path])
                    } label: {
                        Label("Keep in the Copy", systemImage: "pause.circle")
                    }
                    .disabled(row.mark == .kept)
                    .help(Text("Leave this change in the copy when you apply the others (⌘K)"))
                    .accessibilityIdentifier("files-row-keep")
                    Button(role: .destructive) {
                        actions.discard([row.path])
                    } label: {
                        Label("Discard…", systemImage: "trash")
                    }
                    .help(Text("Delete this change from the copy (⌘⌫)"))
                    .accessibilityIdentifier("files-row-discard")
                }
                .controlSize(.small)
                .disabled(!actions.enabled)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// More than one file is selected: the count and the three actions.
@MainActor
private struct ManySelected: View {
    let rows: [FileRow]
    let actions: FileActions

    var body: some View {
        let paths = rows.filter(\.isChange).map(\.path)
        PlainEmpty {
            Label { Text(UIText("%lld files selected", rows.count)) } icon: { DecorativeSymbol(name: "doc.on.doc") }
        } description: {
            Text(FilesCopy.changes(paths.count))
        } actions: {
            HStack(spacing: Space.s) {
                Button("Apply to Original…") { actions.apply(paths) }
                    .accessibilityIdentifier("files-many-apply")
                Button("Keep in the Copy") { actions.keep(paths) }
                Button("Discard…", role: .destructive) { actions.discard(paths) }
            }
            .disabled(paths.isEmpty || !actions.enabled)
        }
    }
}

/// Nothing is selected: what the copy holds, in a few lines.
@MainActor
private struct PreviewSummary: View {
    let doc: ChangesDoc

    var body: some View {
        PlainEmpty {
            Label {
                Text("Select a file to see what changed")
            } icon: {
                DeskModel(glows: ApplyMotion.glows(doc.counts), size: 72)
            }
        } description: {
            VStack(spacing: Space.xs) {
                Text(FilesCopy.waiting(doc.counts))
                if !doc.applied.isEmpty {
                    Text(doc.applied.count == 1 ? UIText("1 file is in your folder already")
                        : UIText("%lld files are in your folder already", doc.applied.count))
                }
                if doc.run.state == .live {
                    Text("The agent still works. The list follows it.")
                }
                if doc.autoApply {
                    Text("paddock applies the changes by itself when the run ends.")
                }
            }
            .font(.callout)
        } actions: {
            EmptyView()
        }
        .accessibilityIdentifier("files-summary")
    }
}

// MARK: - Text

/// The font and the colors of the diff.
enum DiffStyle {
    static let font = Font.system(size: 11.5, design: .monospaced)
    static let numberFont = Font.system(size: 10, design: .monospaced)
    static let removed = Color.red.opacity(0.14)
    static let added = Color.green.opacity(0.16)
    static let none = Color.primary.opacity(0.035)

    /// The width of a line number column for numbers up to `count`.
    static func gutter(_ count: Int) -> CGFloat {
        CGFloat(max(2, String(count).count)) * 6.5 + 10
    }

    /// A line as it shows: a tab is four spaces, an empty line keeps its height.
    static func shown(_ text: String) -> String {
        if text.isEmpty { return " " }
        return text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
    }
}

/// The diff of a text file. Side by side: your file left, the copy's
/// right, each with its line numbers. Unified: one column with both
/// numbers. Lines that did not change are folded unless `whole`.
@MainActor
struct DiffView: View {
    let diff: TextDiff
    let unified: Bool
    let whole: Bool

    var body: some View {
        let context: Int? = whole ? nil : 3
        let gutter = DiffStyle.gutter(diff.lines.count)
        VStack(spacing: 0) {
            if !unified {
                HStack(spacing: 0) {
                    sideTitle(Text("Your folder"))
                    Divider().frame(height: 18)
                    sideTitle(Text("The copy"))
                }
                .background(.bar)
                Divider()
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if unified {
                        ForEach(diff.unified(context: context)) { line in
                            UnifiedLine(line: line, gutter: gutter)
                        }
                    } else {
                        ForEach(diff.rows(context: context)) { row in
                            SideBySideLine(row: row, gutter: gutter)
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(unified ? Text("Changes, unified") : Text("Changes, side by side"))
        .accessibilityIdentifier("diff-view")
    }

    private func sideTitle(_ text: Text) -> some View {
        text.font(.caption.weight(.semibold))
            .labelInk()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 3)
    }
}

/// `16 lines the same`, in place of the lines.
@MainActor
private struct FoldLine: View {
    let count: Int

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "ellipsis").accessibilityHidden(true)
            Text(count == 1 ? UIText("1 line the same") : UIText("%lld lines the same", count))
        }
        .font(.caption)
        .labelInk()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(DiffStyle.none)
        .accessibilityElement(children: .combine)
    }
}

/// One side of a line: the number, the sign and the text.
@MainActor
private struct DiffSide: View {
    let side: DiffRow.Side?
    /// `−` for your side of a change, `+` for the copy's, nil for a same line.
    let sign: String?
    let fill: Color
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(verbatim: side.map { String($0.number) } ?? "")
                .font(DiffStyle.numberFont)
                .labelInk()
                .frame(width: gutter, alignment: .trailing)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(verbatim: side == nil ? "" : (sign ?? ""))
                .font(DiffStyle.font)
                .labelInk()
                .frame(width: 14)
                .accessibilityLabel(sign == "+" ? Text("Added") : Text("Removed"))
                .accessibilityHidden(sign == nil || side == nil)
            Text(verbatim: DiffStyle.shown(side?.text ?? ""))
                .font(DiffStyle.font)
                .labelInk()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.trailing, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(side == nil ? DiffStyle.none : fill)
    }
}

@MainActor
private struct SideBySideLine: View {
    let row: DiffRow
    let gutter: CGFloat

    var body: some View {
        if case .fold(let count) = row.kind {
            FoldLine(count: count)
        } else {
            let changed = row.kind != .same
            HStack(alignment: .top, spacing: 0) {
                DiffSide(side: row.left, sign: changed ? "−" : nil, fill: changed ? DiffStyle.removed : .clear,
                         gutter: gutter)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .accessibilityHidden(true)
                DiffSide(side: row.right, sign: changed ? "+" : nil, fill: changed ? DiffStyle.added : .clear,
                         gutter: gutter)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor
private struct UnifiedLine: View {
    let line: DiffLine
    let gutter: CGFloat

    var body: some View {
        if TextDiff.isFold(line) {
            FoldLine(count: Int(line.text) ?? 0)
        } else {
            HStack(alignment: .top, spacing: 0) {
                number(line.left)
                number(line.right)
                Text(verbatim: sign)
                    .font(DiffStyle.font)
                    .labelInk()
                    .frame(width: 14)
                    .accessibilityLabel(line.kind == .added ? Text("Added") : Text("Removed"))
                    .accessibilityHidden(line.kind == .same)
                Text(verbatim: DiffStyle.shown(line.text))
                    .font(DiffStyle.font)
                    .labelInk()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, Space.xs)
            .background(fill)
        }
    }

    private var sign: String {
        switch line.kind {
        case .same: return ""
        case .removed: return "−"
        case .added: return "+"
        }
    }

    private var fill: Color {
        switch line.kind {
        case .same: return .clear
        case .removed: return DiffStyle.removed
        case .added: return DiffStyle.added
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .font(DiffStyle.numberFont)
            .labelInk()
            .frame(width: gutter, alignment: .trailing)
            .padding(.top, 1)
            .accessibilityHidden(true)
    }
}

/// The text of a file that did not change, with line numbers.
@MainActor
private struct PlainTextView: View {
    let lines: [String]

    var body: some View {
        let gutter = DiffStyle.gutter(lines.count)
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                    DiffSide(side: DiffRow.Side(number: index + 1, text: text), sign: nil, fill: .clear, gutter: gutter)
                }
            }
            .textSelection(.enabled)
        }
        .accessibilityIdentifier("plain-text-view")
    }
}

// MARK: - Pictures

/// A gray check pattern behind a picture, so transparent parts show.
@MainActor
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 8
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : step
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: step, height: step)), with: .color(Color.primary.opacity(0.06)))
                    x += step * 2
                }
                y += step
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}

/// Two pictures: side by side, or one over the other with a slider that
/// uncovers the copy's from the right.
@MainActor
struct ImageCompare: View {
    let original: NSImage?
    let copy: NSImage?
    @Binding var slider: Bool
    @State private var position: CGFloat = 0.5

    var body: some View {
        VStack(spacing: 0) {
            if original != nil, copy != nil {
                HStack {
                    Picker(selection: $slider) {
                        Text("Side by side").tag(false)
                        Text("Slider").tag(true)
                    } label: {
                        Text("Compare")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("image-compare-mode")
                    Spacer()
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            }
            if let original, let copy {
                if slider {
                    sliderView(original, copy)
                } else {
                    HStack(spacing: Space.m) {
                        panel(original, title: Text("Your folder"))
                        panel(copy, title: Text("The copy"))
                    }
                    .padding(Space.m)
                }
            } else if let copy {
                panel(copy, title: Text("The copy")).padding(Space.m)
            } else if let original {
                panel(original, title: Text("Your folder")).padding(Space.m)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("image-compare")
    }

    /// `640 × 480`.
    private func pixels(_ image: NSImage) -> String {
        let rep = image.representations.first
        let width = rep.map(\.pixelsWide).flatMap { $0 > 0 ? $0 : nil } ?? Int(image.size.width)
        let height = rep.map(\.pixelsHigh).flatMap { $0 > 0 ? $0 : nil } ?? Int(image.size.height)
        return "\(width) × \(height)"
    }

    private func picture(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }

    private func panel(_ image: NSImage, title: Text) -> some View {
        VStack(spacing: Space.s) {
            picture(image)
                .background(Checkerboard())
                .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(title)
            VStack(spacing: 1) {
                title.font(.caption.weight(.semibold))
                Text(verbatim: pixels(image)).font(.caption).monospacedDigit()
            }
            .labelInk()
        }
    }

    private func sliderView(_ original: NSImage, _ copy: NSImage) -> some View {
        VStack(spacing: Space.s) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Checkerboard()
                    picture(copy).frame(width: width, height: proxy.size.height)
                    // Your picture covers the left part, up to the handle.
                    picture(original)
                        .frame(width: width, height: proxy.size.height)
                        .background(Color(nsColor: .textBackgroundColor))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, width * position))
                        }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                        .overlay {
                            Image(systemName: "arrow.left.and.right.circle.fill")
                                .font(.system(size: 22))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.accentColor)
                        }
                        .offset(x: width * position - 1)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard width > 0 else { return }
                    position = min(1, max(0, value.location.x / width))
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Compare slider"))
                .accessibilityValue(Text(UIText("%lld percent of your picture shows", Int((position * 100).rounded()))))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: position = min(1, position + 0.1)
                    case .decrement: position = max(0, position - 0.1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("image-slider")
            }
            HStack {
                Text("Your folder")
                Spacer()
                Text("The copy")
            }
            .font(.caption.weight(.semibold))
            .labelInk()
        }
        .padding(Space.m)
    }
}

// MARK: - Links and other files

/// A symbolic link: where it points on each side.
@MainActor
private struct LinkPreview: View {
    let original: String?
    let copy: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label { Text("Symbolic link") } icon: { DecorativeSymbol(name: "link") }
                .font(.headline)
            LabeledContent {
                Text(verbatim: original ?? "—").font(.callout.monospaced()).textSelection(.enabled)
            } label: {
                Text("Your folder")
            }
            LabeledContent {
                Text(verbatim: copy ?? "—").font(.callout.monospaced()).textSelection(.enabled)
            } label: {
                Text("The copy")
            }
        }
        .labelInk()
        .frame(maxWidth: .infinity, alignment: .leading)
        .quietPanel()
        .padding(Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("link-preview")
    }
}

/// A file that is no text and no picture: its sizes, and Quick Look.
@MainActor
private struct NoPreview: View {
    let row: FileRow
    let original: Int64?
    let copy: Int64?
    let actions: FileActions

    var body: some View {
        PlainEmpty {
            Label { Text("No preview for this file") } icon: { FinderIcon(image: FileIcons.icon(row.path), size: 56) }
        } description: {
            VStack(spacing: Space.xs) {
                if let original {
                    Text(UIText("Your folder: %@", FilesCopy.size(original).localized))
                }
                if let copy {
                    Text(UIText("The copy: %@", FilesCopy.size(copy).localized))
                }
            }
            .font(.callout)
        } actions: {
            Button("Quick Look") { actions.quickLook(row.path) }
                .help(Text("Open the file in Quick Look (Space)"))
        }
        .accessibilityIdentifier("no-preview")
    }
}
