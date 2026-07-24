import SwiftUI
import MazidiDomain
import MazidiFoundations

/// Swap to a coach-approved alternative (panels 4b / 7e / 7h). Only the coach-ordered
/// approved alternatives are offered — the domain rejects anything else. Posters preview
/// each option; the currently-assigned/performed exercise can be restored.
struct SwapExerciseSheet: View {
    @Bindable var model: ClientWorkoutModel
    let exercise: AssignedExercise
    @Environment(\.dismiss) private var dismiss

    @State private var selected: ExerciseSlug?

    private var currentPerformed: ExerciseSlug { model.performedSlug(for: exercise) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                    Text("Your coach approved these alternatives. Swapping keeps the sets you've already logged.")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)

                    optionRow(slug: exercise.slug, tag: "Assigned")

                    ForEach(exercise.approvedAlternatives, id: \.self) { slug in
                        optionRow(slug: slug, tag: nil)
                    }
                }
                .padding(MazidiMetric.screenPadding)
            }
            .background(MazidiColor.background)
            .navigationTitle("Swap exercise")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button("Use this exercise") {
                    Task {
                        if let slug = selected, slug != currentPerformed {
                            await model.swap(exercise, to: slug)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.mazidiPrimary)
                .disabled(selected == nil || selected == currentPerformed)
                .padding(MazidiMetric.screenPadding)
                .background(.bar)
                .accessibilityIdentifier(A11yID.swapConfirmButton)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { selected = currentPerformed }
    }

    private func optionRow(slug: ExerciseSlug, tag: String?) -> some View {
        let name = model.content(for: slug)?.displayName ?? slug.rawValue
        let isSelected = selected == slug
        return Button {
            selected = slug
        } label: {
            HStack(spacing: MazidiMetric.stackSpacing) {
                ExercisePosterThumbnail(slug: slug, displayName: name, media: model.media)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(MazidiFont.bodyEmphasis)
                        .foregroundStyle(MazidiColor.text)
                    if let tag {
                        Text(tag).font(MazidiFont.caption).foregroundStyle(MazidiColor.textSecondary)
                    } else if slug == currentPerformed {
                        Text("Current").font(MazidiFont.caption).foregroundStyle(MazidiColor.successText)
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? MazidiColor.primary : MazidiColor.textTertiary)
                    .imageScale(.large)
            }
            .padding(MazidiMetric.cardPadding)
            .frame(minHeight: MazidiMetric.minTarget)
            .background(MazidiColor.surface, in: RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MazidiMetric.cardRadius, style: .continuous)
                    .strokeBorder(isSelected ? MazidiColor.primary : MazidiColor.hairline, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(A11yID.swapAlternativeRow).\(slug.rawValue)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(tag == "Assigned" ? "Originally assigned exercise" : "Coach-approved alternative")
        .accessibilityAddTraits(.isButton)
    }
}
