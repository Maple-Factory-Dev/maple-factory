package dev.maplefactory

import android.content.Intent

/**
 * The iPhone app's launch flags, as intent extras (scripts/run-android.sh turns `-demo YES` into
 * `--es demo YES`): `demo`, `tab`, `goal`, `task`, `onboardingURL`, `onboardingContinue` and `devAs`.
 */
data class LaunchArgs(
    val demo: Boolean = false,
    val tab: String? = null,
    val goal: String? = null,
    val task: String? = null,
    val onboardingUrl: String? = null,
    val onboardingContinue: Boolean = false,
    val devAs: String? = null,
) {
    companion object {
        private fun yes(value: String?) = value != null && value.lowercase() in setOf("yes", "true", "1")

        fun from(intent: Intent?): LaunchArgs {
            val extras = intent?.extras ?: return LaunchArgs()
            fun text(key: String) = extras.getString(key)?.takeIf { it.isNotBlank() }
            return LaunchArgs(
                demo = yes(text("demo")),
                tab = text("tab"),
                goal = text("goal"),
                task = text("task"),
                onboardingUrl = text("onboardingURL"),
                onboardingContinue = yes(text("onboardingContinue")),
                devAs = text("devAs"),
            )
        }
    }
}
