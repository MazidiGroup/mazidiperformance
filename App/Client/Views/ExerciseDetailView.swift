import SwiftUI
import MazidiDomain

/// Exercise detail (panel 7b): poster-first media, type-aware prescription, coach cue, and
/// client-layer copy (description, instructions, common mistakes, benefits). Draft copy is
/// always labelled "DRAFT COPY · PENDING REVIEW" (functional-rules.md) — never shown as
/// approved. Approved alternatives are listed in coach order (7e).
struct ExerciseDetailView: View {
    @Bindable var model: ClientWorkoutModel
    let exercise: AssignedExercise

    private var content: ExerciseContent? { model.content(for: exercise.slug) }
    private var name: String { content?.displayName ?? exercise.slug.rawValue }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
                ExerciseMediaView(
                    slug: model.performedSlug(for: exercise),
                    displayName: name,
                    media: model.media
                )

                if content?.contentStatus == .draftRequiresHumanReview {
                    DraftBadge()
                }

                Text(name)
                    .font(MazidiFont.screenTitle)
                    .foregroundStyle(MazidiColor.text)
                    .accessibilityAddTraits(.isHeader)

                prescriptionCard

                if let cue = exercise.coachCue {
                    calloutCard(icon: "quote.opening", title: "Coach cue", text: cue, kind: .info)
                }

                if let description = content?.clientDescription, !description.isEmpty {
                    Text(description)
                        .font(MazidiFont.body)
                        .foregroundStyle(MazidiColor.text)
                }

                bulletSection("How to do it", items: content?.clientInstructions ?? [], ordered: true, icon: "list.number")
                bulletSection("Common mistakes", items: content?.clientMistakes ?? [], ordered: false, icon: "exclamationmark.triangle")
                bulletSection("Why it's here", items: content?.clientBenefits ?? [], ordered: false, icon: "sparkles")

                if !exercise.approvedAlternatives.isEmpty {
                    approvedAlternatives
                }
            }
            .padding(MazidiMetric.screenPadding)
        }
        .background(MazidiColor.background)
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var prescriptionCard: some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prescription")
                    .font(MazidiFont.caption)
                    .foregroundStyle(MazidiColor.textSecondary)
                Text(PrescriptionFormat.summary(exercise.prescription))
                    .font(MazidiFont.metricValue)
                    .foregroundStyle(MazidiColor.text)
                Text("Rest \(exercise.restSeconds)s between sets")
                    .font(MazidiFont.callout)
                    .foregroundStyle(MazidiColor.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prescription")
        .accessibilityValue("\(PrescriptionFormat.accessibleSummary(exercise.prescription)). Rest \(exercise.restSeconds) seconds between sets.")
    }

    private func calloutCard(icon: String, title: String, text: String, kind: StatusBadge.Kind) -> some View {
        MazidiCard {
            VStack(alignment: .leading, spacing: 6) {
                StatusBadge(kind: kind, label: title, systemImage: icon)
                Text(text)
                    .font(MazidiFont.body)
                    .foregroundStyle(MazidiColor.text)
            }
        }
    }

    @ViewBuilder private func bulletSection(_ title: String, items: [String], ordered: Bool, icon: String) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
                SectionHeader(title: title)
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: MazidiMetric.tightSpacing) {
                        if ordered {
                            Text("\(index + 1)")
                                .font(MazidiFont.caption.weight(.bold))
                                .foregroundStyle(MazidiColor.link)
                                .frame(minWidth: 18, alignment: .trailing)
                        } else {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(MazidiColor.textSecondary)
                                .accessibilityHidden(true)
                        }
                        Text(item)
                            .font(MazidiFont.callout)
                            .foregroundStyle(MazidiColor.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var approvedAlternatives: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.tightSpacing) {
            SectionHeader(title: "Approved alternatives")
            Text("Your coach approved these as swaps during the workout.")
                .font(MazidiFont.caption)
                .foregroundStyle(MazidiColor.textSecondary)
            ForEach(exercise.approvedAlternatives, id: \.self) { slug in
                let altName = model.content(for: slug)?.displayName ?? slug.rawValue
                HStack(spacing: MazidiMetric.stackSpacing) {
                    ExercisePosterThumbnail(slug: slug, displayName: altName, media: model.media, side: 44)
                    Text(altName)
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.text)
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
