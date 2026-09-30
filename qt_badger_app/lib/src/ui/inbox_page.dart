import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

const _quickMessages = ['Come to the booth', 'Running late - 10 min', 'Meet at the entrance', 'Coffee?', 'Call me', 'Need a hand here'];

/// Messages pushed to the badge: they pop up as a banner with a buzz, then wait in the badge's Inbox screen (5 max).
class InboxPage extends StatelessWidget {
  const InboxPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final msgs = st?.messages ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inbox'),
        actions: [
          IconButton(
            tooltip: 'Clear inbox',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: msgs.isEmpty || !app.badgeAnswering ? null : app.clearMessages,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: app.refresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                children: [
                  const ConnectionBanner(),
                  if (msgs.isEmpty && st != null)
                    const EmptyState(
                      icon: Icons.mail_outline,
                      title: "The badge's inbox is empty",
                      hint: 'Messages you send show up on the badge with a buzz, and stay here until deleted. It keeps the latest 5.',
                    ),
                  for (final m in msgs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Dismissible(
                        key: ValueKey('${m.index}-${m.text}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          decoration: BoxDecoration(color: Palette.danger.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(16)),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) => app.deleteMessage(m),
                        child: Card(
                          child: ListTile(
                            leading: Icon(m.unread ? Icons.mark_email_unread : Icons.drafts_outlined, color: m.unread ? Palette.sky : null),
                            title: Text(m.text),
                            subtitle: Text(m.unread ? 'Not opened on the badge yet' : 'Read'),
                            trailing: IconButton(
                              icon: const Icon(Icons.replay),
                              tooltip: 'Send again',
                              onPressed: () => app.sendMessage(m.text),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          const SafeArea(
            top: false,
            child: Padding(padding: EdgeInsets.fromLTRB(12, 8, 12, 8), child: Composer()),
          ),
        ],
      ),
    );
  }
}

Future<void> showComposeMessage(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (ctx) => Padding(
    padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Message the badge', style: Theme.of(ctx).textTheme.titleLarge),
        const SizedBox(height: 10),
        Composer(autofocus: true, onSent: () => Navigator.of(ctx).pop()),
      ],
    ),
  ),
);

/// Text box + quick replies + send. Used inline on the Inbox page and in the sheet on the Badge tab.
class Composer extends StatefulWidget {
  const Composer({super.key, this.autofocus = false, this.onSent});
  final bool autofocus;
  final VoidCallback? onSent;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  bool _buzz = true;
  bool _listening = false;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _text.text).trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final ok = await context.read<AppState>().sendMessage(text, buzz: _buzz);
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) {
      _text.clear();
      widget.onSent?.call();
    }
  }

  Future<void> _dictate() async {
    final app = context.read<AppState>();
    if (_listening) {
      await app.speech.stopListening();
      setState(() => _listening = false);
      return;
    }
    final ok = await app.speech.listen(
      onResult: (t, isFinal) {
        if (!mounted) return;
        setState(() {
          _text.text = t.length > 96 ? t.substring(0, 96) : t;
          if (isFinal) _listening = false;
        });
      },
      onStatus: (s) {
        if (mounted && (s == 'done' || s == 'notListening')) setState(() => _listening = false);
      },
      onError: (_) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!mounted) return;
    if (!ok) app.toast('Speech recognition is not available (check the microphone permission).', error: true);
    setState(() => _listening = ok);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<AppState, bool>((a) => a.badgeAnswering);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final q in _quickMessages)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(label: Text(q), onPressed: enabled ? () => _send(q) : null, visualDensity: VisualDensity.compact),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                autofocus: widget.autofocus,
                maxLength: 96,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message for the badge...',
                  counterText: '',
                  suffixIcon: IconButton(
                    tooltip: 'Dictate',
                    icon: Icon(_listening ? Icons.mic : Icons.mic_none, color: _listening ? Palette.danger : null),
                    onPressed: _dictate,
                  ),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled && !_sending ? () => _send() : null,
              icon: _sending
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
            ),
          ],
        ),
        Row(
          children: [
            Checkbox(value: _buzz, onChanged: (v) => setState(() => _buzz = v ?? true)),
            const Text('Buzz when it arrives'),
          ],
        ),
      ],
    );
  }
}
