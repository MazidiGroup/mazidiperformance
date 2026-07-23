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

    // Sync status
    static let syncStatusBadge = "sync_status_badge"
    #if DEBUG
    /// Development-only connectivity toggle. Defined only in DEBUG so the identifier string
    /// is not compiled into Release builds.
    static let devConnectivityToggle = "dev_connectivity_toggle"
    #endif
}
