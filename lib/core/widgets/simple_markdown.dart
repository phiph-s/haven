import 'package:material_ui/material_ui.dart';

import '../theme/tokens.dart';

/// Block eines einfachen Markdown-Textes.
sealed class MdBlock {
  const MdBlock();
}

class MdHeading extends MdBlock {
  const MdHeading(this.level, this.text);
  final int level;
  final String text;
}

class MdParagraph extends MdBlock {
  const MdParagraph(this.text);
  final String text;
}

class MdBullet extends MdBlock {
  const MdBullet(this.text, {this.marker = '•', this.indent = 0});
  final String text;
  final String marker;
  final int indent;
}

class MdCode extends MdBlock {
  const MdCode(this.text);
  final String text;
}

/// Zerlegt Markdown in Blöcke: Überschriften, Listen, Absätze, Codeblöcke.
/// Bewusst klein: keine Tabellen, Bilder oder verschachtelte Zitate.
List<MdBlock> parseMarkdown(String src) {
  final out = <MdBlock>[];
  final lines = src.replaceAll('\r\n', '\n').split('\n');
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) {
      out.add(MdParagraph(para.join(' ')));
      para.clear();
    }
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final t = line.trim();
    if (t.startsWith('```')) {
      flush();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      out.add(MdCode(code.join('\n')));
      i++;
      continue;
    }
    if (t.isEmpty) {
      flush();
      i++;
      continue;
    }
    final h = RegExp(r'^(#{1,6})\s+(.*?)\s*#*$').firstMatch(t);
    if (h != null) {
      flush();
      out.add(MdHeading(h[1]!.length, h[2]!));
      i++;
      continue;
    }
    final b = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$').firstMatch(line);
    if (b != null) {
      flush();
      final numbered = RegExp(r'^\d').hasMatch(b[2]!);
      out.add(
        MdBullet(
          b[3]!,
          marker: numbered ? b[2]! : '•',
          indent: (b[1]!.length ~/ 2).clamp(0, 3),
        ),
      );
      i++;
      continue;
    }
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(t)) {
      flush();
      i++;
      continue;
    }
    para.add(t.startsWith('>') ? t.substring(1).trim() : t);
    i++;
  }
  flush();
  return out;
}

/// Inline-Teile: `**fett**`, `*kursiv*`, `` `Code` ``, `[Text](url)` (nur der
/// Text), nackte Links bleiben stehen.
List<InlineSpan> inlineSpans(
  String text,
  TextStyle base, {
  required Color codeBg,
  required Color linkColor,
}) {
  final spans = <InlineSpan>[];
  final re = RegExp(
    r'\*\*(.+?)\*\*|__(.+?)__|`([^`]+)`|\[([^\]]+)\]\([^)]*\)|(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])',
  );
  var pos = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
    if (m[1] != null || m[2] != null) {
      spans.add(
        TextSpan(
          text: m[1] ?? m[2],
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
    } else if (m[3] != null) {
      spans.add(
        TextSpan(
          text: m[3],
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 14) - 1,
            backgroundColor: codeBg,
          ),
        ),
      );
    } else if (m[4] != null) {
      spans.add(
        TextSpan(
          text: m[4],
          style: TextStyle(color: linkColor),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: m[5],
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    }
    pos = m.end;
  }
  if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
  return spans;
}

/// Rendert einfaches Markdown (z. B. GitHub-Release-Notes) ohne Paket.
class SimpleMarkdown extends StatelessWidget {
  const SimpleMarkdown(this.source, {super.key, this.maxBlocks});
  final String source;

  /// Begrenzt die Länge (Rest wird abgeschnitten).
  final int? maxBlocks;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    var blocks = parseMarkdown(source);
    final cut = maxBlocks != null && blocks.length > maxBlocks!;
    if (cut) blocks = blocks.sublist(0, maxBlocks!);
    final body = HavenText.body.copyWith(
      color: hv.tx2,
      fontSize: 14,
      height: 1.45,
    );
    Text rich(String t, TextStyle s) => Text.rich(
      TextSpan(
        style: s,
        children: inlineSpans(t, s, codeBg: hv.s2, linkColor: hv.acc),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks)
          Padding(
            padding: EdgeInsets.only(top: b is MdHeading ? 10 : 0, bottom: 6),
            child: switch (b) {
              MdHeading() => rich(
                b.text,
                HavenText.label.copyWith(
                  color: hv.tx,
                  fontSize: b.level <= 2 ? 16 : 14.5,
                ),
              ),
              MdParagraph() => rich(b.text, body),
              MdBullet() => Padding(
                padding: EdgeInsets.only(left: 4.0 + b.indent * 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 20, child: Text(b.marker, style: body)),
                    Expanded(child: rich(b.text, body)),
                  ],
                ),
              ),
              MdCode() => Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.s),
                ),
                child: Text(
                  b.text,
                  style: body.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                    color: hv.tx,
                  ),
                ),
              ),
            },
          ),
        if (cut) Text('…', style: body),
      ],
    );
  }
}
