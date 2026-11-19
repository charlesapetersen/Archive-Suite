import SwiftUI

/// The settings sheet's stage cards and rule stages inside a Settings panel (W47.settings-panels): each stage is set in
/// the panel that holds it, with the same model and writer as the modal sheet (`SettingsSheetHost`), at the Settings
/// window's scale of 1,000 pages. Every card keeps its "See the range" link, which opens the sheet's Range view.
struct SettingsStageCards: View {
    /// The card stages to show (`SettingsSheetModel.cardStages`), in this order.
    var cards: [String] = []
    /// The rule stages to show (`SettingsSheetModel.ruleStageIDs`), in this order.
    var rules: [String] = []
    /// The limits and this batch's totals, above the cards (the Collection panel).
    var limits = false

    @State private var showingRange = false
    private let folder = SettingsSheetButton.outputFolder()

    var body: some View {
        SettingsSheetHost(outputFolder: folder, pages: 1000) { model, actions in
            if let model {
                VStack(alignment: .leading, spacing: 12) {
                    if limits { SheetLimitsAndTotals(model: model) }
                    ForEach(cards, id: \.self) { id in
                        if let card = model.cards.first(where: { $0.id == id }) {
                            StageCardView(card: card, choose: { actions.choose(card.id, $0) },
                                          backToApp: { actions.choose(card.id, nil) }, apply: actions.apply,
                                          seeRange: { showingRange = true })
                            ForEach(model.stageSwitches[card.id] ?? []) { sw in
                                SheetSwitchRow(row: sw, setSwitch: actions.setSwitch)
                            }
                        }
                    }
                    ForEach(rules, id: \.self) { id in
                        if let stage = model.ruleStages.first(where: { $0.id == id }) {
                            RuleStageBox(stage: stage, setSwitch: actions.setSwitch, setStrings: actions.setStrings)
                        }
                    }
                    if let message = actions.problem {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("The measured figures are missing from this build, so the app's picks cannot be shown.")
                    .font(.caption)
            }
        }
        .sheet(isPresented: $showingRange) {
            SettingsSheetView(outputFolder: folder, pages: 1000, pagesCaption: "for 1,000 pages",
                              initialTab: .range) { showingRange = false }
        }
    }
}
