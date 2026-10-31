package dev.maplefactory

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import dev.maplefactory.kit.SavedFactory
import dev.maplefactory.ui.MapleTheme
import dev.maplefactory.ui.RootScreen
import dev.maplefactory.ui.SignInScreen

/**
 * Maple Factory for Android. `-demo YES` opens the sample factories; otherwise the last factory
 * signed into, or the sign-in screen. Task links (maplefactory://task/<ID>, a factory's https …/t/<ID>)
 * open the task, in its own factory when it's a saved one.
 */
class MainActivity : ComponentActivity() {
    private val store: FactoryStore by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        val args = LaunchArgs.from(intent)
        if (savedInstanceState == null) {
            if (args.demo) store.startDemo() else if (!store.isSignedIn) store.restore()
            openLink(intent?.data)
        }
        setContent {
            MapleTheme {
                var adding by remember { mutableStateOf(false) }
                // Signing into another factory from Add a factory opens it.
                LaunchedEffect(store.opened) { adding = false }
                BackHandler(enabled = adding) { adding = false }
                when {
                    !store.isSignedIn -> SignInScreen(store, args)
                    adding -> SignInScreen(store, args.copy(onboardingUrl = null), onCancel = { adding = false })
                    else -> RootScreen(store, args, onAddFactory = { adding = true })
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        openLink(intent.data)
    }

    private fun openLink(uri: Uri?) {
        uri ?: return
        val segments = uri.pathSegments
        val id = when (uri.scheme) {
            // maplefactory://task/<ID> (the Mac app's), or maplefactory://t/<ID>.
            "maplefactory" -> if (uri.host == "task" || uri.host == "t") segments.firstOrNull() else null
            "https", "http" -> segments.takeIf { it.size >= 2 && it[it.size - 2] == "t" }?.last()
            else -> null
        } ?: return
        if (uri.scheme != "maplefactory" && uri.host != null) {
            val key = SavedFactory.key(uri.toString())
            store.saved.firstOrNull { it.id == key }?.let { store.switchTo(it) }
        }
        store.pendingTask = id
    }
}
