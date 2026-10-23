package app.lumina.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items as gridItems
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.lumina.core.Episode
import app.lumina.core.GroupLabel
import app.lumina.core.Series
import app.lumina.core.StreamEndpoint
import app.lumina.core.VodItem
import app.lumina.core.SearchResults
import app.lumina.core.XtreamClient
import app.lumina.core.Programme
import app.lumina.core.Channel
import app.lumina.playback.VodRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private val bottomInset = 168.dp

@Composable
fun LibraryScreen() {
    val model = appModel
    val lib by model.library.collectAsStateWithLifecycle()
    val user by model.user.collectAsStateWithLifecycle()
    var movies by remember { mutableStateOf(true) }
    var category by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }

    val categories = remember(lib, movies) { (if (movies) lib.movies.map { it.category } else lib.series.map { it.category }).distinct() }
    val shownMovies by produceState(emptyList<VodItem>(), lib, movies, category, query) {
        value = if (!movies) emptyList() else { if (query.isNotEmpty()) delay(180); withContext(Dispatchers.Default) { lib.movies.filter { (category == null || it.category == category) && (query.isEmpty() || it.title.contains(query, true)) }.take(600) } }
    }
    val shownSeries by produceState(emptyList<Series>(), lib, movies, category, query) {
        value = if (movies) emptyList() else { if (query.isNotEmpty()) delay(180); withContext(Dispatchers.Default) { lib.series.filter { (category == null || it.category == category) && (query.isEmpty() || it.title.contains(query, true)) }.take(600) } }
    }
    val cont = remember(user.progress) { model.continueWatching() }

    Column(Modifier.fillMaxSize()) {
        LargeTitle("Library")
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true, placeholder = { Text("Search ${if (movies) "movies" else "series"}") })
        Row(Modifier.padding(16.dp, 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("Movies", movies) { movies = true; category = null }
            Chip("Series", !movies) { movies = false; category = null }
        }
        val empty = if (movies) lib.movies.isEmpty() else lib.series.isEmpty()
        if (empty) {
            Column(Modifier.fillMaxWidth().padding(top = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("No ${if (movies) "movies" else "series"} yet", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Text("They appear here when your provider includes them (Xtream logins do).", color = Color.White.copy(alpha = 0.55f), modifier = Modifier.padding(24.dp))
            }
        } else {
            LazyVerticalGrid(
                GridCells.Adaptive(104.dp), contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, bottomInset),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                if (query.isEmpty() && category == null && cont.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text("Continue watching", fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(cont, key = { it.id }) { c ->
                                Column(Modifier.width(110.dp).clickable {
                                    c.progress.streamUrl?.let { u ->
                                        UiState.play(VodRequest(c.id, c.progress.title, StreamEndpoint(u), c.progress.poster), resumeMs = maxOf(0, c.progress.positionMs - 3000))
                                    }
                                }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    PosterImage(c.progress.poster, Modifier.fillMaxWidth())
                                    LinearProgressIndicator(progress = { c.progress.fraction.toFloat() }, Modifier.fillMaxWidth().height(3.dp), color = Pal.accent, trackColor = Color.White.copy(alpha = 0.15f))
                                    Text(c.progress.title, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                            }
                        }
                    }
                }
                if (categories.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip("All", category == null) { category = null }
                        categories.forEach { c -> Chip(GroupLabel.parse(c).title, category == c) { category = c } }
                    }
                }
                if (movies) gridItems(shownMovies, key = { it.id }) { m -> PosterCell(m.poster, m.title) { UiState.push(Page.Movie(m)) } }
                else gridItems(shownSeries, key = { it.id }) { s -> PosterCell(s.poster, s.title) { UiState.push(Page.SeriesPage(s)) } }
            }
        }
    }
}

@Composable
private fun PosterCell(poster: String?, title: String, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        PosterImage(poster, Modifier.fillMaxWidth())
        Text(title, fontSize = 12.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

// MARK: Movie

@Composable
fun MovieDetailScreen(movie: VodItem) {
    val model = appModel
    val user by model.user.collectAsStateWithLifecycle()
    var detail by remember { mutableStateOf<XtreamClient.VodDetail?>(null) }
    LaunchedEffect(movie.id) { detail = model.detail(movie) }
    val progress = user.progress[movie.id]
    val canResume = progress != null && !progress.isFinished && progress.positionMs > 20_000

    fun play(fromStart: Boolean) {
        var ep = movie.stream
        detail?.containerExtension?.let { ext -> if (!ep.url.endsWith(".$ext")) ep = ep.copy(url = ep.url.substringBeforeLast('.') + "." + ext) }
        val at = if (fromStart || progress == null || progress.isFinished) 0L else maxOf(0L, progress.positionMs - 3000)
        UiState.play(VodRequest(movie.id, movie.title, ep, movie.poster), resumeMs = at)
    }

    Column(Modifier.fillMaxSize()) {
        PageHeader("")
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Bottom) {
                PosterImage(detail?.poster ?: movie.poster, Modifier.width(130.dp))
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(movie.title, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        (detail?.year ?: movie.year)?.let { QualityBadge(it) }
                        (detail?.rating ?: movie.rating)?.takeIf { it > 0 }?.let { QualityBadge("★ %.1f".format(it)) }
                        detail?.duration?.let { QualityBadge(it) }
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button({ play(false) }, Modifier.weight(1f)) {
                    Icon(Icons.Filled.PlayArrow, null); Spacer(Modifier.width(6.dp))
                    Text(if (canResume) "Resume ${Fmt.duration(progress!!.positionMs)}" else "Play")
                }
                if (canResume) OutlinedButton({ play(true) }) { Icon(Icons.Filled.Replay, null); Spacer(Modifier.width(6.dp)); Text("Start over") }
            }
            (detail?.plot ?: movie.plot)?.let { Text(it, color = Color.White.copy(alpha = 0.75f)) }
            detail?.genre?.let { Info("Genre", it) }
            detail?.cast?.let { Info("Cast", it) }
            detail?.director?.let { Info("Director", it) }
        }
    }
}

@Composable
private fun Info(k: String, v: String) {
    Column { Text(k, fontSize = 12.sp, color = Color.White.copy(alpha = 0.45f)); Text(v, fontSize = 14.sp) }
}

// MARK: Series

@Composable
fun SeriesDetailScreen(series: Series) {
    val model = appModel
    val user by model.user.collectAsStateWithLifecycle()
    var episodes by remember { mutableStateOf<List<Episode>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var season by remember { mutableIntStateOf(1) }
    LaunchedEffect(series.id) {
        episodes = model.episodes(series)
        season = episodes.minOfOrNull { it.season } ?: 1
        loading = false
    }
    val seasons = remember(episodes) { episodes.map { it.season }.distinct().sorted() }
    val current = remember(episodes, season) { episodes.filter { it.season == season }.sortedBy { it.number } }

    fun play(ep: Episode) {
        val all = episodes.sortedWith(compareBy({ it.season }, { it.number }))
        val idx = all.indexOf(ep)
        val queue = all.drop(idx + 1).map { VodRequest(it.id, "${series.title} · ${it.title}", it.stream, series.poster) }
        val p = user.progress[ep.id]
        val at = if (p == null || p.isFinished) 0L else maxOf(0L, p.positionMs - 3000)
        UiState.play(VodRequest(ep.id, "${series.title} · ${ep.title}", ep.stream, series.poster), queue, at)
    }

    Column(Modifier.fillMaxSize()) {
        PageHeader("")
        LazyColumn(contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, 32.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Bottom) {
                    PosterImage(series.poster, Modifier.width(120.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(series.title, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            series.year?.let { QualityBadge(it) }
                            series.rating?.takeIf { it > 0 }?.let { QualityBadge("★ %.1f".format(it)) }
                        }
                    }
                }
                series.plot?.let { Text(it, fontSize = 14.sp, color = Color.White.copy(alpha = 0.7f), modifier = Modifier.padding(top = 12.dp)) }
            }
            when {
                loading -> item { Text("Loading episodes…", color = Color.White.copy(alpha = 0.55f), modifier = Modifier.padding(top = 20.dp)) }
                episodes.isEmpty() -> item { Text("No episodes found.", color = Color.White.copy(alpha = 0.55f), modifier = Modifier.padding(top = 20.dp)) }
                else -> {
                    if (seasons.size > 1) item {
                        Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            seasons.forEach { s -> Chip("Season $s", season == s) { season = s } }
                        }
                    }
                    items(current, key = { it.id }) { ep ->
                        val p = user.progress[ep.id]
                        Row(Modifier.fillMaxWidth().rowCard().clickable { play(ep) }.padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text("${ep.number}", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.6f), modifier = Modifier.width(34.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(ep.title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                ep.plot?.let { Text(it, fontSize = 12.sp, color = Color.White.copy(alpha = 0.6f), maxLines = 2, overflow = TextOverflow.Ellipsis) }
                                if (p != null && !p.isFinished) LinearProgressIndicator(progress = { p.fraction.toFloat() }, Modifier.fillMaxWidth().height(3.dp), color = Pal.accent, trackColor = Color.White.copy(alpha = 0.15f))
                            }
                            Icon(if (p?.isFinished == true) Icons.Filled.CheckCircle else Icons.Filled.PlayCircle, null, tint = if (p?.isFinished == true) Pal.accent else Color.White.copy(alpha = 0.6f))
                        }
                    }
                }
            }
        }
    }
}

// MARK: Search

@Composable
fun SearchScreen() {
    val model = appModel
    val guide by model.guideVersion.collectAsStateWithLifecycle()
    var query by remember { mutableStateOf("") }
    val result by produceState(Pair(SearchResults(), emptyList<Pair<Programme, Channel>>()), query, guide) {
        delay(160)
        value = Pair(model.search(query), model.programmeSearch(query))
    }
    val (r, programmes) = result

    Column(Modifier.fillMaxSize()) {
        LargeTitle("Search")
        OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp), singleLine = true, placeholder = { Text("Channels, shows, movies") })
        if (query.isBlank()) {
            Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Search everything", fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Text("Channels, what's on now and next,\nmovies and series — in one box.", color = Color.White.copy(alpha = 0.55f), modifier = Modifier.padding(top = 8.dp))
            }
        } else if (r.isEmpty && programmes.isEmpty()) {
            Text("No results for \"$query\"", Modifier.padding(24.dp), color = Color.White.copy(alpha = 0.55f))
        }
        LazyColumn(contentPadding = PaddingValues(16.dp, 12.dp, 16.dp, 168.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (r.channels.isNotEmpty()) item { SectionTitle("Channels") }
            items(r.channels, key = { "c" + it.id }) { ch ->
                Row(Modifier.fillMaxWidth().clickable { UiState.play(ch, r.channels) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    LogoImage(ch.logo, 40.dp, 10.dp)
                    Column { Text(ch.name, fontSize = 16.sp); model.nowNext(ch).now?.let { Text(it.title, fontSize = 12.sp, color = Color.White.copy(alpha = 0.55f)) } }
                }
            }
            if (programmes.isNotEmpty()) item { SectionTitle("On TV soon") }
            items(programmes, key = { "p" + it.first.id }) { (p, ch) ->
                Column(Modifier.fillMaxWidth().clickable { UiState.play(ch) }.padding(vertical = 6.dp)) {
                    Text(p.title, fontSize = 16.sp)
                    Text("${ch.name} · ${Fmt.time(p.start)}", fontSize = 12.sp, color = Color.White.copy(alpha = 0.55f))
                }
            }
            if (r.movies.isNotEmpty()) item { SectionTitle("Movies") }
            items(r.movies, key = { "m" + it.id }) { m ->
                Row(Modifier.fillMaxWidth().clickable { UiState.push(Page.Movie(m)) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PosterImage(m.poster, Modifier.width(34.dp), 6.dp); Text(m.title, fontSize = 16.sp)
                }
            }
            if (r.series.isNotEmpty()) item { SectionTitle("Series") }
            items(r.series, key = { "s" + it.id }) { s ->
                Row(Modifier.fillMaxWidth().clickable { UiState.push(Page.SeriesPage(s)) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    PosterImage(s.poster, Modifier.width(34.dp), 6.dp); Text(s.title, fontSize = 16.sp)
                }
            }
        }
    }
}

@Composable
private fun SectionTitle(t: String) = Text(t, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.5f), modifier = Modifier.padding(top = 12.dp, bottom = 4.dp))
