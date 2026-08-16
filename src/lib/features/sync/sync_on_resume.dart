import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sync_controller.dart';

/// Runs a sync pass whenever the app returns to the foreground, so the local
/// list converges with the cloud after backgrounding (architecture §4.13).
class SyncOnResume extends ConsumerStatefulWidget {
  const SyncOnResume({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SyncOnResume> createState() => _SyncOnResumeState();
}

class _SyncOnResumeState extends ConsumerState<SyncOnResume>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(syncControllerProvider.notifier).syncNow();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
