import Foundation

/// Stable accessibility identifiers for high-value UI tests. Identifiers are contract:
/// they never change with copy or layout, so UI tests stay resilient. Grouped by screen.
enum A11yID {
    // Today / home
    static let todayStartWorkout = "today_start_workout"
    static let todayResumeWorkout = "today_resume_workout"
    static let todayWorkoutCard = "today_workout_card"

    // Workout overview
    static let overviewBeginButton = "overview_begin_button"
    static let overviewExerciseRow = "overview_exercise_row" // + ".<slug>"

    // Active workout
    static let activeExerciseTitle = "active_exercise_title"
    static let activeNextExercise = "active_next_exercise"
    static let activePreviousExercise = "active_previous_exercise"
    static let activePauseButton = "active_pause_button"
    static let activeSwapButton = "active_swap_button"
    static let activeCompleteButton = "active_complete_button"
    static let activeInlineResume = "active_inline_resume"

    // Set entry
    static let setEntryField = "set_entry_field" // + ".reps" / ".load" / ".seconds" / ".metres" / ".rpe"
    static let setEntryLogButton = "set_entry_log_button"
    static let setEntryRow = "set_entry_row" // + ".<index>"

    // Rest timer
    static let restTimerValue = "rest_timer_value"
    static let restTimerAddButton = "rest_timer_add_button"
    static let restTimerSkipButton = "rest_timer_skip_button"
    static let restTimerPauseButton = "rest_timer_pause_button"

    // Swap sheet
    static let swapAlternativeRow = "swap_alternative_row" // + ".<slug>"
    static let swapConfirmButton = "swap_confirm_button"

    // Pause / exit sheet
    static let pauseResumeButton = "pause_resume_button"
    static let pauseExitKeepButton = "pause_exit_keep_button"
    static let pauseDiscardButton = "pause_discard_button"

    // Completion
    static let completeDoneButton = "complete_done_button"
    static let completeSummary = "complete_summary"

    // Health-data consent (ADR-0013)
    static let consentPurposeToggle = "consent_purpose_toggle"   // + ".<purpose>"
    static let consentSaveButton = "consent_save_button"
    static let consentNotNowButton = "consent_not_now_button"
    static let consentNoticeDisclosure = "consent_notice_disclosure"
    /// Shown on Today when a health-collection purpose has no consent record in force.
    static let consentTodayCard = "consent_today_card"
    static let consentOpenButton = "consent_open_button"
    /// Shown in place of the set-entry form when recording is not permitted.
    static let consentRequiredNotice = "consent_required_notice"
    /// The held (not-recorded) set entry notice — nothing is dropped silently.
    static let heldEntryNotice = "held_entry_notice"
    static let heldEntryDiscardButton = "held_entry_discard_button"
    static let heldEntryLogWithoutEffortButton = "held_entry_log_without_effort_button"

    // Privacy / withdrawal surface
    static let privacyOpenButton = "privacy_open_button"
    static let privacyPurposeRow = "privacy_purpose_row"         // + ".<purpose>"
    static let privacyWithdrawButton = "privacy_withdraw_button" // + ".<purpose>"
    static let privacyGrantButton = "privacy_grant_button"       // + ".<purpose>"
    static let privacyWithdrawConfirmButton = "privacy_withdraw_confirm_button"
    static let privacyHistoryDisclosure = "privacy_history_disclosure"

    // Sync status
    static let syncStatusBadge = "sync_status_badge"
    #if DEBUG
    /// Development-only connectivity toggle. Defined only in DEBUG so the identifier string
    /// is not compiled into Release builds.
    static let devConnectivityToggle = "dev_connectivity_toggle"
    #endif
}
