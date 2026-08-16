import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/sync/sync_on_resume.dart';
import 'bootstrap.dart';
import 'router.dart';
import 'theme.dart';

/// App root (architecture §3.3 `app/`).
class KnowledgeCompanionApp extends StatelessWidget {
  const KnowledgeCompanionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: bootstrapOverrides,
      child: MaterialApp.router(
        title: 'AI Knowledge Companion',
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: ThemeMode.system,
        routerConfig: appRouter,
        debugShowCheckedModeBanner: false,
        builder: (context, child) => SyncOnResume(child: child!),
      ),
    );
  }
}
