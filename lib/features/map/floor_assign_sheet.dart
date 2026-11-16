import 'package:material_ui/material_ui.dart';

import '../../core/widgets/haven_sheet.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/haptics.dart';
import '../../core/widgets/haven_button.dart';
import '../../core/widgets/press_scale.dart';
import '../../data/models/floor_plan.dart';
import '../../data/models/room.dart';

/// Ergebnis der Zuordnung: Name und optional der HA-Bereich.
class RoomAssignment {
  const RoomAssignment(this.name, this.areaId);
  final String name;
  final String? areaId;
}

/// Bottom Sheet: Raum einem HA-Bereich zuordnen oder frei
/// benennen. Bereiche, die schon ein anderer Plan-Raum nutzt, sind gesperrt.
Future<RoomAssignment?> showRoomAssignSheet(
  BuildContext context, {
  required FloorRoom room,
  required List<Room> areas,
  required Set<String> usedAreaIds,
}) {
  return showHavenModalSheet<RoomAssignment>(
    context,
    builder: (_) =>
        _AssignSheet(room: room, areas: areas, usedAreaIds: usedAreaIds),
  );
}

class _AssignSheet extends StatefulWidget {
  const _AssignSheet({
    required this.room,
    required this.areas,
    required this.usedAreaIds,
  });
  final FloorRoom room;
  final List<Room> areas;
  final Set<String> usedAreaIds;

  @override
  State<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends State<_AssignSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.room.name == 'Neuer Raum' ? '' : widget.room.name,
  );

  static const _extra = ['Flur', 'Toilette', 'Arbeitszimmer', 'Balkon'];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done(RoomAssignment a) {
    Haptics.tick();
    Navigator.of(context).pop(a);
  }

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final taken = {for (final a in widget.areas) a.name.toLowerCase()};
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: hv.s1,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(HavenRadii.xl),
            ),
            side: BorderSide(color: hv.ln2),
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              // Am oberen Ende übernimmt das Sheet das Ziehen.
              controller: HavenSheetScope.maybeOf(context)?.scrollController,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: hv.ln2,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Raum zuordnen',
                    style: HavenText.section.copyWith(color: hv.tx),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Wähle einen Bereich aus Home Assistant oder tippe '
                    'einen Namen.',
                    style: HavenText.body.copyWith(color: hv.tx2),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in widget.areas)
                        _Choice(
                          label: a.name,
                          selected:
                              widget.room.areaId != null &&
                              (a.areaId ?? a.id) == widget.room.areaId,
                          disabled:
                              widget.usedAreaIds.contains(a.areaId ?? a.id) &&
                              (a.areaId ?? a.id) != widget.room.areaId,
                          onTap: () =>
                              _done(RoomAssignment(a.name, a.areaId ?? a.id)),
                        ),
                      for (final n in _extra)
                        if (!taken.contains(n.toLowerCase()))
                          _Choice(
                            label: n,
                            onTap: () => setState(() => _name.text = n),
                          ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.sentences,
                    style: HavenText.body.copyWith(color: hv.tx),
                    cursorColor: hv.acc,
                    decoration: InputDecoration(
                      hintText: 'Name',
                      hintStyle: HavenText.body.copyWith(color: hv.tx3),
                      filled: true,
                      fillColor: hv.s2,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 16,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(HavenRadii.m),
                        borderSide: BorderSide(color: hv.ln2),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(HavenRadii.m),
                        borderSide: BorderSide(color: hv.ln2),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(HavenRadii.m),
                        borderSide: BorderSide(color: hv.acc, width: 2),
                      ),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 14),
                  HavenButton(label: 'Fertig', primary: true, onTap: _submit),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    final t = _name.text.trim();
    if (t.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    // Passt der Name zu einem freien Bereich, ordnen wir ihn zu.
    String? area;
    for (final a in widget.areas) {
      final id = a.areaId ?? a.id;
      if (a.name.toLowerCase() == t.toLowerCase() &&
          !widget.usedAreaIds.contains(id)) {
        area = id;
      }
    }
    _done(RoomAssignment(t, area));
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.disabled = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final hv = context.hv;
    return Semantics(
      button: true,
      enabled: !disabled,
      selected: selected,
      label: label,
      child: PressScale(
        onTap: disabled ? null : onTap,
        child: SizedBox(
          height: HavenSpace.touch,
          child: Center(
            child: Opacity(
              opacity: disabled ? 0.4 : 1,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? hv.acc : hv.s2,
                  borderRadius: BorderRadius.circular(HavenRadii.pill),
                  border: selected ? null : Border.all(color: hv.ln2),
                ),
                child: Text(
                  label,
                  style: HavenText.label.copyWith(
                    color: selected ? hv.ai : hv.tx,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
