import Foundation
import MazidiDomain

/// The privacy-notice text presented with a health-data consent decision, and the copy for
/// each purpose.
///
/// **Status — DRAFT, pending legal review.** ADR-0013 records the owner's decision to treat
/// this data as UK GDPR Art. 9 special category data with explicit consent (Art. 9(2)(a)) as
/// the lawful basis, and makes solicitor confirmation Phase 0 gate 4. The wording below is
/// plain-language *product* copy written so the consent flow can exist and be tested; it is
/// **not** a lawyer-approved privacy notice. The app labels it as draft wherever it is shown
/// (the same honesty rule the draft exercise copy follows) and `version` changes when the
/// wording is replaced by the approved text.
///
/// Nothing here describes processing the app does not do: there is no backend yet
/// (R-01/R-02), no analytics pipeline for this data, and no model inference over it.
enum HealthPrivacyNotice {
    /// The version recorded with every consent decision. Consent is consent to a specific
    /// text, so this must change whenever the wording below changes.
    static let version = PrivacyNoticeVersion("draft-2026-07-30")

    /// False until the wording has been through legal review (ADR-0013 Phase 0 gate 4). Drives
    /// the draft label; it is not a feature flag and cannot hide the label.
    static let isLegallyApproved = false

    static let screenIntro = """
    Training information is sensitive. Before the app records any of it, choose what you're \
    happy for it to do. Each choice below is separate — agreeing to one does not agree to \
    the others, and you can change any of them later.
    """

    static let noticeSummary = """
    What the app records stays on this phone. There is no server yet, so nothing has been \
    sent anywhere. When sharing with your coach becomes possible, it happens only if you \
    have turned it on.

    Turning a choice off later stops the app recording or sending anything new for that \
    purpose. It does not delete what has already been recorded — your saved sessions stay \
    on this phone.
    """

    static func title(for purpose: HealthDataConsent.Purpose) -> String {
        switch purpose {
        case .performanceRecording: return "Record your training"
        case .perceivedExertionRecording: return "Record how hard it felt"
        case .coachSharing: return "Share with your coach"
        }
    }

    /// What is recorded, in the client's words — concrete, so the choice is informed.
    static func explanation(for purpose: HealthDataConsent.Purpose) -> String {
        switch purpose {
        case .performanceRecording:
            return "What you did in a session: sets, reps, weight, time and distance, and when you trained."
        case .perceivedExertionRecording:
            return "Your effort rating (RPE) for a set, on the sets where you choose to log one."
        case .coachSharing:
            return "Sending what you've recorded to your coach, so they can see how it went and adjust your programme."
        }
    }

    /// Honest description of what turning the choice off does — no implication of deletion.
    static func withdrawalEffect(for purpose: HealthDataConsent.Purpose) -> String {
        switch purpose {
        case .performanceRecording:
            return "New sessions and sets stop being recorded. Sessions you've already recorded stay saved on this phone."
        case .perceivedExertionRecording:
            return "Effort ratings stop being recorded. You can still log sets without one. Ratings already recorded stay saved."
        case .coachSharing:
            return "Nothing new is sent to your coach. Anything saved here and waiting stays saved on this phone and isn't sent. What your coach already has is not taken back."
        }
    }

    /// What the client loses by not agreeing — stated plainly, so declining is a real option
    /// rather than a dead end.
    static func consequenceOfDeclining(for purpose: HealthDataConsent.Purpose) -> String {
        switch purpose {
        case .performanceRecording:
            return "You can still view your programme and follow the workout; the app just won't keep a record of it."
        case .perceivedExertionRecording:
            return "You can still log every set, without an effort rating."
        case .coachSharing:
            return "You can still train and record; your coach won't see the results."
        }
    }
}
