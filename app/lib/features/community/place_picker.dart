import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/gathering_models.dart';
import '../../claim/geo.dart';
import '../../core/theme.dart';
import '../../map/territory_map.dart';
import '../../run/location_source.dart';
import '../../run/run_controller.dart' show locationSourceProvider;
import '../../widgets/common.dart';
import '../../widgets/l_icons.dart';

/// Current position (GCJ-02) without prompting toasts; null when there is
/// no permission or no fix.
Future<LatLng?> quietLocation(WidgetRef ref) async {
  try {
    final src = ref.read(locationSourceProvider);
    if (await src.ensurePermission() != LocationPermissionResult.granted) return null;
    final f = await src.current().timeout(const Duration(seconds: 8));
    return f == null ? null : LatLng(f.lat, f.lng);
  } catch (_) {
    return null;
  }
}

/// Opens the map picker; returns the chosen place or null.
Future<Place?> pickPlace(BuildContext context, {Place? initial, String title = '选择地点'}) =>
    Navigator.of(context).push<Place>(MaterialPageRoute(builder: (_) => PlacePickerPage(initial: initial, title: title)));

/// Drag the map so the pin sits on the meeting point, name it, confirm.
/// Uses the app's territory map (AMap when configured, else the fallback).
class PlacePickerPage extends ConsumerStatefulWidget {
  const PlacePickerPage({super.key, this.initial, this.title = '选择地点'});
  final Place? initial;
  final String title;
  @override
  ConsumerState<PlacePickerPage> createState() => _PlacePickerPageState();
}

class _PlacePickerPageState extends ConsumerState<PlacePickerPage> {
  final _map = TerritoryMapController();
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late LatLng _center = widget.initial?.latLng ?? const LatLng(31.2304, 121.4737);
  LatLng? _me;

  @override
  void initState() {
    super.initState();
    if (widget.initial == null) _locate(move: true);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _locate({bool move = false}) async {
    final p = await quietLocation(ref);
    if (!mounted) return;
    if (p == null) {
      if (!move) toast(context, '暂时拿不到定位，可以直接拖动地图选择', kind: ToastKind.warning);
      return;
    }
    setState(() => _me = p);
    _map.moveTo(p, zoom: 16);
    setState(() => _center = p);
  }

  void _confirm() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      toast(context, '给集合点起个名字，比如「世纪公园 3 号门」');
      return;
    }
    Navigator.of(context).pop(Place(name: name, lat: _center.lat, lng: _center.lng));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          BackHeader(title: widget.title, subtitle: '拖动地图，让图钉对准集合点'),
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: TerritoryMapView(
                  controller: _map,
                  initialCenter: _center,
                  initialZoom: 16,
                  layers: MapLayers(myLocation: _me),
                  onBoundsChanged: (b) =>
                      setState(() => _center = LatLng((b.minLat + b.maxLat) / 2, (b.minLng + b.maxLng) / 2)),
                ),
              ),
              const IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 44),
                    child: LIcon(LIcons.pinFilled, color: LL.lime, size: 48, shadows: [Shadow(blurRadius: 8)]),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: RoundIconButton(icon: LIcons.locate, tooltip: '我的位置', onTap: () => _locate()),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${_center.lat.toStringAsFixed(5)}, ${_center.lng.toStringAsFixed(5)}',
                  style: const TextStyle(color: LL.text3, fontSize: 12)),
              const SizedBox(height: 8),
              TextField(
                key: const Key('place_name'),
                controller: _name,
                inputFormatters: [LengthLimitingTextInputFormatter(30)],
                decoration: const InputDecoration(hintText: '地点名称，如 世纪公园 3 号门', prefixIcon: LIcon(LIcons.pin)),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _confirm, child: const Text('确定')),
            ]),
          ),
        ]),
      ),
    );
  }
}
