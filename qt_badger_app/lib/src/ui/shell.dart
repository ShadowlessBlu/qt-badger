import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'home_page.dart';
import 'inbox_page.dart';
import 'map_page.dart';
import 'more_page.dart';
import 'sos_screen.dart';
import 'tasks_page.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _index = 0;
  final List<Widget?> _pages = List.filled(5, null);
  late final AppState _app;

  static const _builders = <Widget Function()>[HomePage.new, TasksPage.new, MapPage.new, InboxPage.new, MorePage.new];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = context.read<AppState>();
    _app.sos.addListener(_onSos);
  }

  @override
  void dispose() {
    _app.sos.removeListener(_onSos);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _app.onResume();
  }

  void _onSos() {
    final event = _app.sos.value;
    if (event == null || !mounted) return;
    _app.sos.value = null;
    Navigator.of(context).push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => SosScreen(event: event)));
  }

  Widget _page(int i) => _pages[i] ??= _builders[i]();

  @override
  Widget build(BuildContext context) {
    final unread = context.select<AppState, int>((a) => a.status?.badge.unread ?? 0);
    _pages[_index] ??= _builders[_index]();
    return PopScope(
      // Back on any other tab returns to the Badge tab first; from there it leaves the app.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() => _index = 0);
          _app.setMapVisible(false);
        }
      },
      child: Scaffold(
        body: IndexedStack(index: _index, children: [for (var i = 0; i < _pages.length; i++) _pages[i] ?? const SizedBox.shrink()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) {
            setState(() {
              _index = i;
              _page(i);
            });
            _app.setMapVisible(i == 2);
          },
          destinations: [
            const NavigationDestination(icon: Icon(Icons.badge_outlined), selectedIcon: Icon(Icons.badge), label: 'Badge'),
            const NavigationDestination(icon: Icon(Icons.checklist_rtl), selectedIcon: Icon(Icons.checklist_rtl), label: 'Tasks'),
            const NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Map'),
            NavigationDestination(
              icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.mail_outline)),
              selectedIcon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.mail)),
              label: 'Inbox',
            ),
            const NavigationDestination(icon: Icon(Icons.apps), label: 'More'),
          ],
        ),
      ),
    );
  }
}
