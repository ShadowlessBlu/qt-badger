// Small building blocks shared by the pages.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'connect_page.dart';
import 'theme.dart';

/// A titled card. The title takes the section's accent colour.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.accent,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
  });
  final String title;
  final Widget child;
  final Color? accent;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 1.2),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color, this.icon});
  final String label;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        border: Border.all(color: c.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: c), const SizedBox(width: 4)],
          Text(
            label,
            style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.icon, this.color});
  final String label;
  final String value;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 20, color: color ?? scheme.primary), const SizedBox(width: 10)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.hint});
  final IconData icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: muted.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shown at the top of pages whenever the hub or the badge can't be reached.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    late final String message;
    IconData icon = Icons.wifi_off;
    Widget? action;

    switch (app.conn) {
      case Conn.online:
        if (st != null && !st.mcu.alive) {
          message = 'The hub is reachable but the badge sketch is not answering. Start the app from App Lab to flash it.';
          icon = Icons.memory;
        } else if (st != null && st.mcu.protocolMismatch) {
          message =
              'The badge is running an older sketch (protocol ${st.mcu.protocol}, expected ${st.mcu.expectedProtocol}). Restart the app in App Lab.';
          icon = Icons.system_update;
        } else {
          return const SizedBox.shrink();
        }
      case Conn.connecting:
        message = 'Connecting to ${app.hubLabel}...';
        icon = Icons.sync;
      case Conn.unauthorized:
        message = 'This hub needs an access key.';
        icon = Icons.lock_outline;
        action = TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectPage())),
          child: const Text('Enter key'),
        );
      case Conn.offline:
        message = "Can't reach the badge at ${app.hubLabel}. ${app.connError ?? ''}".trim();
        action = TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectPage())),
          child: const Text('Fix'),
        );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Palette.amber.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Palette.amber.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: [
              Icon(icon, color: Palette.amber, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(message, style: const TextStyle(color: Palette.amber, fontSize: 13.5)),
              ),
              ?action,
            ],
          ),
        ),
      ),
    );
  }
}

/// A button that only fires after being held down: fills up while pressed.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.icon,
    this.color = Palette.danger,
    this.duration = const Duration(milliseconds: 1400),
    this.height = 64,
  });
  final String label;
  final IconData? icon;
  final Color color;
  final Duration duration;
  final double height;
  final VoidCallback onConfirmed;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onConfirmed();
        _c.reset();
      }
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        HapticFeedback.selectionClick();
        _c.forward(from: 0);
      },
      onPointerUp: (_) => _c.reset(),
      onPointerCancel: (_) => _c.reset(),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Container(
          height: widget.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.35 + 0.4 * _c.value),
                blurRadius: 14 + 14 * _c.value,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: _c.value,
                  child: Container(color: Colors.white.withValues(alpha: 0.35)),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) ...[Icon(widget.icon, color: Colors.white), const SizedBox(width: 10)],
                  Text(
                    _c.value > 0 ? 'Keep holding...' : widget.label,
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String fmtDistance(double? m) {
  if (m == null) return '-';
  return m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(2)} km';
}

String fmtAgo(int seconds) {
  if (seconds < 60) return '${seconds}s ago';
  if (seconds < 3600) return '${seconds ~/ 60} min ago';
  return '${(seconds / 3600).toStringAsFixed(1)} h ago';
}

String fmtDuration(int seconds) {
  if (seconds < 90) return '${seconds}s';
  if (seconds < 5400) return '${(seconds / 60).round()} min';
  return '${(seconds / 3600).toStringAsFixed(1)} h';
}

/// Runs [fn] after the current frame, without an unawaited-future lint.
void later(FutureOr<void> Function() fn) => Future<void>.microtask(fn);
