import SwiftUI
import MazidiDomain
import MazidiFoundations

// MARK: - Type-aware prescription presentation (7d / 7j)

enum PrescriptionFormat {
    /// Compact prescription summary, e.g. "3 × 5–8 · 80 kg", "2 × 40s", "3 sets · RPE 8".
    static func summary(_ p: Prescription) -> String {
        switch p {
        case let .repsAndLoad(sets, reps, loadKg):
            let load = loadKg.map { " · \(trimmed($0)) kg" } ?? ""
            return "\(sets) × \(range(reps))\(load)"
        case let .repsOnly(sets, reps):
            return "\(sets) × \(range(reps))"
        case let .timed(sets, seconds):
            return "\(sets) × \(seconds)s"
        case let .distance(sets, metres):
            return "\(sets) × \(metres) m"
        case let .effort(sets, rpe):
            return "\(sets) sets · RPE \(trimmed(rpe))"
        }
    }

    /// Spelled-out equivalent for VoiceOver, e.g. "3 sets of 5 to 8 reps at 80 kilograms".
    static func accessibleSummary(_ p: Prescription) -> String {
        switch p {
        case let .repsAndLoad(sets, reps, loadKg):
            let load = loadKg.map { " at \(trimmed($0)) kilograms" } ?? ""
            return "\(sets) sets of \(reps.lowerBound) to \(reps.upperBound) reps\(load)"
        case let .repsOnly(sets, reps):
            return "\(sets) sets of \(reps.lowerBound) to \(reps.upperBound) reps"
        case let .timed(sets, seconds):
            return "\(sets) sets of \(seconds) seconds"
        case let .distance(sets, metres):
            return "\(sets) sets of \(metres) metres"
        case let .effort(sets, rpe):
            return "\(sets) sets to R P E \(trimmed(rpe))"
        }
    }

    /// A recorded set, e.g. "6 reps · 80 kg", "40s", "RPE 8".
    static func summary(_ v: SetEntry.Value, rpe: Double?) -> String {
        let base: String
        switch v {
        case let .repsAndLoad(reps, loadKg): base = "\(reps) reps · \(trimmed(loadKg)) kg"
        case let .reps(reps): base = "\(reps) reps"
        case let .time(seconds): base = "\(seconds)s"
        case let .distance(metres): base = "\(metres) m"
        }
        if let rpe { return "\(base) · RPE \(trimmed(rpe))" }
        return base
    }

    private static func range(_ r: ClosedRange<Int>) -> String {
        r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)–\(r.upperBound)"
    }

    static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Set-entry form (type-aware fields)

/// Type-aware set entry (7d/7j). The visible fields follow the prescription type; the form
/// produces a `SetEntry.Value` for the domain to record. It holds only input state — the
/// recording, duplicate and ordering rules stay in the domain.
struct SetEntryForm: View {
    let exercise: AssignedExercise
    let setNumber: Int              // 1-based, for the label
    /// Effort (RPE) is a separately consented purpose (ADR-0013). When consent is not in
    /// force the control is absent and its state can never be sent — the alternative,
    /// showing it and dropping the value, would be silent data loss.
    var allowsEffortRating: Bool = true
    /// Route to the consent screen from the effort-rating explanation.
    var onRequestEffortRating: (() -> Void)?
    let onLog: (SetEntry.Value, Double?) -> Void

    @State private var reps: Int
    @State private var loadKg: Double
    @State private var seconds: Int
    @State private var metres: Int
    @State private var rpe: Double
    @State private var logRPE: Bool
    @FocusState private var focused: Bool

    init(
        exercise: AssignedExercise,
        setNumber: Int,
        allowsEffortRating: Bool = true,
        onRequestEffortRating: (() -> Void)? = nil,
        onLog: @escaping (SetEntry.Value, Double?) -> Void
    ) {
        self.exercise = exercise
        self.setNumber = setNumber
        self.allowsEffortRating = allowsEffortRating
        self.onRequestEffortRating = onRequestEffortRating
        self.onLog = onLog
        switch exercise.prescription {
        case let .repsAndLoad(_, reps, loadKg):
            _reps = State(initialValue: reps.lowerBound)
            _loadKg = State(initialValue: loadKg ?? 0)
            _seconds = State(initialValue: 0); _metres = State(initialValue: 0)
            _rpe = State(initialValue: 8); _logRPE = State(initialValue: false)
        case let .repsOnly(_, reps):
            _reps = State(initialValue: reps.lowerBound)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: 0); _metres = State(initialValue: 0)
            _rpe = State(initialValue: 8); _logRPE = State(initialValue: false)
        case let .timed(_, s):
            _seconds = State(initialValue: s)
            _reps = State(initialValue: 0); _loadKg = State(initialValue: 0); _metres = State(initialValue: 0)
            _rpe = State(initialValue: 8); _logRPE = State(initialValue: false)
        case let .distance(_, m):
            _metres = State(initialValue: m)
            _reps = State(initialValue: 0); _loadKg = State(initialValue: 0); _seconds = State(initialValue: 0)
            _rpe = State(initialValue: 8); _logRPE = State(initialValue: false)
        case let .effort(_, targetRPE):
            _reps = State(initialValue: 8)
            _loadKg = State(initialValue: 0); _seconds = State(initialValue: 0); _metres = State(initialValue: 0)
            _rpe = State(initialValue: targetRPE); _logRPE = State(initialValue: true)
        }
        // Consent gate: without it the form can never carry an effort value, not even the
        // default the `.effort` prescription would otherwise pre-set.
        if !allowsEffortRating { _logRPE = State(initialValue: false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MazidiMetric.stackSpacing) {
            Text("Log set \(setNumber)")
                .font(MazidiFont.bodyEmphasis)
                .foregroundStyle(MazidiColor.text)

            fields

            if allowsEffortRating {
                Toggle(isOn: $logRPE) {
                    Text("Record effort (RPE)")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                }
                .tint(MazidiColor.primary)
                .frame(minHeight: MazidiMetric.minTarget)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Effort ratings are off")
                        .font(MazidiFont.callout)
                        .foregroundStyle(MazidiColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let onRequestEffortRating {
                        Button("Turn on effort ratings", action: onRequestEffortRating)
                            .buttonStyle(.mazidiSecondary)
                            .accessibilityIdentifier(A11yID.consentOpenButton)
                    }
                }
            }

            if allowsEffortRating, logRPE {
                Stepper(value: $rpe, in: 5...10, step: 0.5) {
                    LabeledContent("RPE", value: PrescriptionFormat.trimmed(rpe))
                        .font(MazidiFont.body)
                }
                .accessibilityIdentifier("\(A11yID.setEntryField).rpe")
            }

            Button {
                onLog(value(), (allowsEffortRating && logRPE) ? rpe : nil)
            } label: {
                Text("Log set \(setNumber)")
            }
            .buttonStyle(.mazidiPrimary)
            .accessibilityIdentifier(A11yID.setEntryLogButton)
        }
    }

    @ViewBuilder private var fields: some View {
        switch exercise.prescription {
        case .repsAndLoad:
            HStack(spacing: MazidiMetric.stackSpacing) {
                numberField("Reps", value: $reps, id: "reps")
                decimalField("Load (kg)", value: $loadKg, id: "load")
            }
        case .repsOnly, .effort:
            numberField("Reps", value: $reps, id: "reps")
        case .timed:
            numberField("Seconds", value: $seconds, id: "seconds")
        case .distance:
            numberField("Metres", value: $metres, id: "metres")
        }
    }

    private func value() -> SetEntry.Value {
        switch exercise.prescription {
        case .repsAndLoad: return .repsAndLoad(reps: reps, loadKg: loadKg)
        case .repsOnly, .effort: return .reps(reps)
        case .timed: return .time(seconds: seconds)
        case .distance: return .distance(metres: metres)
        }
    }

    private func numberField(_ label: String, value: Binding<Int>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(MazidiFont.caption).foregroundStyle(MazidiColor.textSecondary)
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: MazidiMetric.minTarget)
                .accessibilityIdentifier("\(A11yID.setEntryField).\(id)")
                .accessibilityLabel(label)
        }
    }

    private func decimalField(_ label: String, value: Binding<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(MazidiFont.caption).foregroundStyle(MazidiColor.textSecondary)
            TextField(label, value: value, format: .number)
                .keyboardType(.decimalPad)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: MazidiMetric.minTarget)
                .accessibilityIdentifier("\(A11yID.setEntryField).\(id)")
                .accessibilityLabel(label)
        }
    }
}
