import SwiftUI
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
            ExercisePickerSheet(content: modelContent) { slug in
                Task {
                    await model.updateDraft(current) { draft in
                        draft.exercises.append(PrescribedExercise(
                            slug: slug,
                            order: draft.exercises.count,
                            prescription: .repsAndLoad(sets: 3, reps: 8...12, loadKg: nil)
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

    private var modelContent: any ExerciseContentProviding {
        FixtureExerciseContentProvider()
    }

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
        let name = modelContent.content(for: exercise.slug)?.displayName ?? exercise.slug.rawValue
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

// MARK: - Exercise picker (bundled fixture library)

private struct ExercisePickerSheet: View {
    let content: any ExerciseContentProviding
    let onPick: (ExerciseSlug) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The bundled representative slugs (full library arrives via the content pipeline).
    private let slugs: [ExerciseSlug] = [
        "barbell-squat", "barbell-bent-over-row", "barbell-high-incline-bench-press",
        "cable-seated-rope-face-pull", "band-wood-chopper", "dumbbell-row-bilateral",
        "kettlebell-sumo-deadlift", "barbell-rack-pull",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MazidiMetric.tightSpacing) {
                    ForEach(slugs, id: \.self) { slug in
                        let name = content.content(for: slug)?.displayName ?? slug.rawValue
                        Button {
                            onPick(slug)
                            dismiss()
                        } label: {
                            HStack {
                                Text(name)
                                    .font(MazidiFont.body)
                                    .foregroundStyle(MazidiColor.text)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(MazidiColor.link)
                            }
                            .padding(MazidiMetric.cardPadding)
                            .frame(minHeight: MazidiMetric.minTarget)
                            .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.chipRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("exercise_option.\(slug.rawValue)")
                    }
                }
                .padding(MazidiMetric.screenPadding)
            }
            .background(MazidiColor.background)
            .navigationTitle("Add exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
