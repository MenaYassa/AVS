import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/repositories.dart';
import 'auth_controller.dart';

/// Authentication / Welcome screen matching the native Manus/AVS design language.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await ref.read(authControllerProvider.notifier).signInWithGoogle();
      final currentUserId = ref.read(authControllerProvider).valueOrNull;
      if (mounted && currentUserId != null) {
        // Sign-in succeeded
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/');
        }
      }
    } on AuthFailure catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.message;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final msg = 'Sign-in failed: ${e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '')}';
        setState(() {
          _errorMessage = msg;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.red.shade800,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final darkBg = const Color(0xFF12131A);
    final cardBg = const Color(0xFF1E202C);
    final borderColor = const Color(0xFF2E3244);

    return Scaffold(
      backgroundColor: darkBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: context.canPop()
            ? IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => context.pop(),
              )
            : null,
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // App Logo / Symbol Icon
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: cardBg,
                    shape: BoxShape.circle,
                    border: Border.all(color: borderColor, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.auto_awesome,
                      color: Colors.white,
                      size: 34,
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // Welcome Header
                Text(
                  'Welcome to AVS',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Capture thoughts out loud, get organized knowledge.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white60,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 36),

                // Error alert if present
                if (_errorMessage != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade900.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red.shade700.withOpacity(0.5)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.white, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // PRIMARY ACTION: Continue with Google
                _AuthButton(
                  icon: _GoogleLogoIcon(),
                  label: 'Continue with Google',
                  isLoading: _isLoading,
                  onPressed: _isLoading ? null : _handleGoogleSignIn,
                  backgroundColor: cardBg,
                  textColor: Colors.white,
                  borderColor: borderColor,
                ),

                const SizedBox(height: 14),

                // Secondary Providers
                _AuthButton(
                  icon: _MicrosoftLogoIcon(),
                  label: 'Continue with Microsoft',
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please use "Continue with Google" for Supabase authentication.'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  backgroundColor: cardBg.withOpacity(0.7),
                  textColor: Colors.white70,
                  borderColor: borderColor.withOpacity(0.6),
                ),

                const SizedBox(height: 14),

                _AuthButton(
                  icon: const Icon(Icons.apple, color: Colors.white, size: 22),
                  label: 'Continue with Apple',
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Please use "Continue with Google" on Android.'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  backgroundColor: cardBg.withOpacity(0.7),
                  textColor: Colors.white70,
                  borderColor: borderColor.withOpacity(0.6),
                ),

                const SizedBox(height: 36),

                // Footer Legal Text
                Text(
                  'By continuing, you agree to our Terms of Service\nand have read our Privacy Policy. © 2026 AI Knowledge Companion',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white38,
                    fontSize: 11,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthButton extends StatelessWidget {
  const _AuthButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.backgroundColor,
    required this.textColor,
    required this.borderColor,
    this.isLoading = false,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final Color textColor;
  final Color borderColor;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: backgroundColor,
          side: BorderSide(color: borderColor, width: 1),
          shape: RoundedCornerShape(14),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        child: isLoading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(width: 14),
                  Text(
                    label,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _GoogleLogoIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: const Text(
        'G',
        style: TextStyle(
          color: Color(0xFF4285F4),
          fontWeight: FontWeight.w900,
          fontSize: 14,
          height: 1,
        ),
      ),
    );
  }
}

class _MicrosoftLogoIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Column(
        children: [
          Row(
            children: [
              Container(width: 8, height: 8, color: const Color(0xFFF25022)),
              const SizedBox(width: 2),
              Container(width: 8, height: 8, color: const Color(0xFF7FBA00)),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Container(width: 8, height: 8, color: const Color(0xFF00A4EF)),
              const SizedBox(width: 2),
              Container(width: 8, height: 8, color: const Color(0xFFFFB900)),
            ],
          ),
        ],
      ),
    );
  }
}
