package app.lumina.ui

import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.lumina.core.AppSettings
import app.lumina.core.LuminaException
import app.lumina.core.Source
import app.lumina.core.SourceKind
import app.lumina.core.XtreamClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val bottomInset = 168.dp

@Composable
private fun Section(title: String, footer: String? = null, content: @Composable () -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.55f), modifier = Modifier.padding(start = 6.dp, bottom = 6.dp))
        Column(Modifier.fillMaxWidth().rowCard(20.dp)) { content() }
        if (footer != null) Text(footer, fontSize = 12.sp, color = Color.White.copy(alpha = 0.45f), modifier = Modifier.padding(6.dp, 6.dp, 6.dp, 0.dp))
    }
}

@Composable
private fun ToggleRow(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp)
        Switch(checked, onChange)
    }
}

@Composable
private fun StepperRow(title: String, value: String, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), fontSize = 16.sp)
        Text(value, color = Color.White.copy(alpha = 0.6f))
        Spacer(Modifier.width(8.dp))
        GlassIconButton(Icons.Filled.Remove, "Less", 34.dp) { onMinus() }
        Spacer(Modifier.width(6.dp))
        GlassIconButton(Icons.Filled.Add, "More", 34.dp) { onPlus() }
    }
}

@Composable
private fun ActionRow(title: String, destructive: Boolean = false, onClick: () -> Unit) {
    Text(title, Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp), fontSize = 16.sp, color = if (destructive) Color(0xFFFF6B6B) else Pal.accent)
}

@Composable
fun SettingsScreen() {
    val model = appModel
    val sources by model.sources.collectAsStateWithLifecycle()
    val accounts by model.accounts.collectAsStateWithLifecycle()
    val user by model.user.collectAsStateWithLifecycle()
    val s = user.settings
    val scan by model.scanProgress.collectAsStateWithLifecycle()
    val dead by model.deadChannels.collectAsStateWithLifecycle()
    val guideAt by model.guideUpdatedAt.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val ctx = LocalContext.current
    var message by remember { mutableStateOf<String?>(null) }
    var pinDialog by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<Source?>(null) }
    var addMenu by remember { mutableStateOf(false) }
    fun set(f: (AppSettings) -> AppSettings) = model.updateUser { it.copy(settings = f(it.settings)) }

    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri ->
        if (uri != null) scope.launch(Dispatchers.IO) {
            runCatching { val f = model.exportBackup(); ctx.contentResolver.openOutputStream(uri)?.use { o -> f.inputStream().use { it.copyTo(o) } } }
                .onSuccess { message = "Backup saved." }.onFailure { message = "Couldn't save the backup." }
        }
    }
    val restore = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch { runCatching { model.importBackup(uri) }.onSuccess { message = "Backup restored." }.onFailure { message = "That file isn't a Lumina backup." } }
    }

    Column(Modifier.fillMaxSize()) {
        LargeTitle("Settings")
        Column(Modifier.verticalScroll(rememberScrollState()).padding(bottom = bottomInset)) {
            Section("Sources") {
                sources.forEach { src ->
                    Row(Modifier.fillMaxWidth().clickable { UiState.push(Page.SourceEdit(src)) }.padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Icon(sourceIcon(src), null, tint = Pal.accent)
                        Column(Modifier.weight(1f)) {
                            Text(src.name, fontSize = 16.sp)
                            val bits = buildList {
                                accounts[src.id]?.daysRemaining()?.let { add(if (it >= 0) "$it days left" else "expired") }
                                src.lastRefreshed?.let { add("updated " + android.text.format.DateUtils.getRelativeTimeSpanString(it).toString().lowercase()) }
                            }
                            Text(if (bits.isEmpty()) "Not loaded yet" else bits.joinToString(" · "), fontSize = 12.sp, color = Color.White.copy(alpha = 0.55f))
                        }
                        TextButton({ removing = src }) { Text("Remove", color = Color(0xFFFF6B6B)) }
                    }
                }
                Column {
                    ActionRow("+ Add source") { addMenu = true }
                    androidx.compose.material3.DropdownMenu(addMenu, { addMenu = false }) {
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Xtream login") }, leadingIcon = { Icon(Icons.Filled.Key, null) }, onClick = { addMenu = false; UiState.push(Page.AddSource(AddMode.XTREAM)) })
                        androidx.compose.material3.DropdownMenuItem(text = { Text("M3U link") }, leadingIcon = { Icon(Icons.Filled.Link, null) }, onClick = { addMenu = false; UiState.push(Page.AddSource(AddMode.M3U)) })
                        androidx.compose.material3.DropdownMenuItem(text = { Text("Playlist file") }, leadingIcon = { Icon(Icons.Filled.Description, null) }, onClick = { addMenu = false; UiState.push(Page.AddSource(AddMode.FILE)) })
                    }
                }
            }
            Section("Playback", "Merging combines 'ESPN', 'ESPN HD' and 'ESPN FHD' into one channel with fallbacks. Raw .ts streams play too (ExoPlayer), but HLS starts faster.") {
                ToggleRow("Auto-switch to backup stream", s.autoFailover) { v -> set { it.copy(autoFailover = v) } }
                ToggleRow("Merge duplicate channels", s.mergeDuplicates) { v -> set { it.copy(mergeDuplicates = v) } }
                ToggleRow("Prefer HLS for .ts links", s.rewriteTsToHls) { v -> set { it.copy(rewriteTsToHls = v) } }
                ToggleRow("Resume last channel shortcut", s.resumeLastChannel) { v -> set { it.copy(resumeLastChannel = v) } }
            }
            Section("TV guide") {
                StepperRow("Refresh every", "${s.guideRefreshHours} h", { set { it.copy(guideRefreshHours = (it.guideRefreshHours - 1).coerceAtLeast(1)) } }, { set { it.copy(guideRefreshHours = (it.guideRefreshHours + 1).coerceAtMost(48)) } })
                ActionRow("Refresh guide now") { scope.launch { model.refreshGuide(true) } }
                guideAt?.let { Text("Last updated " + android.text.format.DateUtils.getRelativeTimeSpanString(it).toString().lowercase(), Modifier.padding(16.dp, 0.dp, 16.dp, 12.dp), fontSize = 12.sp, color = Color.White.copy(alpha = 0.5f)) }
            }
            Section("Android Auto", "Audio only keeps playback smooth in the car and uses far less data. Shorter lists load faster on the car display.") {
                ToggleRow("Audio only in the car", s.autoAudioOnly) { v -> set { it.copy(autoAudioOnly = v) } }
                StepperRow("List length", "${s.autoMaxItems}", { set { it.copy(autoMaxItems = (it.autoMaxItems - 20).coerceAtLeast(20)) } }, { set { it.copy(autoMaxItems = (it.autoMaxItems + 20).coerceAtMost(200)) } })
            }
            Section("Parental control", "Locked groups ask for the PIN before they open or play, including in the car.") {
                ToggleRow("Hide adult-looking groups", s.hideAdultByDefault) { v -> set { it.copy(hideAdultByDefault = v) } }
                ActionRow(if (user.hasPin) "Change or remove PIN" else "Set a PIN") { pinDialog = true }
                if (user.hasPin) {
                    ActionRow("Choose locked groups (${user.lockedGroups.size})") { UiState.push(Page.LockedGroups) }
                    ActionRow("Lock everything again") { model.lockAll() }
                }
            }
            Section("Library tools") {
                val sc = scan
                if (sc != null) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        LinearProgressIndicator(progress = { sc.first.toFloat() / maxOf(sc.second, 1) }, Modifier.fillMaxWidth(), color = Pal.accent)
                        Text("Checking channels… ${sc.first} of ${sc.second}", fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f))
                        TextButton({ model.cancelScan() }) { Text("Stop", color = Color(0xFFFF6B6B)) }
                    }
                } else {
                    ActionRow("Find dead channels") { model.scanForDeadChannels() }
                    if (dead.isNotEmpty()) {
                        Text("${dead.size} channels didn't respond.", Modifier.padding(horizontal = 16.dp), fontSize = 13.sp, color = Color.White.copy(alpha = 0.6f))
                        ActionRow("Hide dead channels") { model.applyDeadChannelHiding() }
                    }
                }
                if (user.hiddenChannels.isNotEmpty() || user.hiddenGroups.isNotEmpty()) ActionRow("Show ${user.hiddenChannels.size} hidden channels again") { model.unhideAll() }
            }
            Section("Backup", "Includes sources (with logins), favorites and settings. Keep the file private.") {
                ActionRow("Export backup") { export.launch("Lumina-Backup.json") }
                ActionRow("Restore from backup") { restore.launch(arrayOf("application/json", "text/plain", "*/*")) }
            }
            Section("About") {
                Text("Version 1.0", Modifier.padding(16.dp, 16.dp, 16.dp, 4.dp))
                Text("Lumina is a player. It does not provide or endorse any content.", Modifier.padding(16.dp, 0.dp, 16.dp, 16.dp), fontSize = 12.sp, color = Color.White.copy(alpha = 0.55f))
            }
        }
    }

    removing?.let { src ->
        AlertDialog(
            onDismissRequest = { removing = null }, title = { Text("Remove ${src.name}?") }, text = { Text("Your favorites stay saved if you add it back.") },
            confirmButton = { TextButton({ model.removeSource(src.id); removing = null }) { Text("Remove", color = Color(0xFFFF6B6B)) } },
            dismissButton = { TextButton({ removing = null }) { Text("Cancel") } },
        )
    }
    message?.let { m -> AlertDialog(onDismissRequest = { message = null }, text = { Text(m) }, confirmButton = { TextButton({ message = null }) { Text("OK") } }) }
    if (pinDialog) PinSetupDialog { pinDialog = false }
}

private fun sourceIcon(s: Source): ImageVector = when (s.kind) {
    SourceKind.Demo -> Icons.Filled.AutoAwesome
    is SourceKind.M3u -> if ((s.kind as SourceKind.M3u).url.startsWith("/")) Icons.Filled.Description else Icons.Filled.Link
    is SourceKind.Xtream -> Icons.Filled.Key
}

// MARK: Source edit

@Composable
fun SourceEditScreen(source: Source) {
    val model = appModel
    var name by remember { mutableStateOf(source.name) }
    var ua by remember { mutableStateOf(source.userAgent ?: "") }
    var offset by remember { mutableStateOf(source.epgOffsetMinutes) }
    var extra by remember { mutableStateOf("") }
    var enabled by remember { mutableStateOf(source.enabled) }
    var extras by remember { mutableStateOf(source.extraEpg) }
    val account = model.accounts.collectAsStateWithLifecycle().value[source.id]
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        PageHeader(source.name)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name") }, singleLine = true)
            account?.let { a ->
                Column(Modifier.fillMaxWidth().rowCard().padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Account", fontWeight = FontWeight.SemiBold)
                    Text("Status: ${a.status}")
                    a.expiry?.let { Text("Expires: " + java.text.DateFormat.getDateInstance().format(java.util.Date(it))) }
                    a.maxConnections?.let { Text("Connections: ${a.activeConnections ?: 0} of $it") }
                    if (a.isTrial) Text("Trial account", color = Color.White.copy(alpha = 0.6f))
                }
            }
            OutlinedTextField(ua, { ua = it }, Modifier.fillMaxWidth(), label = { Text("Custom User-Agent (optional)") }, singleLine = true)
            Row(Modifier.fillMaxWidth().rowCard().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                StepperRow("Guide time shift", "$offset min", { offset = (offset - 15).coerceAtLeast(-720) }, { offset = (offset + 15).coerceAtMost(720) })
            }
            Text("Shift the guide if programmes show up an hour early or late.", fontSize = 12.sp, color = Color.White.copy(alpha = 0.5f))
            OutlinedTextField(extra, { extra = it }, Modifier.fillMaxWidth(), label = { Text("Extra guide URL (XMLTV)") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
            extras.forEach { u -> Row(verticalAlignment = Alignment.CenterVertically) { Text(u, Modifier.weight(1f), fontSize = 12.sp, maxLines = 1); TextButton({ extras = extras - u }) { Text("Remove") } } }
            ToggleRow("Enabled", enabled) { enabled = it }
            Button({
                val newExtras = if (extra.startsWith("http") && extra !in extras) extras + extra.trim() else extras
                model.updateSource(source.copy(name = name.ifBlank { source.name }, userAgent = ua.ifBlank { null }, epgOffsetMinutes = offset, enabled = enabled, extraEpg = newExtras))
                UiState.pop()
            }, Modifier.fillMaxWidth()) { Text("Save changes") }
            OutlinedButton({ scope.launch { model.refresh(source.id) } }, Modifier.fillMaxWidth()) { Text("Refresh now") }
        }
    }
}

// MARK: Add source

@Composable
fun AddSourceScreen(initial: AddMode) {
    val model = appModel
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var mode by remember { mutableStateOf(initial) }
    var name by remember { mutableStateOf("") }
    var url by remember { mutableStateOf("") }
    var server by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var note by remember { mutableStateOf<String?>(null) }

    fun fail(e: Throwable) { error = (e as? LuminaException)?.message ?: e.message ?: "Something went wrong." }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            busy = true; error = null
            try {
                val display = withContext(Dispatchers.IO) { ctx.contentResolver.query(uri, null, null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(c.getColumnIndexOrThrow(OpenableColumns.DISPLAY_NAME)) else null } }
                var src = model.importPlaylist(uri, display)
                if (name.isNotBlank()) src = src.copy(name = name)
                model.addSource(src)
                UiState.pop()
            } catch (e: Exception) { fail(e) } finally { busy = false }
        }
    }

    fun submit() {
        scope.launch {
            busy = true; error = null; note = null
            try {
                when (mode) {
                    AddMode.XTREAM -> {
                        val s = XtreamClient.normalizeServer(server) ?: throw LuminaException(LuminaException.Kind.INVALID_URL)
                        model.addSource(Source(name = name.ifBlank { java.net.URI(s).host ?: "Xtream" }, kind = SourceKind.Xtream(s, user.trim(), pass)))
                    }
                    AddMode.M3U -> {
                        var t = url.trim()
                        if (!t.startsWith("http", true)) t = "http://$t"
                        val c = XtreamClient.credentials(t)
                        if (c != null) {
                            note = "Detected an Xtream login — using it for movies, series and guide too."
                            model.addSource(Source(name = name.ifBlank { runCatching { java.net.URI(c.first).host }.getOrNull() ?: "Xtream" }, kind = SourceKind.Xtream(c.first, c.second, c.third)))
                        } else {
                            model.addSource(Source(name = name.ifBlank { runCatching { java.net.URI(t).host }.getOrNull() ?: "Playlist" }, kind = SourceKind.M3u(t)))
                        }
                    }
                    AddMode.FILE -> return@launch
                }
                UiState.pop()
            } catch (e: Exception) { fail(e) } finally { busy = false }
        }
    }

    val canSubmit = when (mode) {
        AddMode.XTREAM -> server.isNotBlank() && user.isNotBlank() && pass.isNotBlank()
        AddMode.M3U -> url.isNotBlank()
        AddMode.FILE -> false
    }

    Column(Modifier.fillMaxSize()) {
        PageHeader("Add source")
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { AddMode.entries.forEach { m -> Chip(m.label, mode == m) { mode = m; error = null } } }
            OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth(), label = { Text("Name (optional)") }, singleLine = true)
            when (mode) {
                AddMode.XTREAM -> {
                    OutlinedTextField(server, { server = it }, Modifier.fillMaxWidth(), label = { Text("Server, e.g. http://host:8080") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                    OutlinedTextField(user, { user = it }, Modifier.fillMaxWidth(), label = { Text("Username") }, singleLine = true)
                    OutlinedTextField(pass, { pass = it }, Modifier.fillMaxWidth(), label = { Text("Password") }, singleLine = true, visualTransformation = PasswordVisualTransformation())
                }
                AddMode.M3U -> {
                    OutlinedTextField(url, { url = it }, Modifier.fillMaxWidth(), label = { Text("https://…/playlist.m3u") }, singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                    val clip = androidx.compose.ui.platform.LocalClipboardManager.current
                    TextButton({ clip.getText()?.text?.let { url = it } }) { Text("Paste from clipboard") }
                }
                AddMode.FILE -> OutlinedButton({ picker.launch(arrayOf("*/*")) }, Modifier.fillMaxWidth(), enabled = !busy) { Text("Choose a .m3u or .m3u8 file") }
            }
            note?.let { Text(it, color = Pal.accent, fontSize = 13.sp) }
            error?.let { Text("⚠ $it", color = Color(0xFFFFD166), fontSize = 14.sp) }
            if (mode != AddMode.FILE) Button({ submit() }, Modifier.fillMaxWidth(), enabled = !busy && canSubmit) {
                if (busy) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.Black); Spacer(Modifier.width(8.dp)) }
                Text(if (busy) "Connecting…" else "Connect")
            } else if (busy) CircularProgressIndicator()
        }
    }
}

// MARK: Parental control

@Composable
private fun PinSetupDialog(dismiss: () -> Unit) {
    val model = appModel
    val has = model.user.value.hasPin
    var current by remember { mutableStateOf("") }
    var pin by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val num = KeyboardOptions(keyboardType = KeyboardType.NumberPassword)
    AlertDialog(
        onDismissRequest = dismiss, title = { Text("PIN") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (has) OutlinedTextField(current, { current = it.filter(Char::isDigit) }, label = { Text("Current PIN") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = num)
                OutlinedTextField(pin, { pin = it.filter(Char::isDigit).take(8) }, label = { Text("New PIN (4–8 digits)") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = num)
                OutlinedTextField(confirm, { confirm = it.filter(Char::isDigit).take(8) }, label = { Text("Repeat PIN") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), keyboardOptions = num)
                error?.let { Text(it, color = Color(0xFFFFD166), fontSize = 13.sp) }
            }
        },
        confirmButton = {
            TextButton({
                when {
                    has && !model.user.value.verifyPin(current) -> error = "Current PIN is wrong."
                    pin != confirm -> error = "PINs don't match."
                    pin.length !in 4..8 -> error = "Use 4 to 8 digits."
                    else -> { model.updateUser { it.withPin(pin) }; dismiss() }
                }
            }) { Text("Save") }
        },
        dismissButton = {
            Row {
                if (has) TextButton({
                    if (model.user.value.verifyPin(current)) { model.updateUser { it.withPin(null).copy(lockedGroups = emptySet()) }; dismiss() } else error = "Enter the current PIN first."
                }) { Text("Remove PIN", color = Color(0xFFFF6B6B)) }
                TextButton(dismiss) { Text("Cancel") }
            }
        },
    )
}

@Composable
fun LockedGroupsScreen() {
    val model = appModel
    val lib by model.library.collectAsStateWithLifecycle()
    val user by model.user.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        PageHeader("Locked groups")
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true, placeholder = { Text("Search groups") })
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            items(lib.allGroups.filter { query.isEmpty() || it.id.contains(query, true) }, key = { it.id }) { g ->
                ToggleRow("${g.label.title}  ·  ${g.count}", g.id in user.lockedGroups) { on ->
                    model.updateUser { it.copy(lockedGroups = if (on) it.lockedGroups + g.id else it.lockedGroups - g.id) }
                }
            }
        }
    }
}
