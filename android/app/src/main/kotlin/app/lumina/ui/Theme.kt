package app.lumina.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import java.text.DateFormat
import java.util.Date

object Pal {
    val accent = Color(0xFF59CCFF)
    val accent2 = Color(0xFF9973FF)
    val live = Color(0xFFFF4D59)
    val bg = Color(0xFF080A12)
    val gradient = Brush.linearGradient(listOf(accent, accent2))
}

@Composable
fun LuminaTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Pal.accent, secondary = Pal.accent2, background = Pal.bg, surface = Color(0xFF12141F),
            onPrimary = Color.Black, onBackground = Color.White, onSurface = Color.White,
            surfaceVariant = Color(0xFF1A1D2B), onSurfaceVariant = Color(0xFFB8BCCB),
        ),
    ) {
        // Outside a Material Surface the default text colour is black; this is a dark-only app.
        androidx.compose.runtime.CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides Color.White) { content() }
    }
}

/** Deep, quiet backdrop with two soft colour pools. Cheap: static gradients only. */
@Composable
fun AppBackground(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier
            .fillMaxSize()
            .background(Pal.bg)
            .drawBehind {
                drawRect(Brush.radialGradient(listOf(Pal.accent.copy(alpha = 0.22f), Color.Transparent), center = Offset(0f, 0f), radius = size.minDimension * 0.95f))
                drawRect(Brush.radialGradient(listOf(Pal.accent2.copy(alpha = 0.20f), Color.Transparent), center = Offset(size.width, size.height), radius = size.minDimension * 1.05f))
            },
    ) { content() }
}

/** Frosted, translucent surface with a soft highlight edge. Used for chrome (bars, chips, buttons), not every list row. */
fun Modifier.glass(radius: Dp = 22.dp, tint: Color = Color.Transparent, backdrop: Color = Color.Transparent): Modifier {
    val shape = RoundedCornerShape(radius)
    return this
        .clip(shape)
        .background(backdrop, shape)
        .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.07f))), shape)
        .background(tint, shape)
        .border(BorderStroke(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.30f), Color.White.copy(alpha = 0.06f)))), shape)
}

/** Flat translucent fill for list rows (cheap to draw in long lists). */
fun Modifier.rowCard(radius: Dp = 16.dp): Modifier = this.clip(RoundedCornerShape(radius)).background(Color.White.copy(alpha = 0.06f))

@Composable
fun GlassIconButton(icon: ImageVector, desc: String, size: Dp = 44.dp, tint: Color = Color.Transparent, onClick: () -> Unit) {
    Box(
        Modifier.size(size).glass(size / 2, tint).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(icon, desc, Modifier.size(size * 0.46f), tint = Color.White) }
}

@Composable
fun Chip(title: String, selected: Boolean = false, icon: ImageVector? = null, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .clip(shape)
            .then(if (selected) Modifier.background(Pal.gradient, shape) else Modifier.glass(50.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) Icon(icon, null, Modifier.size(15.dp), tint = if (selected) Color.Black else Color.White)
        Text(title, color = if (selected) Color.Black else Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
    }
}

@Composable
fun QualityBadge(text: String) {
    Text(
        text, color = Color.White.copy(alpha = 0.7f), fontSize = 10.sp, fontWeight = FontWeight.Bold,
        modifier = Modifier.clip(RoundedCornerShape(4.dp)).background(Color.White.copy(alpha = 0.14f)).padding(horizontal = 5.dp, vertical = 1.5.dp),
    )
}

@Composable
fun LiveDot() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(Pal.live))
        Text("LIVE", color = Pal.live, fontSize = 10.sp, fontWeight = FontWeight.ExtraBold)
    }
}

@Composable
fun LogoImage(url: String?, size: Dp = 54.dp, corner: Dp = 12.dp, placeholder: ImageVector = Icons.Filled.Tv) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(corner)).background(Color.White.copy(alpha = 0.08f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(placeholder, null, Modifier.size(size * 0.38f), tint = Color.White.copy(alpha = 0.25f))
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().padding(5.dp))
    }
}

@Composable
fun PosterImage(url: String?, modifier: Modifier = Modifier, corner: Dp = 14.dp) {
    Box(
        modifier.aspectRatio(2f / 3f).clip(RoundedCornerShape(corner)).background(Color.White.copy(alpha = 0.07f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Movie, null, Modifier.size(32.dp), tint = Color.White.copy(alpha = 0.25f))
        if (url != null) AsyncImage(model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
    }
}

object Fmt {
    private val timeFmt = DateFormat.getTimeInstance(DateFormat.SHORT)
    fun time(ms: Long): String = synchronized(timeFmt) { timeFmt.format(Date(ms)) }
    fun range(start: Long, stop: Long) = "${time(start)} – ${time(stop)}"
    fun duration(ms: Long): String {
        val t = (ms / 1000).toInt()
        val h = t / 3600; val m = (t % 3600) / 60; val s = t % 60
        return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
    }
}
