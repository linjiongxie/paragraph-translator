import SwiftUI
import AppKit
import TranslatorCore

struct FormattedPassageView: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        let blocks = FormattedText.blocks(from: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .line(let line):
                    passageLine(line)
                        .padding(.top, CGFloat(line.blankLinesBefore) * 8 + (index == 0 ? 0 : 4))
                case .table(let table):
                    PassageTableView(table: table, fontSize: fontSize)
                        .padding(.top, CGFloat(table.blankLinesBefore) * 8 + (index == 0 ? 0 : 4))
                }
            }
        }
        .font(.system(size: fontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passageLine(_ line: FormattedText.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let marker = line.marker {
                Text(marker).frame(minWidth: 12, alignment: .trailing)
            }
            Text(line.content)
                .font(.system(size: line.headingLevel == nil ? fontSize : fontSize + 2,
                              weight: line.headingLevel == nil ? .regular : .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(line.indentation) * 4)
    }
}

private struct PassageTableView: View {
    let table: MarkdownTable.Table
    let fontSize: CGFloat

    var body: some View {
        let rows = [table.header] + table.rows
        let widths = columnWidths(rows)
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(table.displayedCells(in: row).enumerated()), id: \.offset) { column, cell in
                            Text(cell.content)
                                .font(.system(size: fontSize, weight: index == 0 ? .semibold : .regular))
                                .multilineTextAlignment(textAlignment(table.alignments[column]))
                                .frame(width: widths[column], alignment: alignment(table.alignments[column]))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                    }
                    .background(Color.primary.opacity(index == 0 ? 0.06 : (index.isMultiple(of: 2) ? 0.018 : 0)))
                    .overlay(alignment: .bottom) {
                        if index < rows.count - 1 { Divider() }
                    }
                }
            }
            .overlay {
                GeometryReader { proxy in
                    Path { path in
                        var x: CGFloat = 0
                        for width in widths.dropLast() {
                            x += width + 20
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                    }
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            .padding(.bottom, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表格，\(rows.count) 行，\(table.columnCount) 列")
    }

    private func columnWidths(_ rows: [MarkdownTable.Row]) -> [CGFloat] {
        (0..<table.columnCount).map { column in
            let longest = rows.map { row -> CGFloat in
                let cell = table.displayedCells(in: row)[column]
                return String(cell.content.characters).components(separatedBy: "\n").map {
                    ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width
                }.max() ?? 0
            }.max() ?? 0
            return min(column == 0 ? 240 : 180, max(80, longest.rounded(.up)))
        }
    }

    private func alignment(_ value: MarkdownTable.Alignment) -> SwiftUI.Alignment {
        switch value {
        case .center: return .center
        case .right: return .trailing
        case .unspecified, .left: return .leading
        }
    }

    private func textAlignment(_ value: MarkdownTable.Alignment) -> TextAlignment {
        switch value {
        case .center: return .center
        case .right: return .trailing
        case .unspecified, .left: return .leading
        }
    }
}
