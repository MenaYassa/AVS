import 'package:go_router/go_router.dart';

import '../features/graph/global_graph_screen.dart';
import '../features/graph/graph_screen.dart';
import '../features/home/home_screen.dart';
import '../features/insights/insights_screen.dart';
import '../features/notes/note_editor_screen.dart';
import '../features/search/search_screen.dart';
import '../features/session_detail/session_detail_screen.dart';
import '../features/settings/settings_screen.dart';

/// go_router configuration (architecture §3.1).
final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
    GoRoute(
      path: '/sessions/:id',
      builder: (_, state) =>
          SessionDetailScreen(sessionId: state.pathParameters['id']!),
    ),
    GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
    GoRoute(path: '/note/new', builder: (_, _) => const NoteEditorScreen()),
    GoRoute(path: '/insights', builder: (_, _) => const InsightsScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    GoRoute(path: '/graph', builder: (_, _) => const GlobalGraphScreen()),
    GoRoute(
      path: '/graph/:id',
      builder: (_, state) =>
          GraphScreen(sessionId: state.pathParameters['id']!),
    ),
  ],
);
