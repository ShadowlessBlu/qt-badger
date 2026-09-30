import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Tasks on the badge (max 8): tick off, delete, add by typing / dictating / scheduling,
/// or paste an agenda and let the organizer split it into reminders.
class TasksPage extends StatelessWidget {
  const TasksPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final st = app.status;
    final tasks = st?.tasks ?? const <TaskItem>[];
    final enabled = app.badgeAnswering;

    return Scaffold(
      appBar: AppBar(
        title: Text(tasks.isEmpty ? 'Tasks' : 'Tasks  ${st!.openTasks}/${tasks.length}'),
        actions: [
          IconButton(
            tooltip: 'AI organizer',
            icon: const Icon(Icons.auto_awesome),
            onPressed: enabled ? () => showOrganizerSheet(context) : null,
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'clear':
                  app.clearDone();
                case 'read':
                  app.speakOnPhone(tasks.where((t) => !t.done).map((t) => t.text).join('. '));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'clear', enabled: enabled && tasks.any((t) => t.done), child: const Text('Clear completed')),
              PopupMenuItem(value: 'read', enabled: tasks.any((t) => !t.done), child: const Text('Read open tasks aloud')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: enabled ? () => showAddTaskSheet(context) : null,
        icon: const Icon(Icons.add),
        label: const Text('Add task'),
      ),
      body: RefreshIndicator(
        onRefresh: app.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
          children: [
            const ConnectionBanner(),
            if (st != null) ...[_Capacity(count: tasks.length), const SizedBox(height: 12)],
            if (tasks.isEmpty && st != null)
              const EmptyState(
                icon: Icons.checklist_rtl,
                title: 'No tasks on the badge',
                hint: 'Add one with the button below, or tap the sparkles to turn a pasted agenda into reminders.',
              ),
            for (final t in tasks)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TaskTile(task: t),
              ),
            if (st != null && st.reminders.isNotEmpty) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: 'Scheduled reminders',
                accent: Palette.amber,
                child: Column(
                  children: [
                    for (final r in st.reminders)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.alarm, color: Palette.amber),
                        title: Text(r.text),
                        subtitle: Text(DateFormat('EEE d MMM, HH:mm').format(r.at)),
                        trailing: IconButton(icon: const Icon(Icons.close), tooltip: 'Cancel', onPressed: () => app.deleteReminder(r)),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Capacity extends StatelessWidget {
  const _Capacity({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(value: count / 8, minHeight: 6, color: count >= 8 ? Palette.coral : Palette.amber),
        ),
        const SizedBox(height: 4),
        Text(
          count >= 8 ? 'The badge holds 8 tasks - it is full. Clear some to add more.' : '$count of 8 slots used',
          style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final TaskItem task;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('${task.index}-${task.text}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: Palette.danger.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(16)),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => app.deleteTask(task),
      child: Card(
        child: ListTile(
          leading: Checkbox(value: task.done, onChanged: (_) => app.toggleTask(task), activeColor: Palette.amber),
          title: Text(
            task.text,
            style: TextStyle(decoration: task.done ? TextDecoration.lineThrough : null, color: task.done ? scheme.onSurfaceVariant : null),
          ),
          trailing: IconButton(
            icon: const Icon(Icons.volume_up_outlined),
            tooltip: 'Read aloud',
            onPressed: () => app.speakOnPhone(task.text),
          ),
          onTap: () => app.toggleTask(task),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- add a task
Future<void> showAddTaskSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const _AddTaskSheet());

class _AddTaskSheet extends StatefulWidget {
  const _AddTaskSheet();

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  final _text = TextEditingController();
  DateTime? _remindAt;
  bool _listening = false;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
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
          _text.text = t.length > 80 ? t.substring(0, 80) : t;
          _text.selection = TextSelection.collapsed(offset: _text.text.length);
          if (isFinal) _listening = false;
        });
      },
      onStatus: (s) {
        if (mounted && (s == 'done' || s == 'notListening')) setState(() => _listening = false);
      },
      onError: (e) {
        if (mounted) setState(() => _listening = false);
        app.toast('Speech recognition: $e', error: true);
      },
    );
    if (!mounted) return;
    if (!ok) app.toast('Speech recognition is not available (check the microphone permission).', error: true);
    setState(() => _listening = ok);
  }

  Future<void> _pickTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(context: context, initialDate: now, firstDate: now, lastDate: now.add(const Duration(days: 365)));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 30))));
    if (time == null) return;
    setState(() => _remindAt = DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _submit() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final app = context.read<AppState>();
    setState(() => _busy = true);
    final ok = _remindAt == null ? await app.addTask(text) : await app.addReminder(text, _remindAt!);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + inset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('New task', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: 'e.g. Meet Alex near stage B',
              suffixIcon: IconButton(
                tooltip: _listening ? 'Stop dictating' : 'Dictate',
                icon: Icon(_listening ? Icons.mic : Icons.mic_none, color: _listening ? Palette.danger : null),
                onPressed: _dictate,
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(label: const Text('Now'), selected: _remindAt == null, onSelected: (_) => setState(() => _remindAt = null)),
              ActionChip(
                avatar: const Icon(Icons.alarm, size: 18),
                label: const Text('In 10 min'),
                onPressed: () => setState(() => _remindAt = DateTime.now().add(const Duration(minutes: 10))),
              ),
              ActionChip(
                avatar: const Icon(Icons.alarm, size: 18),
                label: const Text('In 1 hour'),
                onPressed: () => setState(() => _remindAt = DateTime.now().add(const Duration(hours: 1))),
              ),
              ActionChip(avatar: const Icon(Icons.event, size: 18), label: const Text('Pick time...'), onPressed: _pickTime),
            ],
          ),
          if (_remindAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'It will appear on the badge (with a banner and a buzz) at ${DateFormat('EEE d MMM, HH:mm').format(_remindAt!)}.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(_remindAt == null ? Icons.add : Icons.schedule),
              label: Text(_remindAt == null ? 'Add to badge' : 'Schedule reminder'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------- AI organizer
Future<void> showOrganizerSheet(BuildContext context) =>
    showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => const _OrganizerSheet());

class _OrganizerSheet extends StatefulWidget {
  const _OrganizerSheet();

  @override
  State<_OrganizerSheet> createState() => _OrganizerSheetState();
}

class _OrganizerSheetState extends State<_OrganizerSheet> {
  final _text = TextEditingController();
  String _engine = 'auto';
  OrganizeJob? _job;
  bool _running = false;
  bool _listening = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _text.text = data!.text!);
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
          _text.text = t;
          if (isFinal) _listening = false;
        });
      },
      onStatus: (s) {
        if (mounted && (s == 'done' || s == 'notListening')) setState(() => _listening = false);
      },
      onError: (e) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!mounted) return;
    if (!ok) app.toast('Speech recognition is not available (check the microphone permission).', error: true);
    setState(() => _listening = ok);
  }

  Future<void> _run() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _running = true;
      _job = null;
    });
    final job = await context.read<AppState>().organize(
      text,
      engine: _engine,
      onProgress: (j) {
        if (mounted) setState(() => _job = j);
      },
    );
    if (!mounted) return;
    setState(() {
      _running = false;
      if (job != null) _job = job;
    });
    if (job != null && job.done) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    final scheme = Theme.of(context).colorScheme;
    final job = _job;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + inset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Schedule organizer', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Paste or dictate an agenda. Each action item becomes a short reminder on the badge.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 4,
              maxLines: 8,
              maxLength: 4000,
              decoration: InputDecoration(hintText: 'e.g. Meet Alex near stage B at 2pm. Check the booth 12 demo. Pick up lanyards.'),
            ),
            Row(
              children: [
                TextButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste), label: const Text('Paste')),
                TextButton.icon(
                  onPressed: _dictate,
                  icon: Icon(_listening ? Icons.mic : Icons.mic_none, color: _listening ? Palette.danger : null),
                  label: Text(_listening ? 'Listening...' : 'Dictate'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'auto', label: Text('Auto'), icon: Icon(Icons.auto_awesome)),
                ButtonSegment(value: 'rules', label: Text('Instant'), icon: Icon(Icons.bolt)),
                ButtonSegment(value: 'llm', label: Text('AI only'), icon: Icon(Icons.psychology)),
              ],
              selected: {_engine},
              onSelectionChanged: (s) => setState(() => _engine = s.first),
            ),
            const SizedBox(height: 6),
            Text(switch (_engine) {
              'rules' => 'Splits the text into sentences and lines. Instant, works offline.',
              'llm' => 'Only the on-board model (Gemma 3 1B). It runs at a few words per second, so expect a minute or more.',
              _ => 'Tries the on-board model, and falls back to the instant splitter if it is slow or returns nothing.',
            }, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : _run,
                icon: _running
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.playlist_add),
                label: Text(_running ? 'Working... ${job?.seconds.round() ?? 0}s' : 'Extract and push to badge'),
              ),
            ),
            if (job != null && !job.running) ...[const SizedBox(height: 12), _Result(job: job)],
          ],
        ),
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.job});
  final OrganizeJob job;

  @override
  Widget build(BuildContext context) {
    final ok = job.done;
    final color = ok ? Palette.green : Palette.coral;
    final engine = switch (job.engine) {
      'llm-tool' => 'on-board AI',
      'llm-text' => 'on-board AI (text)',
      'rules' => 'instant splitter',
      _ => job.engine ?? '',
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ok ? 'Added ${job.added.length} reminder${job.added.length == 1 ? '' : 's'} using $engine' : (job.error ?? 'Nothing was added'),
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
          for (final a in job.added) Padding(padding: const EdgeInsets.only(top: 4), child: Text('- $a')),
          if (job.skipped > 0) Text('${job.skipped} duplicate(s) skipped', style: const TextStyle(fontSize: 12.5)),
          if (job.listFull)
            const Text("The badge's list filled up - clear some tasks and run again for the rest.", style: TextStyle(fontSize: 12.5)),
        ],
      ),
    );
  }
}
