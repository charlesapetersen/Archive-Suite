import SwiftUI

struct ContainerFacetFilterPopover: View {
    @ObservedObject var model: NavigationModel
    @State private var facet: ContainerFacet
    @Environment(\.dismiss) private var dismiss

    init(model: NavigationModel) {
        self.model = model
        let initial = model.filter.activeContainerFacets.first?.facet
            ?? ContainerFacet.allCases.first { !model.containerCatalog.facetValues($0).isEmpty }
            ?? .container
        _facet = State(initialValue: initial)
    }

    var body: some View {
        let constraints = Set(model.filter.activeContainerFacets.map { ContainerCatalog.FacetConstraint($0.facet, $0.value) })
        VStack(alignment: .leading, spacing: 10) {
            Picker("Container facet", selection: $facet) {
                ForEach(ContainerFacet.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ContainerFacetValuesView(scope: .init(facet: facet, constraints: constraints,
                                                  revision: model.containerCatalogRevision),
                                     catalog: model.containerCatalog, selected: model.filter.containerFacet(facet),
                                     clear: { model.filter.setContainerFacet(facet, nil) },
                                     choose: { model.filter.setContainerFacet(facet, $0) })
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("ar.containerFacet.done")
            }
        }
        .padding(12)
        .frame(width: 484)
    }
}

/// The searchable value list shared by the filter bar and Advanced Search.
struct ContainerFacetValuesView: View {
    struct Scope: Hashable, Sendable {
        let facet: ContainerFacet
        let constraints: Set<ContainerCatalog.FacetConstraint>
        let revision: Int

        init(facet: ContainerFacet, constraints: Set<ContainerCatalog.FacetConstraint>, revision: Int) {
            self.facet = facet
            self.constraints = constraints.filter { $0.facet != facet }
            self.revision = revision
        }
    }

    let scope: Scope
    let catalog: ContainerCatalog
    let selected: String?
    var clear: (() -> Void)?
    let choose: (String) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var loaded: (Scope, [ContainerCatalog.FacetValue])?

    var body: some View {
        let values = scope.constraints.isEmpty ? catalog.facetValues(scope.facet)
            : loaded.flatMap { $0.0 == scope ? $0.1 : nil }
        let matches = values.map { ContainerCatalog.filter($0, matching: query) }
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find \(scope.facet.label.lowercased()) values", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("ar.containerFacet.search")
                .onSubmit {
                    if let matches, matches.count == 1 { choose(matches[0].value) }
                }
            if let clear {
                Button("Any \(scope.facet.label.lowercased())", action: clear)
                    .disabled(selected == nil)
            }
            Divider()
            ScrollView {
                if let matches {
                    if matches.isEmpty {
                        Text(query.isEmpty && !scope.constraints.isEmpty
                             ? "No values match the other facets" : "No matching values")
                            .foregroundStyle(.secondary)
                    }
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let selectedKey = selected.map(ContainerFacet.key)
                        ForEach(matches, id: \.key) { value in
                            Button { choose(value.value) } label: {
                                HStack {
                                    Text(value.value)
                                    Spacer()
                                    Text(value.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                                    if selectedKey != nil {
                                        Image(systemName: "checkmark")
                                            .opacity(value.key == selectedKey ? 1 : 0)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(value.value) (\(value.count.formatted()))")
                            .accessibilityAddTraits(value.key == selectedKey ? .isSelected : [])
                        }
                    }
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Counting values")
                }
            }
            .frame(height: 240)
        }
        .onAppear { searchFocused = true }
        .onChange(of: scope.facet) {
            query = ""
            searchFocused = true
        }
        .task(id: scope) {
            guard !scope.constraints.isEmpty else { return }
            let scope = scope
            let worker = Task.detached(priority: .userInitiated) {
                catalog.facetValues(scope.facet, narrowedBy: scope.constraints)
            }
            let values = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled { loaded = (scope, values) }
        }
    }
}
