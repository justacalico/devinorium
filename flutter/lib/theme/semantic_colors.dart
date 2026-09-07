import 'package:flutter/material.dart';

/// Semantic colors used for statuses, badges, and code highlighting.
///
/// These live outside [ColorScheme] because Material has no success, warning,
/// or info slots. They are populated from the active [ColorTheme] when the
/// theme defines matching tokens, and fall back to a tuned light/dark palette
/// so widgets that run without the app theme still look correct.
@immutable
class SemanticColors extends ThemeExtension<SemanticColors> {
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color info;
  final Color onInfo;
  final Color infoContainer;
  final Color onInfoContainer;

  const SemanticColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.info,
    required this.onInfo,
    required this.infoContainer,
    required this.onInfoContainer,
  });

  static SemanticColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SemanticColors>() ?? fallback(theme.brightness);
  }

  static SemanticColors fallback(Brightness brightness) =>
      fromColors(const {}, brightness);

  static SemanticColors fromColors(
    Map<String, Color> colors,
    Brightness brightness,
  ) {
    final isDark = brightness == Brightness.dark;
    return SemanticColors(
      success:
          colors['success'] ??
          (isDark ? const Color(0xFF22C55E) : const Color(0xFF16A34A)),
      onSuccess:
          colors['on-success'] ??
          (isDark ? const Color(0xFF052E16) : const Color(0xFFFFFFFF)),
      successContainer:
          colors['success-container'] ??
          (isDark ? const Color(0xFF14532D) : const Color(0xFFDCFCE7)),
      onSuccessContainer:
          colors['on-success-container'] ??
          (isDark ? const Color(0xFFDCFCE7) : const Color(0xFF14532D)),
      warning:
          colors['warning'] ??
          (isDark ? const Color(0xFFF59E0B) : const Color(0xFFD97706)),
      onWarning:
          colors['on-warning'] ??
          (isDark ? const Color(0xFF451A03) : const Color(0xFF000000)),
      warningContainer:
          colors['warning-container'] ??
          (isDark ? const Color(0xFF78350F) : const Color(0xFFFEF3C7)),
      onWarningContainer:
          colors['on-warning-container'] ??
          (isDark ? const Color(0xFFFEF3C7) : const Color(0xFF78350F)),
      info:
          colors['info'] ??
          (isDark ? const Color(0xFF0EA5E9) : const Color(0xFF0284C7)),
      onInfo:
          colors['on-info'] ??
          (isDark ? const Color(0xFF082F49) : const Color(0xFFFFFFFF)),
      infoContainer:
          colors['info-container'] ??
          (isDark ? const Color(0xFF0C4A6E) : const Color(0xFFE0F2FE)),
      onInfoContainer:
          colors['on-info-container'] ??
          (isDark ? const Color(0xFFE0F2FE) : const Color(0xFF0C4A6E)),
    );
  }

  @override
  SemanticColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? info,
    Color? onInfo,
    Color? infoContainer,
    Color? onInfoContainer,
  }) {
    return SemanticColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      info: info ?? this.info,
      onInfo: onInfo ?? this.onInfo,
      infoContainer: infoContainer ?? this.infoContainer,
      onInfoContainer: onInfoContainer ?? this.onInfoContainer,
    );
  }

  @override
  SemanticColors lerp(ThemeExtension<SemanticColors>? other, double t) {
    if (other is! SemanticColors) return this;
    return SemanticColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(
        successContainer,
        other.successContainer,
        t,
      )!,
      onSuccessContainer: Color.lerp(
        onSuccessContainer,
        other.onSuccessContainer,
        t,
      )!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      onWarningContainer: Color.lerp(
        onWarningContainer,
        other.onWarningContainer,
        t,
      )!,
      info: Color.lerp(info, other.info, t)!,
      onInfo: Color.lerp(onInfo, other.onInfo, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      onInfoContainer: Color.lerp(onInfoContainer, other.onInfoContainer, t)!,
    );
  }
}
