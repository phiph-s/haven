import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_card.dart';
import 'search_index.dart';

/// Knopf oben rechts: öffnet die Suche.
class SearchButton extends StatelessWidget {
  const SearchButton({super.key});

  @override
  Widget build(BuildContext context) => RoundIconButton(
    icon: Icons.search_rounded,
    label: 'Suchen',
    onTap: () => showHavenSearch(context),
  );
}

bool _open = false;

/// Suchfenster über allem: weich eingeblendet, Hintergrund unscharf. Ein
/// Treffer schließt es und springt hin.
Future<void> showHavenSearch(BuildContext context) async {
  if (_open) return;
  _open = true;
  Haptics.tick();
  try {
    await showGeneralDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierLabel: 'Suche schließen',
      barrierColor: const Color(0x00000000),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (context, _, _) => const _SearchDialog(),
      transitionBuilder: (context, a, _, child) {
        final t = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
        return AnimatedBuilder(
          animation: t,
          builder: (context, _) => Stack(
            children: [
              // Hintergrund: unscharf und leicht abgedunkelt.
              Positioned.fill(
                child: IgnorePointer(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: 14 * t.value,
                      sigmaY: 14 * t.value,
                    ),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.28 * t.value),
                    ),
                  ),
                ),
              ),
              Opacity(
                opacity: t.value,
                child: Transform.translate(
                  offset: Offset(0, -16 * (1 - t.value)),
                  child: Transform.scale(
                    scale: 0.97 + 0.03 * t.value,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    _open = false;
  }
}

class _SearchDialog extends ConsumerStatefulWidget {
  const _SearchDialog();

  @override
  ConsumerState<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends ConsumerState<_SearchDialog> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  int _sel = 0;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<SearchItem> _results(List<SearchItem> index) {
    final q = _text.text.trim();
    if (q.isNotEmpty) return searchItems(index, q);
    // Ohne Eingabe: Räume und Kartenarten als Vorschläge.
    return [
      for (final i in index)
        if (i.kind == SearchKind.room) i,
      for (final i in index)
        if (i.kind == SearchKind.view && i.title.startsWith('Karte:')) i,
    ];
  }

  void _go(SearchItem item) {
    Haptics.tap();
    final router = GoRouter.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    Navigator.of(context).pop();
    item.open(router, container);
  }

  void _move(int by, int count) {
    if (count == 0) return;
    setState(() => _sel = (_sel + by).clamp(0, count - 1));
    // Auswahl sichtbar halten.
    const rowH = 60.0;
    final top = _sel * rowH;
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (top < p.pixels) {
      _scroll.jumpTo(top);
    } else if (top + rowH > p.pixels + p.viewportDimension) {
      _scroll.jumpTo(top + rowH - p.viewportDimension);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final index = ref.watch(searchIndexProvider);
    final results = _results(index);
    if (_sel >= results.length) _sel = results.isEmpty ? 0 : results.length - 1;
    final pad = MediaQuery.paddingOf(context);
    final maxH = MediaQuery.sizeOf(context).height * 0.7;
    final empty = _text.text.trim().isEmpty;

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, pad.top + 12, 12, 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 580, maxHeight: maxH),
          child: Material(
            color: hv.s1,
            elevation: 0,
            borderRadius: BorderRadius.circular(HavenRadii.l),
            clipBehavior: Clip.antiAlias,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: hv.ln),
                borderRadius: BorderRadius.circular(HavenRadii.l),
              ),
              child: Focus(
                onKeyEvent: (_, e) {
                  if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
                    return KeyEventResult.ignored;
                  }
                  final k = e.logicalKey;
                  if (k == LogicalKeyboardKey.arrowDown) {
                    _move(1, results.length);
                  } else if (k == LogicalKeyboardKey.arrowUp) {
                    _move(-1, results.length);
                  } else if (k == LogicalKeyboardKey.escape) {
                    Navigator.of(context).pop();
                  } else {
                    return KeyEventResult.ignored;
                  }
                  return KeyEventResult.handled;
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                      child: Row(
                        children: [
                          Icon(Icons.search_rounded, color: hv.tx2),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              key: const ValueKey('search-field'),
                              controller: _text,
                              focusNode: _focus,
                              autofocus: true,
                              textInputAction: TextInputAction.search,
                              style: HavenText.body.copyWith(
                                color: hv.tx,
                                fontSize: 17,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Geräte, Werte, Räume, Ansichten …',
                                hintStyle: HavenText.body.copyWith(
                                  color: hv.tx3,
                                  fontSize: 17,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                              onChanged: (_) => setState(() => _sel = 0),
                              onSubmitted: (_) {
                                if (results.isNotEmpty) _go(results[_sel]);
                              },
                            ),
                          ),
                          if (!empty)
                            IconButton(
                              tooltip: 'Leeren',
                              icon: Icon(Icons.close_rounded, color: hv.tx3),
                              onPressed: () {
                                _text.clear();
                                setState(() => _sel = 0);
                                _focus.requestFocus();
                              },
                            ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: hv.ln),
                    if (empty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
                        child: Text(
                          'Vorschläge',
                          style: HavenText.caption.copyWith(color: hv.tx3),
                        ),
                      ),
                    if (results.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Nichts gefunden',
                          textAlign: TextAlign.center,
                          style: HavenText.body.copyWith(color: hv.tx2),
                        ),
                      )
                    else
                      Flexible(
                        child: ListView.builder(
                          controller: _scroll,
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: results.length,
                          itemExtent: 60,
                          itemBuilder: (context, i) => _ResultRow(
                            item: results[i],
                            selected: i == _sel,
                            onTap: () => _go(results[i]),
                            onHover: () {
                              if (_sel != i) setState(() => _sel = i);
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final SearchItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final tint = item.color ?? hv.tx2;
    return Semantics(
      button: true,
      selected: selected,
      label: '${item.kind.label} ${item.title}',
      excludeSemantics: true,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: selected ? hv.s2 : Colors.transparent,
              borderRadius: BorderRadius.circular(HavenRadii.m),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (item.color ?? hv.s2).withValues(
                      alpha: item.color == null ? 1 : 0.25,
                    ),
                  ),
                  child: Icon(item.icon, size: 19, color: tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenText.label.copyWith(
                          color: hv.tx,
                          fontSize: 15,
                        ),
                      ),
                      if (item.subtitle != null && item.subtitle!.isNotEmpty)
                        Text(
                          item.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HavenText.caption.copyWith(color: hv.tx2),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  item.kind.label,
                  style: HavenText.caption.copyWith(
                    color: hv.tx3,
                    fontSize: 11.5,
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.keyboard_return_rounded, size: 16, color: hv.tx3),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
