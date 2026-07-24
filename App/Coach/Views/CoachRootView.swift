import SwiftUI
import MazidiDomain
import MazidiFoundations

/// Coach programming shell (ADR-0009, turn 6): workout list with draft/published status
/// and assignment states, editor navigation, and sign-out. Reached ONLY through a
/// validated coach role claim.
struct CoachRootView: View {
    let environment: CoachEnvironment
    @Environment(SessionModel.self) private var session
    @State private var model: CoachProgrammingModel?
    @State private var path: [Identifier<WorkoutTemplate>] = []
    @State private var showNewDraft = false
    @State private var newTitle = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let model {
                    workoutList(model)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Workouts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out") { Task { await session.signOut() } }
                        .accessibilityIdentifier("coach_sign_out")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newTitle = ""
                        showNewDraft = true
                    } label: {
                        Label("New workout", systemImage: "plus")
                    }
                    .accessibilityIdentifier("coach_create_workout")
                }
            }
            .navigationDestination(for: Identifier<WorkoutTemplate>.self) { templateID in
                if let model, let template = model.templates.first(where: { $0.id == templateID }) {
                    WorkoutEditorView(model: model, template: template)
                }
            }
        }
        .tint(MazidiColor.primary)
        .alert("New workout", isPresented: $showNewDraft) {
            TextField("Title", text: $newTitle)
                .accessibilityIdentifier("coach_new_workout_title")
            Button("Create") {
                Task {
                    if let model, let draft = await model.createDraft(title: newTitle) {
                        path.append(draft.id)
                    }
                }
            }
            .accessibilityIdentifier("coach_new_workout_create")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Drafts save on this phone; publish when it's ready to assign.")
        }
        .task {
            if model == nil { model = environment.makeModel() }
            await model?.load()
        }
    }

    @ViewBuilder private func workoutList(_ model: CoachProgrammingModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                if model.templates.isEmpty {
                    MessageState(
                        systemImage: "square.and.pencil",
                        title: "No workouts yet",
                        message: "Create a workout, publish it, then assign it to a client."
                    )
                } else {
                    ForEach(model.templates) { template in
                        templateRow(model, template: template)
                    }
                }
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .refreshable { await model.load() }
        .alert("Heads up", isPresented: Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.transientError = nil } }
        )) {
            Button("OK", role: .cancel) { model.transientError = nil }
        } message: {
            Text(model.transientError ?? "")
        }
    }

    private func templateRow(_ model: CoachProgrammingModel, template: WorkoutTemplate) -> some View {
        Button {
            path.append(template.id)
        } label: {
            MazidiCard {
                VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                    HStack {
                        Text(template.draft.title.isEmpty ? "Untitled" : template.draft.title)
                            .font(MazidiFont.sectionTitle)
                            .foregroundStyle(MazidiColor.text)
                        Spacer()
                        if template.publishedVersionCount == 0 {
                            StatusBadge(kind: .warning, label: "Draft", systemImage: "pencil")
                        } else {
                            StatusBadge(kind: .success, label: "v\(template.publishedVersionCount) published", systemImage: "checkmark.seal")
                        }
                    }
                    Text("\(template.draft.exercises.count) exercise\(template.draft.exercises.count == 1 ? "" : "s")")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                    assignmentStatuses(model, template: template)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("coach_workout_row.\(template.draft.title)")
    }

    /// Assignment states for this template — honest wording: queued means queued, and
    /// only real client-recorded facts (via the dev relay) advance it.
    @ViewBuilder private func assignmentStatuses(_ model: CoachProgrammingModel, template: WorkoutTemplate) -> some View {
        let assignments = model.assignments(for: template)
        if !assignments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(assignments) { assignment in
                    HStack(spacing: MazidiMetric.tightSpacing) {
                        Text(assignment.assigneeAccountRef)
                            .font(MazidiFont.caption)
                            .foregroundStyle(MazidiColor.textSecondary)
                        statusBadge(assignment.status)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("coach_assignment_status.\(assignment.assigneeAccountRef).\(assignment.status.rawValue)")
                }
            }
            .padding(.top, 2)
        }
    }

    private func statusBadge(_ status: WorkoutAssignment.Status) -> StatusBadge {
        switch status {
        case .queued:
            return StatusBadge(kind: .info, label: "Queued — delivery confirms with backend", systemImage: "tray.and.arrow.up")
        case .started:
            return StatusBadge(kind: .warning, label: "Started", systemImage: "figure.strengthtraining.traditional")
        case .completed:
            return StatusBadge(kind: .success, label: "Completed", systemImage: "checkmark.seal")
        case .cancelled:
            return StatusBadge(kind: .neutral, label: "Cancelled", systemImage: "xmark.circle")
        }
    }
}
