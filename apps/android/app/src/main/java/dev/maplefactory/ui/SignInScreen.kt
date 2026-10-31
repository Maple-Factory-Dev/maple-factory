package dev.maplefactory.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Construction
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.outlined.Business
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.maplefactory.FactoryStore
import dev.maplefactory.LaunchArgs
import dev.maplefactory.R
import dev.maplefactory.kit.FactoryApi
import dev.maplefactory.wire.PROTOCOL_VERSION
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private sealed class Step {
    data object Address : Step()
    data object Probing : Step()
    data class SignIn(val health: FactoryApi.Health) : Step()
    data class Waiting(val code: String, val uri: String) : Step()
    data object SigningIn : Step()
}

/** `-onboardingURL` connects once per launch, not every time the screen comes back. */
private var autoConnected = false

/**
 * Signing into a factory: type its address, probe /healthz, then GitHub's device flow (or a local
 * server's dev sign-in). Used on first launch and from Add a factory in the rail ([onCancel] set).
 * `-onboardingURL 10.0.2.2:8788` fills in an address and connects; `-onboardingContinue YES` signs in too.
 */
@Composable
fun SignInScreen(store: FactoryStore, args: LaunchArgs, onCancel: (() -> Unit)? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    var step by remember { mutableStateOf<Step>(Step.Address) }
    var server by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var flow by remember { mutableStateOf<Job?>(null) }

    fun reset() {
        flow?.cancel()
        flow = null
        server = null
        error = null
        step = Step.Address
    }

    fun signIn() {
        val url = server ?: return
        val health = (step as? Step.SignIn)?.health ?: return
        error = null
        flow = scope.launch {
            try {
                if (health.signIn == "dev") {
                    step = Step.SigningIn
                    store.signedIn(FactoryApi.devSignIn(url, args.devAs))
                    return@launch
                }
                val code = FactoryApi.startDeviceFlow(url)
                step = Step.Waiting(code.userCode, code.verificationUri)
                val deadline = System.currentTimeMillis() + code.expiresIn * 1000L
                while (System.currentTimeMillis() < deadline) {
                    delay(code.interval * 1000L)
                    FactoryApi.pollDeviceFlow(url, code.deviceCode, store.deviceLabel)?.let {
                        store.signedIn(it)
                        return@launch
                    }
                }
                error = "The code expired. Try again."
                step = Step.SignIn(health)
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: Exception) {
                error = FactoryApi.describe(failure)
                step = Step.SignIn(health)
            }
        }
    }

    fun connect() {
        val url = FactoryApi.serverUrl(address) ?: return
        error = null
        step = Step.Probing
        scope.launch {
            try {
                val health = FactoryApi.probe(url)
                if (health.protocolVersion > PROTOCOL_VERSION) {
                    error = FactoryApi.TOO_NEW
                    step = Step.Address
                    return@launch
                }
                server = url
                step = Step.SignIn(health)
                if (args.onboardingContinue) {
                    delay(1000)
                    signIn()
                }
            } catch (cancel: CancellationException) {
                throw cancel
            } catch (failure: Exception) {
                error = FactoryApi.describe(failure)
                step = Step.Address
            }
        }
    }

    LaunchedEffect(Unit) {
        val typed = args.onboardingUrl
        if (typed != null && !autoConnected) {
            autoConnected = true
            address = typed
            connect()
        }
    }

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Column(
            Modifier.systemBarsPadding().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            if (onCancel != null) {
                IconButton(onClick = { flow?.cancel(); onCancel() }, modifier = Modifier.padding(start = 0.dp)) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                }
            }
            Column(Modifier.padding(top = if (onCancel == null) 24.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Image(painterResource(R.drawable.mark), null, Modifier.size(64.dp).clip(RoundedCornerShape(14.dp)))
                Text(if (onCancel == null) "Connect to a factory" else "Add a factory", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                Text("Enter the address your team runs Maple at. You'll sign in with GitHub next.", color = secondaryText)
            }

            when (val current = step) {
                Step.Address, Step.Probing -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = address,
                        onValueChange = { address = it },
                        placeholder = { Text("maple.yourteam.dev") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                        keyboardActions = KeyboardActions(onGo = { connect() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(
                        onClick = { connect() },
                        enabled = FactoryApi.serverUrl(address) != null && current != Step.Probing,
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                    ) {
                        if (current == Step.Probing) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                            Spacer(Modifier.size(8.dp))
                        }
                        Text(if (current == Step.Probing) "Connecting…" else "Continue")
                    }
                }
                is Step.SignIn -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val health = current.health
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Verified, null, tint = Maple.approve.color, modifier = Modifier.size(18.dp))
                        Text(server?.substringAfter("://") ?: "", color = Maple.approve.color)
                    }
                    health.org?.let { Text("The $it factory", style = MaterialTheme.typography.titleMedium) }
                    val dev = health.signIn == "dev"
                    Button(onClick = { signIn() }, enabled = health.signIn != "unconfigured", modifier = Modifier.fillMaxWidth().height(48.dp)) {
                        Icon(if (dev) Icons.Filled.Construction else Icons.Filled.Person, null, Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(if (dev) "Sign in as ${args.devAs ?: health.devLogin ?: "dev"}" else "Sign in with GitHub")
                    }
                    if (health.signIn == "unconfigured") {
                        Text("This factory hasn't set up GitHub sign-in yet.", style = MaterialTheme.typography.bodySmall, color = secondaryText)
                    }
                    TextButton(onClick = { reset() }) { Text("Use another factory") }
                }
                is Step.Waiting -> Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Text("Enter this code on GitHub", style = MaterialTheme.typography.titleMedium)
                    SelectionContainer {
                        Text(
                            current.code,
                            fontSize = 34.sp,
                            fontWeight = FontWeight.SemiBold,
                            fontFamily = FontFamily.Monospace,
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                .background(MaterialTheme.colorScheme.surfaceContainerHigh).padding(vertical = 14.dp),
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        )
                    }
                    Button(
                        onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            clipboard.setPrimaryClip(ClipData.newPlainText("GitHub code", current.code))
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(current.uri)))
                        },
                        modifier = Modifier.fillMaxWidth().height(48.dp),
                    ) {
                        Icon(Icons.Filled.OpenInBrowser, null, Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text("Copy code and open GitHub")
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Text("Waiting for GitHub…", color = secondaryText)
                    }
                    TextButton(onClick = { reset() }) { Text("Cancel") }
                }
                Step.SigningIn -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.size(10.dp))
                    Text("Signing in…")
                }
            }

            error?.let {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Error, null, tint = Maple.danger.color, modifier = Modifier.size(18.dp))
                    Text(it, color = Maple.danger.color, style = MaterialTheme.typography.bodyMedium)
                }
            }

            // Factories signed into before; adding one from the rail lists them there already.
            if (onCancel == null && store.saved.isNotEmpty() && step == Step.Address) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Signed in before", style = MaterialTheme.typography.titleMedium)
                    for (factory in store.saved) {
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh)
                                .clickable { store.switchTo(factory) }.padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Icon(Icons.Outlined.Business, null)
                            Column(Modifier.weight(1f)) {
                                Text(factory.name)
                                Text(factory.host, style = MaterialTheme.typography.bodySmall, color = secondaryText)
                            }
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = tertiaryText)
                        }
                    }
                }
            }

            if (onCancel == null) {
                OutlinedButton(onClick = { store.startDemo() }, modifier = Modifier.fillMaxWidth().height(48.dp)) {
                    Icon(Icons.Filled.PlayCircle, null, Modifier.size(18.dp))
                    Spacer(Modifier.size(8.dp))
                    Text("Try the demo")
                }
            }
        }
    }
}
