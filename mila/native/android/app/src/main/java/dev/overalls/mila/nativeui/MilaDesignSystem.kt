package dev.overalls.mila.nativeui

import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.foundation.isSystemInDarkTheme

object MilaColors { val LightText=Color(0xFF000000); val LightTextAlt=Color(0xFF666666); val LightBackground=Color(0xFFFFFFFF); val LightBackgroundAlt=Color(0xFFEEEEEE); val DarkText=Color(0xFFFFFFFF); val DarkTextAlt=Color(0xFFAAAAAA); val DarkBackground=Color(0xFF000000); val DarkBackgroundAlt=Color(0xFF111111) }
val MilaMono = FontFamily.Monospace
@Composable fun MilaTheme(settings: MilaSettings = MilaSettings(), content: @Composable () -> Unit) {
    val dark = when (settings.appearance) {
        MilaAppearance.Dark -> true
        MilaAppearance.Light -> false
        MilaAppearance.System -> isSystemInDarkTheme()
    }
    val colors = if (dark) darkColorScheme(
        primary = MilaColors.DarkText, onPrimary = MilaColors.DarkBackground,
        background = MilaColors.DarkBackground, onBackground = MilaColors.DarkText,
        surface = MilaColors.DarkBackgroundAlt, onSurface = MilaColors.DarkText,
    ) else lightColorScheme(
        primary = MilaColors.LightText, onPrimary = MilaColors.LightBackground,
        background = MilaColors.LightBackground, onBackground = MilaColors.LightText,
        surface = MilaColors.LightBackgroundAlt, onSurface = MilaColors.LightText,
    )
    val direction = if (milaLocaleDirection(settings.locale) == MilaLocaleDirection.Rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
    CompositionLocalProvider(LocalLayoutDirection provides direction) {
        MaterialTheme(colorScheme = colors, typography = Typography().copy(
            bodyLarge = Typography().bodyLarge.copy(fontFamily = MilaMono),
            bodyMedium = Typography().bodyMedium.copy(fontFamily = MilaMono),
        ), content = content)
    }
}
val MilaBorderWidth = 2.dp
