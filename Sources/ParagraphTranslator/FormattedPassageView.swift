import SwiftUI
import TranslatorCore

struct FormattedPassageView: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        let lines = FormattedText.lines(from: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
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
                .padding(.top, CGFloat(line.blankLinesBefore) * 8 + (index == 0 ? 0 : 4))
            }
        }
        .font(.system(size: fontSize))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
