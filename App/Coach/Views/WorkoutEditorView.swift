import SwiftUI
import MazidiContent
import MazidiDomain
import MazidiFoundations

/// Workout editor (turn 6d/6e): title, ordered exercises with type-aware prescriptions,
/// reordering, draft autosave on every mutation, publish, and assign. The domain owns
/// validation and immutability; this view only edits the draft.
struct WorkoutEditorView: View {
    @Bindable var model: CoachProgrammingModel
    let template: WorkoutTemplate

    @State private var title: String
    @State private var showAddExercise = false
    @State private var editingExercise: PrescribedExercise?
    @State private var showAssign = false
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Always render the freshest template state from the model (autosaved edits).
    private var current: WorkoutTemplate {
        model.templates.first(where: { $0.id == template.id }) ?? template
    }

    init(model: CoachProgrammingModel, template: WorkoutTemplate) {
        self.model = model
        self.template = template
        _title = State(initialValue: template.draft.title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                titleField
                SectionHeader(title: "Exercises")
                exerciseRows
                Button {
                    showAddExercise = true
                } label: {
                    Label("Add exercise", systemImage: "plus")
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier("editor_add_exercise")

                publishSection
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle(current.draft.title.isEmpty ? "New workout" : current.draft.title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showAddExercise) {
            CatalogueExercisePicker(
                store: model.catalogueStore,
                content: modelContent,
                media: model.media
            ) { slug, selectedLabel in
                Task {
                    await model.updateDraft(current) { draft in
                        draft.exercises.append(PrescribedExercise(
                            slug: slug,
                            order: draft.exercises.count,
                            prescription: .repsAndLoad(sets: 3, reps: 8...12, loadKg: nil),
                            // Freeze the label the coach saw at selection (ADR-0011 §2);
                            // the slug remains the stable identity.
                            selectedLabel: selectedLabel
                        ))
                    }
                }
            }
        }
        .sheet(item: $editingExercise) { exercise in
            PrescriptionEditorSheet(exercise: exercise, content: modelContent) { updated in
                Task {
                    await model.updateDraft(current) { draft in
                        if let index = draft.exercises.firstIndex(where: { $0.id == updated.id }) {
                            draft.exercises[index] = updated
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAssign) {
            if let version = model.latestVersion(of: current) {
                AssignWorkoutSheet(model: model, version: version)
            }
        }
    }

    private var modelContent: any ExerciseContentProviding { model.content }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Title").font(MazidiFont.caption).foregroundStyle(MazidiColor.textSecondary)
            TextField("Workout title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: MazidiMetric.minTarget)
                .accessibilityIdentifier("editor_title_field")
                .onSubmit { commitTitle() }
                .onChange(of: title) { _, _ in } // committed on submit/publish
        }
    }

    private func commitTitle() {
        guard title != current.draft.title else { return }
        Task { await model.updateDraft(current) { $0.title = title } }
    }

    @ViewBuilder private var exerciseRows: some View {
        let exercises = current.draft.exercises
        if exercises.isEmpty {
            Text("No exercises yet.")
                .font(MazidiFont.callout)
                .foregroundStyle(MazidiColor.textSecondary)
        }
        ForEach(Array(exercises.enumerated()), id: \.element.id) { index, exercise in
            exerciseRow(exercise, index: index, count: exercises.count)
        }
    }

    private func exerciseRow(_ exercise: PrescribedExercise, index: Int, count: Int) -> some View {
        // Prefer the label frozen at selection; fall back to live content, then slug.
        let name = exercise.selectedLabel ?? modelContent.content(for: exercise.slug)?.displayName ?? exercise.slug.rawValue
        return MazidiCard {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: MazidiMetric.tightSpacing))
                : AnyLayout(HStackLayout(spacing: MazidiMetric.stackSpacing))
            layout {
                Button {
                    editingExercise = exercise
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(MazidiFont.bodyEmphasis)
                            .foregroundStyle(MazidiColor.text)
                        Text(prescriptionSummary(exercise.prescription))
                            .font(MazidiFont.callout)
                            .foregroundStyle(MazidiColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor_exercise_row.\(exercise.slug.rawValue)")
                .accessibilityHint("Edit prescription")

                HStack(spacing: MazidiMetric.tightSpacing) {
                    Button {
                        move(exercise, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: MazidiMetric.minTarget, height: MazidiMetric.minTarget)
                    }
                    .buttonStyle(.mazidiSecondary)
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(name) earlier")
                    Button {
                        move(exercise, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: MazidiMetric.minTarget, height: MazidiMetric.minTarget)
                    }
                    .buttonStyle(.mazidiSecondary)
                    .disabled(index == count - 1)
                    .accessibilityLabel("Move \(name) later")
                }
            }
        }
    }

    private func move(_ exercise: PrescribedExercise, offset: Int) {
        Task {
            await model.updateDraft(current) { draft in
                guard let index = draft.exercises.firstIndex(where: { $0.id == exercise.id }) else { return }
                let target = index + offset
                guard draft.exercises.indices.contains(target) else { return }
                draft.exercises.swapAt(index, target)
                for i in draft.exercises.indices { draft.exercises[i].order = i }
            }
        }
    }

    private var publishSection: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
            SectionHeader(title: "Publish & assign")
            Text("Publishing freezes this version. Clients you assign always keep exactly what was published — later edits create new versions.")
                .font(MazidiFont.caption)
                .foregroundStyle(MazidiColor.textSecondary)
            Button("Publish version \(current.publishedVersionCount + 1)") {
                commitTitle()
                Task { _ = await model.publish(refreshedCurrent()) }
            }
            .buttonStyle(.mazidiPrimary)
            .accessibilityIdentifier("editor_publish")

            if model.latestVersion(of: current) != nil {
                Button("Assign to client…") {
                    showAssign = true
                }
                .buttonStyle(.mazidiSecondary)
                .accessibilityIdentifier("editor_assign")
            }
        }
        .padding(.top, MazidiMetric.stackSpacing)
    }

    /// Re-read after the async title commit so publish sees the freshest draft.
    private func refreshedCurrent() -> WorkoutTemplate {
        var refreshed = current
        if refreshed.draft.title != title { refreshed.draft.title = title }
        return refreshed
    }

    private func prescriptionSummary(_ p: SetPrescription) -> String {
        switch p {
        case let .repsAndLoad(sets, reps, load):
            let l = load.map { " · \(PrescriptionFormat.trimmed($0)) kg" } ?? ""
            return "\(sets) × \(reps.lowerBound)–\(reps.upperBound)\(l)"
        case let .repsOnly(sets, reps): return "\(sets) × \(reps.lowerBound)–\(reps.upperBound)"
        case let .timed(sets, seconds): return "\(sets) × \(seconds)s"
        case let .distance(sets, metres): return "\(sets) × \(metres) m"
        case let .effort(sets, rpe): return "\(sets) sets · RPE \(PrescriptionFormat.trimmed(rpe))"
        case let .unsupported(description): return "Unsupported: \(description)"
        }
    }
}

// MARK: - Catalogue-backed exercise picker (ADR-0011 §1)

/// Search / filter / preview over the canonical exercise catalogue. Selection returns the
/// stable canonical slug plus the display label frozen at selection time. Ordering is
/// deterministic (display name, slug tiebreak) so it never shifts unpredictably between
/// launches; filters combine deterministically. No live-internet dependency — everything
/// resolves from the bundled catalogue + representative media.
private struct CatalogueExercisePicker: View {
    let store: ExerciseCatalogueStore
    let content: any ExerciseContentProviding
    let media: any MediaResolving
    let onPick: (ExerciseSlug, String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Wrapper so the preview sheet can key off a value type (`ExerciseSlug` is not
    /// `Identifiable`, and we avoid retroactively conforming a domain type).
    private struct PreviewItem: Identifiable { let slug: ExerciseSlug; var id: String { slug.rawValue } }

    @State private var query = ""
    @State private var category: String?      // movement pattern
    @State private var equipment: String?
    @State private var preview: PreviewItem?

    private var results: [CatalogueRecord] {
        store.search(query, filter: CatalogueFilter(
            equipment: equipment.map { [$0] } ?? [],
            movementPatterns: category.map { [$0] } ?? []
        ))
    }

    private func label(for slug: ExerciseSlug) -> String {
        content.content(for: slug)?.displayName ?? slug.rawValue
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: MazidiMetric.tightSpacing) {
                searchField
                filters
                resultsSection(results)
            }
            .background(MazidiColor.background)
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(item: $preview) { item in
                CatalogueExercisePreview(
                    slug: item.slug,
                    label: label(for: item.slug),
                    record: store.record(for: item.slug),
                    content: content.content(for: item.slug),
                    media: media
                ) {
                    onPick(item.slug, label(for: item.slug))
                    dismiss()
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: MazidiMetric.tightSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(MazidiColor.textSecondary)
            TextField("Search exercises", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .frame(minHeight: MazidiMetric.minTarget)
                .accessibilityIdentifier("coach_exercise_search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(MazidiColor.textSecondary)
                }
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("coach_exercise_search_clear")
            }
        }
        .padding(.horizontal, MazidiMetric.cardPadding)
        .frame(minHeight: MazidiMetric.minTarget)
        .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.chipRadius, style: .continuous))
        .padding(.horizontal, MazidiMetric.screenPadding)
    }

    @ViewBuilder private var filters: some View {
        HStack(spacing: MazidiMetric.tightSpacing) {
            filterMenu(
                title: category ?? "Category",
                options: store.availableMovementPatterns,
                selection: $category,
                id: "coach_filter_category"
            )
            filterMenu(
                title: equipment ?? "Equipment",
                options: store.availableEquipment,
                selection: $equipment,
                id: "coach_filter_equipment"
            )
            Spacer()
        }
        .padding(.horizontal, MazidiMetric.screenPadding)
    }

    private func filterMenu(title: String, options: [String], selection: Binding<String?>, id: String) -> some View {
        Menu {
            Button("All") { selection.wrappedValue = nil }
            ForEach(options, id: \.self) { option in
                Button(option) { selection.wrappedValue = option }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(MazidiFont.callout)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .padding(.horizontal, MazidiMetric.cardPadding)
            .frame(minHeight: MazidiMetric.minTarget)
            .background(
                (selection.wrappedValue == nil ? MazidiColor.surface : MazidiColor.surfaceAlt),
                in: RoundedRectangle(cornerRadius: MazidiMetric.chipRadius, style: .continuous)
            )
        }
        .accessibilityIdentifier(id)
    }

    @ViewBuilder private func resultsSection(_ records: [CatalogueRecord]) -> some View {
        if store.allRecords.isEmpty {
            MessageState(
                systemImage: "exclamationmark.triangle",
                title: "Exercise library unavailable",
                message: "The catalogue couldn't be loaded. Restart the app; your drafts are safe."
            )
            .accessibilityIdentifier("coach_picker_unavailable")
            Spacer()
        } else if records.isEmpty {
            MessageState(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "No exercises match your search and filters."
            )
            .accessibilityIdentifier("coach_picker_empty")
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: MazidiMetric.tightSpacing) {
                    ForEach(records, id: \.slug) { record in
                        row(record)
                    }
                }
                .padding(MazidiMetric.screenPadding)
            }
        }
    }

    private func row(_ record: CatalogueRecord) -> some View {
        let slug = record.slug
        let name = label(for: slug)
        return HStack(spacing: MazidiMetric.stackSpacing) {
            ExercisePosterThumbnail(slug: slug, displayName: name, media: media, side: 44)
            Button {
                onPick(slug, name)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(MazidiFont.body).foregroundStyle(MazidiColor.text)
                    if !record.equipment.isEmpty {
                        Text(record.equipment.joined(separator: " · "))
                            .font(MazidiFont.caption).foregroundStyle(MazidiColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("exercise_option.\(slug.rawValue)")
            .accessibilityHint("Add to workout")

            Button {
                preview = PreviewItem(slug: slug)
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(MazidiColor.link)
                    .frame(width: MazidiMetric.minTarget, height: MazidiMetric.minTarget)
            }
            .accessibilityLabel("Preview \(name)")
            .accessibilityIdentifier("exercise_preview.\(slug.rawValue)")
        }
        .padding(MazidiMetric.cardPadding)
        .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.chipRadius, style: .continuous))
    }
}

// MARK: - Exercise preview (canonical metadata + draft coaching content)

private struct CatalogueExercisePreview: View {
    let slug: ExerciseSlug
    let label: String
    let record: CatalogueRecord?
    let content: ExerciseContent?
    let media: any MediaResolving
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                    ExerciseMediaView(slug: slug, displayName: label, media: media)

                    if content?.contentStatus == .draftRequiresHumanReview {
                        DraftBadge()
                    }

                    Text(label)
                        .font(MazidiFont.screenTitle)
                        .foregroundStyle(MazidiColor.text)
                        .accessibilityAddTraits(.isHeader)

                    if let record {
                        metadataCard(record)
                    }

                    if let description = content?.clientDescription, !description.isEmpty {
                        Text(description).font(MazidiFont.body).foregroundStyle(MazidiColor.text)
                    }
                    bulletSection("How to do it", items: content?.clientInstructions ?? [])
                    bulletSection("Common mistakes", items: content?.clientMistakes ?? [])
                }
                .padding(MazidiMetric.screenPadding)
            }
            .background(MazidiColor.background)
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("coach_exercise_preview")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd() }
                        .accessibilityIdentifier("preview_add_exercise")
                }
            }
        }
    }

    private func metadataCard(_ record: CatalogueRecord) -> some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: 6) {
                metadataRow("Equipment", record.equipment)
                metadataRow("Movement", record.movementPattern)
                metadataRow("Primary muscles", record.primaryMuscles)
                if !record.difficulty.isEmpty {
                    metadataRow("Difficulty", [record.difficulty])
                }
            }
        }
    }

    @ViewBuilder private func metadataRow(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: MazidiMetric.tightSpacing) {
                Text(title).font(MazidiFont.caption).foregroundStyle(MazidiColor.textSecondary)
                    .frame(width: 120, alignment: .leading)
                Text(values.joined(separator: " · ")).font(MazidiFont.callout).foregroundStyle(MazidiColor.text)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private func bulletSection(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                SectionHeader(title: title)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(MazidiFont.callout).foregroundStyle(MazidiColor.text)
                }
            }
        }
    }
}

// MARK: - Prescription editor (6e/7d: type-aware fields)

private struct PrescriptionEditorSheet: View {
    @State private var working: PrescribedExercise
    let content: any ExerciseContentProviding
    let onSave: (PrescribedExercise) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Kind: String, CaseIterable, Identifiable {
        case repsAndLoad = "Reps + load"
        case repsOnly = "Reps"
        case timed = "Timed"
        case distance = "Distance"
        case effort = "RPE"
        var id: String { rawValue }
    }

    @State private var kind: Kind
    @State private var sets: Int
    @State private var repsLow: Int
    @State private var repsHigh: Int
    @State private var loadKg: Double
    @State private var seconds: Int
    @State private var metres: Int
    @State private var rpe: Double
    @State private var rest: Int
    @State private var notes: String

    init(exercise: PrescribedExercise, content: any ExerciseContentProviding, onSave: @escaping (PrescribedExercise) -> Void) {
        _working = State(initialValue: exercise)
        self.content = content
        self.onSave = onSave
        switch exercise.prescription {
        case let .repsAndLoad(s, reps, load):
            _kind = State(initialValue: .repsAndLoad); _sets = State(initialValue: s)
            _repsLow = State(initialValue: reps.lowerBound); _repsHigh = State(initialValue: reps.upperBound)
            _loadKg = State(initialValue: load ?? 0); _seconds = State(initialValue: 40)
            _metres = State(initialValue: 100); _rpe = State(initialValue: 8)
        case let .repsOnly(s, reps):
            _kind = State(initialValue: .repsOnly); _sets = State(initialValue: s)
            _repsLow = State(initialValue: reps.lowerBound); _repsHigh = State(initialValue: reps.upperBound)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: 40)
            _metres = State(initialValue: 100); _rpe = State(initialValue: 8)
        case let .timed(s, secs):
            _kind = State(initialValue: .timed); _sets = State(initialValue: s)
            _repsLow = State(initialValue: 8); _repsHigh = State(initialValue: 12)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: secs)
            _metres = State(initialValue: 100); _rpe = State(initialValue: 8)
        case let .distance(s, m):
            _kind = State(initialValue: .distance); _sets = State(initialValue: s)
            _repsLow = State(initialValue: 8); _repsHigh = State(initialValue: 12)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: 40)
            _metres = State(initialValue: m); _rpe = State(initialValue: 8)
        case let .effort(s, target):
            _kind = State(initialValue: .effort); _sets = State(initialValue: s)
            _repsLow = State(initialValue: 8); _repsHigh = State(initialValue: 12)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: 40)
            _metres = State(initialValue: 100); _rpe = State(initialValue: target)
        case .unsupported:
            _kind = State(initialValue: .repsOnly); _sets = State(initialValue: 3)
            _repsLow = State(initialValue: 8); _repsHigh = State(initialValue: 12)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: 40)
            _metres = State(initialValue: 100); _rpe = State(initialValue: 8)
        }
        _rest = State(initialValue: exercise.restSeconds)
        _notes = State(initialValue: exercise.coachNotes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .accessibilityIdentifier("prescription_type_picker")
                    Stepper("Sets: \(sets)", value: $sets, in: 1...10)
                        .accessibilityIdentifier("prescription_sets_stepper")
                    switch kind {
                    case .repsAndLoad:
                        Stepper("Reps from: \(repsLow)", value: $repsLow, in: 1...30)
                        Stepper("Reps to: \(repsHigh)", value: $repsHigh, in: repsLow...40)
                        LabeledContent("Load (kg)") {
                            TextField("Load", value: $loadKg, format: .number)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("prescription_load_field")
                        }
                    case .repsOnly:
                        Stepper("Reps from: \(repsLow)", value: $repsLow, in: 1...30)
                        Stepper("Reps to: \(repsHigh)", value: $repsHigh, in: repsLow...40)
                    case .timed:
                        Stepper("Seconds: \(seconds)", value: $seconds, in: 5...600, step: 5)
                    case .distance:
                        Stepper("Metres: \(metres)", value: $metres, in: 10...5000, step: 10)
                    case .effort:
                        Stepper("Target RPE: \(PrescriptionFormat.trimmed(rpe))", value: $rpe, in: 5...10, step: 0.5)
                    }
                }
                Section("Rest & notes") {
                    Stepper("Rest: \(rest)s", value: $rest, in: 15...300, step: 15)
                    TextField("Coach notes (optional)", text: $notes, axis: .vertical)
                        .accessibilityIdentifier("prescription_notes_field")
                }
            }
            .navigationTitle(content.content(for: working.slug)?.displayName ?? working.slug.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        working.prescription = builtPrescription()
                        working.restSeconds = rest
                        working.coachNotes = notes.isEmpty ? nil : notes
                        onSave(working)
                        dismiss()
                    }
                    .accessibilityIdentifier("prescription_save")
                }
            }
        }
    }

    private func builtPrescription() -> SetPrescription {
        switch kind {
        case .repsAndLoad: return .repsAndLoad(sets: sets, reps: repsLow...max(repsLow, repsHigh), loadKg: loadKg > 0 ? loadKg : nil)
        case .repsOnly: return .repsOnly(sets: sets, reps: repsLow...max(repsLow, repsHigh))
        case .timed: return .timed(sets: sets, seconds: seconds)
        case .distance: return .distance(sets: sets, metres: metres)
        case .effort: return .effort(sets: sets, targetRPE: rpe)
        }
    }
}

// MARK: - Assign sheet

/// Assign a published version to a client (turn 6h). Client selection: dev fixture
/// identities in DEBUG; the production client list arrives with the backend relationship
/// model (R-01) and is stated honestly.
struct AssignWorkoutSheet: View {
    @Bindable var model: CoachProgrammingModel
    let version: WorkoutTemplateVersion
    @Environment(\.dismiss) private var dismiss

    private var clientRefs: [String] {
        #if DEBUG
        ["dev-client-001", "dev-client-002"]
        #else
        []
        #endif
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                Text("Assigning \"\(version.content.title)\" v\(version.versionNumber). The client keeps exactly this version, even if you edit the workout later.")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.textSecondary)

                if clientRefs.isEmpty {
                    MessageState(
                        systemImage: "person.2",
                        title: "No clients yet",
                        message: "Your client list arrives with the backend service."
                    )
                } else {
                    ForEach(clientRefs, id: \.self) { ref in
                        Button {
                            Task {
                                _ = await model.assign(version: version, toClientRef: ref)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(ref)
                                    .font(MazidiFont.bodyEmphasis)
                                    .foregroundStyle(MazidiColor.text)
                                Spacer()
                                Image(systemName: "paperplane")
                                    .foregroundStyle(MazidiColor.link)
                            }
                            .padding(MazidiMetric.cardPadding)
                            .frame(minHeight: MazidiMetric.minTarget)
                            .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("assign_client.\(ref)")
                    }
                    Text("Queued locally — delivery confirmation arrives with the backend.")
                        .font(MazidiFont.caption)
                        .foregroundStyle(MazidiColor.textTertiary)
                }
                Spacer()
            }
            .padding(MazidiMetric.screenPadding)
            .background(MazidiColor.background)
            .navigationTitle("Assign workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
