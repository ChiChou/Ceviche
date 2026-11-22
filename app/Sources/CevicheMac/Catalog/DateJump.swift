import SwiftUI
import CevicheCore

/// A month to scroll the library or the Faces wall to, asked for from the status bar. Each request is new, so the same
/// month can be asked for twice.
struct DateJumpRequest: Equatable {
    /// `YYYY-MM`.
    let month: String
    let id = UUID()
}

/// The status bar's calendar button for a date-sorted view: the years of the photos shown, with the months that hold
/// any of them, each going to its first photo.
struct DateJumpButton: View {
    @ObservedObject var model: CatalogModel
    @State private var showing = false
    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "calendar").font(.system(size: 14)).frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable(false)
        .help(L10n.tr("Go to Date")).accessibilityLabel(L10n.tr("Go to Date"))
        .popover(isPresented: $showing, arrowEdge: .top) {
            DateJumpList(model: model) { month in
                showing = false
                model.dateJump = DateJumpRequest(month: month)
            }
        }
    }
}

/// Years with photos, newest first, each with its twelve months; months without photos are dimmed.
private struct DateJumpList: View {
    @ObservedObject var model: CatalogModel
    let choose: (String) -> Void
    @State private var months: Set<String>?
    var body: some View {
        Group {
            if let months, !months.isEmpty {
                let years = Set(months.compactMap { Int($0.prefix(4)) }).sorted()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(years.reversed(), id: \.self) { year in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(year)).font(.headline).monospacedDigit()
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                                    ForEach(1...12, id: \.self) { number in
                                        let month = String(format: "%04d-%02d", year, number)
                                        Button(Self.shortName(number)) { choose(month) }
                                            .buttonStyle(.secondaryAction).controlSize(.small)
                                            .disabled(!months.contains(month))
                                    }
                                }
                            }
                        }
                    }.padding(14)
                }
                // A scroll view in a popover takes no height of its own: about 76 points a year, up to 420.
                .frame(width: 340, height: min(420, CGFloat(years.count) * 76 + 28))
            } else {
                Text(months == nil ? "" : L10n.tr("No dated photos.")).font(.callout).foregroundStyle(.secondary).frame(width: 220, height: 60)
            }
        }
        .task { months = (try? await model.store?.captureMonths(filter: model.filter)) ?? [] }
    }
    static func shortName(_ month: Int) -> String {
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        let names = formatter.shortStandaloneMonthSymbols ?? []
        return names.indices.contains(month - 1) ? names[month - 1] : String(month)
    }
}
