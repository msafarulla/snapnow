import 'package:flutter/material.dart';

/// SnapNow's look: neutral macOS-like greys (no Material seed tints), one accent, compact desktop controls
/// with no ink ripples, and one "chrome" style shared by every floating card (toolbar, inspector, colour
/// bar, zoom pill, filmstrip): a translucent surface, 14 px corners, a hairline border and a soft shadow.
class SnapTheme {
  static const accent = Color(0xFF2F7CF6);

  static final light = _build(
    brightness: Brightness.light,
    scheme: const ColorScheme.light(
      primary: accent,
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFDCE8FD),
      onPrimaryContainer: Color(0xFF0B3F94),
      secondary: Color(0xFF6B6B73),
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: Color(0xFF1C1C1E),
      onSurfaceVariant: Color(0xFF6B6B73),
      surfaceBright: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: Color(0xFFF5F5F8),
      surfaceContainer: Color(0xFFF0F0F4),
      surfaceContainerHigh: Color(0xFFEAEAEF),
      surfaceContainerHighest: Color(0xFFE2E2E8),
      outline: Color(0xFFC4C4CC),
      outlineVariant: Color(0xFFE3E3E8),
      error: Color(0xFFE5484D),
      onError: Colors.white,
      inverseSurface: Color(0xFF2C2C2E),
      onInverseSurface: Color(0xFFF2F2F7),
      shadow: Colors.black,
    ),
    chrome: const SnapChrome(
      backdrop: Color(0xFFE9E9EE),
      card: Color(0xF2FFFFFF),
      border: Color(0x1F000000),
      shadow: [BoxShadow(color: Color(0x1F000000), blurRadius: 18, offset: Offset(0, 6)),
          BoxShadow(color: Color(0x0F000000), blurRadius: 3, offset: Offset(0, 1))],
      control: Color(0xFFF0F0F4),
      controlBorder: Color(0xFFDADAE0),
      raised: Colors.white,
    ),
  );

  static final dark = _build(
    brightness: Brightness.dark,
    scheme: const ColorScheme.dark(
      primary: Color(0xFF5A96F8),
      onPrimary: Color(0xFF07152E),
      primaryContainer: Color(0xFF1E3A6B),
      onPrimaryContainer: Color(0xFFD3E2FF),
      secondary: Color(0xFFA0A0A8),
      onSecondary: Color(0xFF1C1C1E),
      surface: Color(0xFF232326),
      onSurface: Color(0xFFEDEDF2),
      onSurfaceVariant: Color(0xFFA3A3AB),
      surfaceBright: Color(0xFF3E3E44),
      surfaceContainerLowest: Color(0xFF151517),
      surfaceContainerLow: Color(0xFF1B1B1E),
      surfaceContainer: Color(0xFF242428),
      surfaceContainerHigh: Color(0xFF2C2C31),
      surfaceContainerHighest: Color(0xFF35353B),
      outline: Color(0xFF4E4E56),
      outlineVariant: Color(0xFF323238),
      error: Color(0xFFF2555A),
      onError: Color(0xFF2B0507),
      inverseSurface: Color(0xFFEDEDF2),
      onInverseSurface: Color(0xFF1C1C1E),
      shadow: Colors.black,
    ),
    chrome: const SnapChrome(
      backdrop: Color(0xFF121214),
      card: Color(0xF2242428),
      border: Color(0x24FFFFFF),
      shadow: [BoxShadow(color: Color(0x66000000), blurRadius: 22, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))],
      control: Color(0xFF303036),
      controlBorder: Color(0xFF45454C),
      raised: Color(0xFF3E3E44),
    ),
  );

  /// Matches the Ghostty terminal (tokyonight + FiraMono), like the Swift app's Tokyo Night theme.
  static final tokyoNight = _build(
    brightness: Brightness.dark,
    fontFamily: 'FiraMono Nerd Font Mono',
    scheme: const ColorScheme.dark(
      primary: Color(0xFF7AA2F7),
      onPrimary: Color(0xFF1A1B26),
      primaryContainer: Color(0xFF2B3B6B),
      onPrimaryContainer: Color(0xFFC0CAF5),
      secondary: Color(0xFFBB9AF7),
      onSecondary: Color(0xFF1A1B26),
      surface: Color(0xFF1F2335),
      onSurface: Color(0xFFC0CAF5),
      onSurfaceVariant: Color(0xFFA9B1D6),
      surfaceBright: Color(0xFF3B4261),
      surfaceContainerLowest: Color(0xFF16161E),
      surfaceContainerLow: Color(0xFF1A1B26),
      surfaceContainer: Color(0xFF1F2335),
      surfaceContainerHigh: Color(0xFF24283B),
      surfaceContainerHighest: Color(0xFF292E42),
      outline: Color(0xFF565F89),
      outlineVariant: Color(0xFF2F334D),
      error: Color(0xFFF7768E),
      onError: Color(0xFF1A1B26),
      inverseSurface: Color(0xFFC0CAF5),
      onInverseSurface: Color(0xFF1A1B26),
      shadow: Colors.black,
    ),
    chrome: const SnapChrome(
      backdrop: Color(0xFF16161E),
      card: Color(0xF21F2335),
      border: Color(0x2EC0CAF5),
      shadow: [BoxShadow(color: Color(0x66000000), blurRadius: 22, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))],
      control: Color(0xFF292E42),
      controlBorder: Color(0xFF3B4261),
      raised: Color(0xFF3B4261),
    ),
  );

  static ThemeData _build({required Brightness brightness, required ColorScheme scheme, required SnapChrome chrome, String? fontFamily}) {
    final dark = brightness == Brightness.dark;
    final body = TextStyle(fontFamily: fontFamily, color: scheme.onSurface, fontSize: 13, height: 1.3, letterSpacing: -0.1);
    final menuShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(11), side: BorderSide(color: chrome.border));
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: scheme.surfaceContainerLow,
      canvasColor: scheme.surface,
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: scheme.onSurface.withValues(alpha: 0.06),
      hoverColor: scheme.onSurface.withValues(alpha: 0.05),
      focusColor: scheme.primary.withValues(alpha: 0.12),
      dividerColor: scheme.outlineVariant,
      extensions: [chrome],
      textTheme: TextTheme(
        bodyLarge: body.copyWith(fontSize: 14),
        bodyMedium: body,
        bodySmall: body.copyWith(fontSize: 11.5, color: scheme.onSurfaceVariant),
        labelLarge: body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
        labelMedium: body.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
        labelSmall: body.copyWith(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: scheme.onSurfaceVariant),
        titleLarge: body.copyWith(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.3),
        titleMedium: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -0.2),
        titleSmall: body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 18),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1, space: 1),
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? scheme.surfaceContainerHigh : scheme.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.6 : 0.25),
        elevation: 10,
        shape: menuShape,
        menuPadding: const EdgeInsets.symmetric(vertical: 6),
        textStyle: body,
        labelTextStyle: WidgetStatePropertyAll(body),
      ),
      menuTheme: MenuThemeData(style: MenuStyle(shape: WidgetStatePropertyAll(menuShape), surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent))),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        verticalOffset: 16,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        textStyle: TextStyle(fontFamily: fontFamily, fontSize: 11.5, color: scheme.onInverseSurface, height: 1.25),
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(7),
          boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: chrome.border)),
        titleTextStyle: body.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
        contentTextStyle: body,
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: chrome.control,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        hintStyle: body.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.8)),
        labelStyle: body.copyWith(color: scheme.onSurfaceVariant),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: chrome.controlBorder)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: chrome.controlBorder)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: scheme.primary, width: 1.5)),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        side: BorderSide(color: scheme.outline, width: 1.2),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : Colors.transparent),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          textStyle: body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: chrome.controlBorder),
          textStyle: body.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: 0.25)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      sliderTheme: SliderThemeData(overlayShape: SliderComponentShape.noOverlay),
    );
  }
}

/// The shared style of every floating card, read with `SnapChrome.of(context)`.
class SnapChrome extends ThemeExtension<SnapChrome> {
  /// The editor's background behind the picture.
  final Color backdrop;
  /// A floating card's fill (slightly translucent), its hairline border and its shadow.
  final Color card, border;
  final List<BoxShadow> shadow;
  /// Controls inside a card (dropdowns, segmented tracks, fields) and their border; `raised` is the
  /// lit part of a control (a segmented control's thumb).
  final Color control, controlBorder, raised;

  const SnapChrome({required this.backdrop, required this.card, required this.border, required this.shadow,
      required this.control, required this.controlBorder, required this.raised});

  static SnapChrome of(BuildContext context) => Theme.of(context).extension<SnapChrome>() ?? _fallback(Theme.of(context));

  static SnapChrome _fallback(ThemeData t) => t.brightness == Brightness.dark
      ? SnapTheme.dark.extension<SnapChrome>()!
      : SnapTheme.light.extension<SnapChrome>()!;

  static const radius = 14.0;

  /// A floating card.
  BoxDecoration decoration({double radius = SnapChrome.radius, bool opaque = false}) => BoxDecoration(
        color: opaque ? card.withValues(alpha: 1) : card,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border, width: 0.8),
        boxShadow: shadow,
      );

  /// A floating pill (fully rounded ends).
  BoxDecoration pill() => BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: border, width: 0.8),
        boxShadow: shadow,
      );

  /// A control inside a card.
  BoxDecoration controlBox({double radius = 7}) => BoxDecoration(
        color: control,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: controlBorder, width: 0.8),
      );

  @override
  SnapChrome copyWith({Color? backdrop, Color? card, Color? border, List<BoxShadow>? shadow, Color? control, Color? controlBorder, Color? raised}) =>
      SnapChrome(
        backdrop: backdrop ?? this.backdrop,
        card: card ?? this.card,
        border: border ?? this.border,
        shadow: shadow ?? this.shadow,
        control: control ?? this.control,
        controlBorder: controlBorder ?? this.controlBorder,
        raised: raised ?? this.raised,
      );

  @override
  SnapChrome lerp(SnapChrome? other, double t) {
    if (other == null) return this;
    return SnapChrome(
      backdrop: Color.lerp(backdrop, other.backdrop, t)!,
      card: Color.lerp(card, other.card, t)!,
      border: Color.lerp(border, other.border, t)!,
      shadow: BoxShadow.lerpList(shadow, other.shadow, t) ?? shadow,
      control: Color.lerp(control, other.control, t)!,
      controlBorder: Color.lerp(controlBorder, other.controlBorder, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
    );
  }
}
