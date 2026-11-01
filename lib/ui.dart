import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Общий стиль приложений Winter Hub: тёмно-синий фон, ледяные акценты.
class W {
  static Color accent = const Color(0xFF7FD8FF);
  static const bg = Color(0xFF0A1020);
  static const surface = Color(0xFF111A2E);
  static const surface2 = Color(0xFF17223A);
  static const border = Color(0xFF24324F);
  static const text = Color(0xFFEAF2FF);
  static const muted = Color(0xFF8A9BB8);
  static const ice = Color(0xFF7FD8FF);
  static const good = Color(0xFF5EE6A8);
  static const warn = Color(0xFFFFC46B);
  static const bad = Color(0xFFFF6B8A);

  static const h1 = TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: text, letterSpacing: -0.4);
  static const h2 = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: text);
  static const body = TextStyle(fontSize: 14.5, color: text, height: 1.4);
  static const small = TextStyle(fontSize: 12.5, color: muted, height: 1.35);
}

ThemeData winterTheme(Color accent) {
  W.accent = accent;
  return ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: W.bg,
    colorScheme: ColorScheme.dark(primary: accent, secondary: W.ice, surface: W.surface),
    appBarTheme: const AppBarTheme(backgroundColor: W.bg, surfaceTintColor: Colors.transparent, foregroundColor: W.text, titleTextStyle: W.h2),
    snackBarTheme: const SnackBarThemeData(backgroundColor: W.surface2, contentTextStyle: TextStyle(color: W.text)),
    dialogTheme: const DialogThemeData(backgroundColor: W.surface),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: W.surface),
    sliderTheme: SliderThemeData(activeTrackColor: accent, thumbColor: accent, inactiveTrackColor: W.border),
    switchTheme: SwitchThemeData(trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : W.border)),
  );
}

/// Карточка.
class WCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color, borderColor;
  const WCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap, this.color, this.borderColor});

  @override
  Widget build(BuildContext context) => Material(
        color: color ?? W.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: padding,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: borderColor ?? W.border)),
            child: child,
          ),
        ),
      );
}

class Section extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const Section(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 18, 2, 8),
        child: Row(children: [Expanded(child: Text(text, style: W.h2)), if (trailing != null) trailing!]),
      );
}

class Chip2 extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback? onTap;
  const Chip2(this.text, {super.key, this.selected = false, this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? W.accent : W.surface2,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? W.accent : W.border),
          ),
          child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? W.bg : W.text)),
        ),
      );
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
}

Future<bool> confirmDialog(BuildContext context, String title, String text, {String ok = 'Да'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: W.h2),
        content: Text(text, style: W.body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    ) ==
    true;

/// Папка данных приложения (на ПК — AppData, на телефоне — память приложения).
Future<Directory> dataDir() async {
  final d = await getApplicationSupportDirectory();
  await d.create(recursive: true);
  return d;
}

/// Простое хранилище JSON в файле.
class JsonStore {
  final String name;
  JsonStore(this.name);

  Future<File> _file() async => File('${(await dataDir()).path}${Platform.pathSeparator}$name');

  Future<Map<String, dynamic>> read() async {
    try {
      final f = await _file();
      if (await f.exists()) return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    return {};
  }

  Future<void> write(Map<String, dynamic> j) async {
    try {
      final f = await _file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(j), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }
}
