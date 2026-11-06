import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'geo.dart';
import 'news.dart';
import 'places.dart';
import 'ui.dart';
import 'package:winter_core/winter_core.dart';

Future<void> main() => runWinterApp(repo: 'winter-walks', appName: 'Winter Walks', body: _main);

void _main() {
  WidgetsFlutterBinding.ensureInitialized();
  final crash = FlutterError.onError;
  FlutterError.onError = (d) {
    crash?.call(d); // запись в отчёт о падениях (winter_core)
    log('flutter: ${d.exceptionAsString()}');
  };
  runApp(WinterCrashBanner(child: const WalksApp()));
}

/// Журнал ошибок в папке приложения (log.txt) — помогает разобраться, если что-то не работает.
Future<void> log(String s) async {
  try {
    final f = File('${(await dataDir()).path}${Platform.pathSeparator}log.txt');
    if (await f.exists() && await f.length() > 200000) await f.delete();
    await f.writeAsString('${DateTime.now().toIso8601String()} $s\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

const _sky = Color(0xFF6EC8FF);
const radii = [1, 2, 3, 5, 10, 20, 50];

/// Состояние приложения: точка, радиус, места, новости, избранное.
class AppState extends ChangeNotifier {
  final _store = JsonStore('walks.json');
  Spot? spot;
  int radiusKm = 3;
  String lang = 'ru';
  List<Place> places = [];
  bool loadingPlaces = false;
  String? placesError;
  final Map<String, Place> favs = {};
  Set<String> visited = {};
  String newsScope = 'city'; // district | city | region
  List<NewsItem> news = [];
  bool loadingNews = false;
  String? newsError;
  String? note;

  Future<void> load() async {
    try {
      await _load();
    } catch (e, st) {
      log('load: $e\n$st');
      note = 'Ошибка запуска: $e';
      loadingPlaces = false;
      notifyListeners();
    }
  }

  Future<void> _load() async {
    log('start, data: ${(await dataDir()).path}');
    final j = await _store.read();
    log('saved keys: ${j.keys.toList()}');
    spot = Spot.fromJson(j['spot'] as Map?);
    radiusKm = (j['radius'] as num?)?.toInt() ?? 3;
    lang = '${j['lang'] ?? 'ru'}';
    newsScope = '${j['scope'] ?? 'city'}';
    for (final f in (j['favs'] as List? ?? const []).whereType<Map>()) {
      final p = Place.fromJson(f);
      favs[p.id] = p;
    }
    visited = {...((j['visited'] as List?) ?? const []).map((e) => '$e')};
    notifyListeners();
    if (spot == null) {
      await useMyLocation();
    } else {
      refresh();
    }
  }

  Future<void> save() => _store.write({
        'spot': spot?.toJson(),
        'radius': radiusKm,
        'lang': lang,
        'scope': newsScope,
        'favs': [for (final p in favs.values) p.toJson()],
        'visited': visited.toList(),
      });

  Future<void> useMyLocation() async {
    loadingPlaces = true;
    note = null;
    notifyListeners();
    final (pos, msg) = await locateMe();
    log('locate: $pos $msg');
    note = msg;
    if (pos == null) {
      loadingPlaces = false;
      notifyListeners();
      return;
    }
    await setSpot(pos);
  }

  Future<void> setSpot(LatLng p) async {
    spot = Spot(p, 'Определяю место…');
    notifyListeners();
    spot = await reverse(p, lang: lang);
    await save();
    refresh();
  }

  void setRadius(int km) {
    radiusKm = km;
    save();
    loadPlaces();
  }

  void setScope(String s) {
    newsScope = s;
    save();
    loadNews();
  }

  void refresh() {
    loadPlaces();
    loadNews();
  }

  final _cache = JsonStore('cache.json');
  int _gen = 0;

  String _cacheKey(Spot s) => '${s.pos.latitude.toStringAsFixed(3)},${s.pos.longitude.toStringAsFixed(3)},$radiusKm';

  Future<void> loadPlaces() async {
    final s = spot;
    if (s == null) return;
    final gen = ++_gen;
    loadingPlaces = true;
    placesError = null;
    // Сначала показываем то, что уже находили здесь раньше, — мгновенно и без интернета.
    final cache = await _cache.read();
    final key = _cacheKey(s);
    final cached = cache[key];
    if (cached is List && gen == _gen) {
      places = [for (final j in cached.whereType<Map>()) Place.fromJson(j)];
      for (final p in places) {
        p.dist = distanceM(s.pos, p.pos);
      }
    } else if (gen == _gen) {
      places = [];
    }
    notifyListeners();
    try {
      final fresh = await fetchAll(s.pos, radiusKm * 1000.0, lang: lang, onPartial: (part) {
        if (gen != _gen || part.length <= places.length) return;
        places = part;
        notifyListeners();
      });
      if (gen != _gen) return;
      if (fresh.length >= places.length || cached is! List) places = fresh;
      log('places: ${fresh.length}');
      final keep = Map<String, dynamic>.from(cache)..remove(key);
      while (keep.length >= 6) {
        keep.remove(keep.keys.first);
      }
      keep[key] = [for (final p in places) p.toJson()];
      await _cache.write(keep);
    } catch (e) {
      if (gen != _gen) return;
      log('places error: $e');
      if (places.isEmpty) placesError = '$e'.replaceFirst('Exception: ', '');
    }
    if (gen != _gen) return;
    loadingPlaces = false;
    notifyListeners();
  }

  String get newsPlace {
    final s = spot;
    if (s == null) return '';
    return switch (newsScope) {
      'district' => s.district.isNotEmpty ? s.district : s.city,
      'region' => s.region.isNotEmpty ? s.region : s.city,
      _ => s.city.isNotEmpty ? s.city : (s.district.isNotEmpty ? s.district : s.region),
    };
  }

  Future<void> loadNews() async {
    final s = spot;
    final place = newsPlace;
    if (s == null || place.isEmpty) return;
    loadingNews = true;
    newsError = null;
    notifyListeners();
    try {
      // Для района добавляем город, чтобы не путать с одноимёнными районами других городов.
      final extra = newsScope == 'district' && s.city.isNotEmpty && place != s.city ? s.city : '';
      news = await fetchNews(place, lang: lang, cc: s.countryCode, extra: extra);
      if (news.isEmpty && extra.isEmpty) news = await fetchNews(place, lang: lang, cc: s.countryCode); // повтор: Google иногда отвечает пусто
      if (news.isEmpty && extra.isNotEmpty) news = await fetchNews(place, lang: lang, cc: s.countryCode);
      log('news "$place": ${news.length}');
    } catch (e) {
      log('news error: $e');
      newsError = 'Не удалось загрузить новости. Проверь интернет.';
    }
    loadingNews = false;
    notifyListeners();
  }

  void toggleFav(Place p) {
    favs.containsKey(p.id) ? favs.remove(p.id) : favs[p.id] = p;
    save();
    notifyListeners();
  }

  void toggleVisited(Place p) {
    visited.contains(p.id) ? visited.remove(p.id) : visited.add(p.id);
    save();
    notifyListeners();
  }
}

final app = AppState();

class WalksApp extends StatelessWidget {
  const WalksApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Winter Walks',
        debugShowCheckedModeBanner: false,
        theme: winterTheme(_sky),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    app.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => Column(children: [
            // Не const: шапка и вкладки должны перерисовываться, когда меняются данные.
            // ignore: prefer_const_constructors
            _Header(),
            Expanded(child: IndexedStack(index: tab, children: [
              // ignore: prefer_const_constructors
              PlacesTab(),
              // ignore: prefer_const_constructors
              NewsTab(),
              // ignore: prefer_const_constructors
              FavsTab(),
            ])),
          ]),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: W.surface,
        indicatorColor: _sky.withValues(alpha: 0.25),
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.explore_outlined), label: 'Куда пойти'),
          NavigationDestination(icon: Icon(Icons.newspaper_outlined), label: 'Новости'),
          NavigationDestination(icon: Icon(Icons.bookmark_border), label: 'Избранное'),
        ],
      ),
    );
  }
}

/// Шапка: где я и какой радиус.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final s = app.spot;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        WCard(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LocationScreen())),
          child: Row(children: [
            const Icon(Icons.place, color: _sky),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s?.label ?? 'Место не выбрано', maxLines: 1, overflow: TextOverflow.ellipsis, style: W.body.copyWith(fontWeight: FontWeight.w700)),
                Text(s == null ? 'Нажми, чтобы выбрать' : 'Нажми, чтобы изменить место', style: W.small),
              ]),
            ),
            IconButton(tooltip: 'Где я сейчас', icon: const Icon(Icons.my_location, color: _sky), onPressed: app.useMyLocation),
          ]),
        ),
        if (app.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(app.note!, style: W.small.copyWith(color: W.warn))),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            const Center(child: Text('Радиус:  ', style: W.small)),
            for (final r in radii)
              Padding(padding: const EdgeInsets.only(right: 6), child: Chip2('$r км', selected: app.radiusKm == r, onTap: () => app.setRadius(r))),
          ]),
        ),
      ]),
    );
  }
}

// ---------------- Куда пойти ----------------

class PlacesTab extends StatefulWidget {
  const PlacesTab({super.key});

  @override
  State<PlacesTab> createState() => _PlacesTabState();
}

class _PlacesTabState extends State<PlacesTab> {
  String filter = 'all'; // all | walk | photo | <cat>
  bool showMap = false;
  final mapCtrl = MapController();

  List<Place> get shown => app.places.where((p) {
        if (filter == 'all') return true;
        if (filter == 'walk') return p.kind == Kind.walk;
        if (filter == 'photo') return p.kind == Kind.photo;
        return p.cat == filter;
      }).toList();

  void _surprise() {
    final walks = app.places.where((p) => p.kind == Kind.walk && !app.visited.contains(p.id)).toList();
    final pool = walks.isEmpty ? app.places : walks;
    if (pool.isEmpty) {
      toast(context, 'Рядом ничего не нашлось — увеличь радиус');
      return;
    }
    final target = pool[math.Random().nextInt(pool.length)];
    final photos = app.places.where((p) => p.kind == Kind.photo && p.id != target.id && distanceM(p.pos, target.pos) < 1500).take(4).toList();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => WalkPlanScreen(target: target, photos: photos)));
  }

  @override
  Widget build(BuildContext context) {
    final list = shown;
    final counts = {for (final c in categories) c.id: app.places.where((p) => p.cat == c.id).length};
    return Column(children: [
      SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final f in [('all', 'Всё'), ('walk', '🚶 Погулять'), ('photo', '📷 Красивые фото')])
            Padding(padding: const EdgeInsets.only(right: 6), child: Chip2(f.$2, selected: filter == f.$1, onTap: () => setState(() => filter = f.$1))),
          for (final c in categories)
            if ((counts[c.id] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Chip2('${c.emoji} ${c.title} ${counts[c.id]}', selected: filter == c.id, onTap: () => setState(() => filter = c.id)),
              ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(children: [
          Text(app.loadingPlaces ? 'Ищу места…' : 'Найдено: ${list.length}', style: W.small),
          const Spacer(),
          TextButton.icon(onPressed: app.places.isEmpty ? null : _surprise, icon: const Icon(Icons.casino_outlined, size: 18), label: const Text('Куда сходить?')),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [ButtonSegment(value: false, icon: Icon(Icons.list, size: 18)), ButtonSegment(value: true, icon: Icon(Icons.map_outlined, size: 18))],
            selected: {showMap},
            onSelectionChanged: (s) => setState(() => showMap = s.first),
          ),
        ]),
      ),
      if (app.loadingPlaces) const LinearProgressIndicator(color: _sky),
      if (app.placesError != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Text(app.placesError!, style: W.body, textAlign: TextAlign.center),
            TextButton(onPressed: app.loadPlaces, child: const Text('Повторить')),
          ]),
        ),
      if (app.spot == null && !app.loadingPlaces)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            const Text('Выбери, где ты: по геолокации, поиском или точкой на карте.', style: W.body, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LocationScreen())), child: const Text('Выбрать место')),
          ]),
        ),
      Expanded(
        child: showMap
            ? PlacesMap(places: list, controller: mapCtrl)
            : RefreshIndicator(
                onRefresh: app.loadPlaces,
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: list.length + 1,
                  itemBuilder: (_, i) => i < list.length
                      ? PlaceCard(list[i])
                      : Padding(
                          padding: const EdgeInsets.all(12),
                          child: Center(
                            child: TextButton.icon(
                              onPressed: app.loadingPlaces ? null : app.loadPlaces,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: Text(app.loadingPlaces ? 'Ищу ещё места…' : 'Обновить список'),
                            ),
                          ),
                        ),
                ),
              ),
      ),
    ]);
  }
}

Future<void> openRoute(Place p) async {
  final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${p.pos.latitude},${p.pos.longitude}&travelmode=walking');
  await launchUrl(url, mode: LaunchMode.externalApplication);
}

class PlaceCard extends StatelessWidget {
  final Place p;
  const PlaceCard(this.p, {super.key});

  @override
  Widget build(BuildContext context) {
    final fav = app.favs.containsKey(p.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: WCard(
        padding: EdgeInsets.zero,
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceScreen(p))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (p.image != null)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
              child: SizedBox(
                height: 170,
                child: Image.network(p.image!, fit: BoxFit.cover, headers: const {'User-Agent': userAgent}, errorBuilder: (_, __, ___) => const ColoredBox(color: W.surface2)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(children: [
              if (p.image == null) Padding(padding: const EdgeInsets.only(right: 10), child: Text(p.category.emoji, style: const TextStyle(fontSize: 26))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: W.body.copyWith(fontWeight: FontWeight.w700)),
                  Text('${p.category.emoji} ${p.category.title} · ${fmtDist(p.dist)} · ${walkTime(p.dist)}', style: W.small),
                  if (p.about != null && p.about!.isNotEmpty) Text(p.about!, maxLines: 2, overflow: TextOverflow.ellipsis, style: W.small.copyWith(color: W.text)),
                ]),
              ),
              if (app.visited.contains(p.id)) const Icon(Icons.check_circle, color: W.good, size: 18),
              IconButton(icon: Icon(fav ? Icons.bookmark : Icons.bookmark_border, color: fav ? _sky : W.muted), onPressed: () => app.toggleFav(p)),
              IconButton(tooltip: 'Маршрут', icon: const Icon(Icons.directions_walk, color: _sky), onPressed: () => openRoute(p)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class PlacesMap extends StatelessWidget {
  final List<Place> places;
  final MapController controller;
  final Place? focus;
  const PlacesMap({super.key, required this.places, required this.controller, this.focus});

  @override
  Widget build(BuildContext context) {
    final s = app.spot;
    if (s == null) return const SizedBox();
    final zoom = switch (app.radiusKm) { <= 1 => 15.0, <= 2 => 14.0, <= 3 => 13.5, <= 5 => 13.0, <= 10 => 12.0, <= 20 => 11.0, _ => 9.5 };
    return FlutterMap(
      mapController: controller,
      options: MapOptions(initialCenter: focus?.pos ?? s.pos, initialZoom: focus != null ? 15 : zoom),
      children: [
        darkTiles(),
        CircleLayer(circles: [
          CircleMarker(point: s.pos, radius: app.radiusKm * 1000.0, useRadiusInMeter: true, color: _sky.withValues(alpha: 0.06), borderColor: _sky.withValues(alpha: 0.5), borderStrokeWidth: 1.5),
        ]),
        MarkerLayer(markers: [
          for (final p in places)
            Marker(
              point: p.pos,
              width: 38,
              height: 38,
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceScreen(p))),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (p.kind == Kind.walk ? W.good : _sky).withValues(alpha: 0.9),
                    border: Border.all(color: focus?.id == p.id ? Colors.white : W.bg, width: focus?.id == p.id ? 3 : 2),
                  ),
                  child: Text(p.category.emoji, style: const TextStyle(fontSize: 18)),
                ),
              ),
            ),
          Marker(
            point: s.pos,
            width: 22,
            height: 22,
            child: Container(decoration: BoxDecoration(shape: BoxShape.circle, color: W.bad, border: Border.all(color: Colors.white, width: 3))),
          ),
        ]),
        const MapAttribution(),
      ],
    );
  }
}

TileLayer darkTiles() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.winterhub.winter_walks',
      maxZoom: 19,
    );

class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomRight,
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: Colors.white70,
          child: GestureDetector(
            onTap: () => launchUrl(Uri.parse('https://www.openstreetmap.org/copyright'), mode: LaunchMode.externalApplication),
            child: const Text('© OpenStreetMap', style: TextStyle(fontSize: 10, color: Colors.black87)),
          ),
        ),
      );
}

class PlaceScreen extends StatelessWidget {
  final Place p;
  const PlaceScreen(this.p, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final fav = app.favs.containsKey(p.id);
          final nearbyPhotos = app.places.where((x) => x.id != p.id && x.kind == Kind.photo && distanceM(x.pos, p.pos) < 1200).take(6).toList();
          final tags = p.tags;
          final info = <(IconData, String)>[
            if (tags['opening_hours'] != null) (Icons.schedule, 'Часы работы: ${tags['opening_hours']}'),
            if (tags['fee'] == 'yes') (Icons.payments_outlined, 'Платный вход'),
            if (tags['fee'] == 'no') (Icons.money_off, 'Вход бесплатный'),
            if (tags['wheelchair'] == 'yes') (Icons.accessible, 'Доступно на коляске'),
            if (tags['ele'] != null) (Icons.terrain, 'Высота: ${tags['ele']} м'),
            if (tags['website'] != null) (Icons.language, tags['website']!),
          ];
          return Scaffold(
            appBar: AppBar(title: Text(p.name, maxLines: 1), actions: [
              IconButton(icon: Icon(fav ? Icons.bookmark : Icons.bookmark_border, color: fav ? _sky : null), onPressed: () => app.toggleFav(p)),
            ]),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
                  if (p.image != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: Image.network(p.image!, fit: BoxFit.cover, width: double.infinity, headers: const {'User-Agent': userAgent}, errorBuilder: (_, __, ___) => const SizedBox()),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(p.name, style: W.h1),
                  Text('${p.category.emoji} ${p.category.title} · ${fmtDist(p.dist)} от тебя · ${walkTime(p.dist)}', style: W.small),
                  if (p.about != null && p.about!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(p.about!, style: W.body)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(onPressed: () => openRoute(p), icon: const Icon(Icons.directions_walk), label: const Text('Маршрут')),
                    OutlinedButton.icon(
                      onPressed: () => app.toggleVisited(p),
                      icon: Icon(app.visited.contains(p.id) ? Icons.check_circle : Icons.check_circle_outline, color: app.visited.contains(p.id) ? W.good : null),
                      label: Text(app.visited.contains(p.id) ? 'Был здесь' : 'Отметить «был»'),
                    ),
                    if (p.wiki != null)
                      OutlinedButton.icon(onPressed: () => launchUrl(Uri.parse(p.wiki!), mode: LaunchMode.externalApplication), icon: const Icon(Icons.menu_book_outlined), label: const Text('Википедия')),
                  ]),
                  if (info.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    for (final i in info)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(children: [Icon(i.$1, size: 18, color: W.muted), const SizedBox(width: 8), Expanded(child: Text(i.$2, style: W.small.copyWith(color: W.text)))]),
                      ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 220,
                    child: ClipRRect(borderRadius: BorderRadius.circular(14), child: PlacesMap(places: [p, ...nearbyPhotos], controller: MapController(), focus: p)),
                  ),
                  if (p.kind == Kind.photo) ...[
                    const Section('Советы для фото'),
                    WCard(child: Text(photoTip(p), style: W.body)),
                  ],
                  if (nearbyPhotos.isNotEmpty) ...[
                    const Section('Рядом можно сфотографировать'),
                    for (final x in nearbyPhotos) PlaceCard(x),
                  ],
                ]),
              ),
            ),
          );
        },
      );
}

String photoTip(Place p) {
  final base = switch (p.cat) {
    'viewpoint' => 'Лучший свет — «золотой час»: час после рассвета и час до заката. Возьми в кадр линию горизонта по правилу третей.',
    'waterfall' => 'Для «шёлковой» воды нужна длинная выдержка: поставь телефон на камень и включи ночной режим или режим «длинная экспозиция».',
    'historic' => 'Сними здание с низкой точки, чтобы подчеркнуть высоту. Вечером включается подсветка — попробуй синий час сразу после заката.',
    'art' => 'Подойди ближе и найди необычный ракурс: деталь, отражение, силуэт на фоне неба.',
    'peak' => 'Добавь в кадр человека для масштаба. Рассвет на вершине — самые красивые снимки.',
    _ => 'Снимай в мягком свете утром или вечером, ищи отражения в воде и ведущие линии (дорожки, ограды).',
  };
  return base;
}

class WalkPlanScreen extends StatelessWidget {
  final Place target;
  final List<Place> photos;
  const WalkPlanScreen({super.key, required this.target, required this.photos});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Идея для прогулки')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
          Text('Сходи сюда:', style: W.small),
          PlaceCard(target),
          if (photos.isNotEmpty) ...[
            const Section('А по пути сфотографируй'),
            for (final p in photos) PlaceCard(p),
          ],
          const SizedBox(height: 8),
          Text('Прогулка займёт примерно ${walkTime(target.dist * 2)} туда и обратно.', style: W.small),
        ]),
      );
}

// ---------------- Выбор места ----------------

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final q = TextEditingController();
  List<(String, LatLng)> results = [];
  bool searching = false;
  LatLng? picked;
  final map = MapController();
  Timer? _debounce;

  Future<void> _search() async {
    if (q.text.trim().length < 2) return;
    setState(() => searching = true);
    try {
      results = await searchPlace(q.text.trim(), lang: app.lang);
    } catch (_) {
      results = [];
      if (mounted) toast(context, 'Поиск не отвечает. Проверь интернет.');
    }
    if (mounted) setState(() => searching = false);
  }

  void _choose(LatLng p) {
    app.setSpot(p);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final start = picked ?? app.spot?.pos ?? const LatLng(50.45, 30.52);
    return Scaffold(
      appBar: AppBar(title: const Text('Где ты?')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: q,
            style: W.body,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 900), _search);
            },
            decoration: InputDecoration(
              hintText: 'Город, улица или место',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searching ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
              filled: true,
              fillColor: W.surface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        if (results.isNotEmpty)
          SizedBox(
            height: math.min(240, results.length * 56.0),
            child: ListView(children: [
              for (final r in results)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.place_outlined),
                  title: Text(r.$1, maxLines: 2, overflow: TextOverflow.ellipsis, style: W.small.copyWith(color: W.text)),
                  onTap: () => _choose(r.$2),
                ),
            ]),
          ),
        ListTile(
          leading: const Icon(Icons.my_location, color: _sky),
          title: const Text('Моё местоположение'),
          subtitle: const Text('GPS на телефоне; на ПК — примерно по интернету', style: W.small),
          onTap: () {
            app.useMyLocation();
            Navigator.pop(context);
          },
        ),
        const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Или нажми на карту, чтобы выбрать точку:', style: W.small)),
        const SizedBox(height: 6),
        Expanded(
          child: Stack(children: [
            FlutterMap(
              mapController: map,
              options: MapOptions(initialCenter: start, initialZoom: 12, onTap: (_, p) => setState(() => picked = p)),
              children: [
                darkTiles(),
                if (picked != null)
                  MarkerLayer(markers: [
                    Marker(point: picked!, width: 40, height: 40, alignment: Alignment.topCenter, child: const Icon(Icons.location_on, color: W.bad, size: 40)),
                  ]),
                const MapAttribution(),
              ],
            ),
            if (picked != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: FilledButton.icon(onPressed: () => _choose(picked!), icon: const Icon(Icons.check), label: const Text('Выбрать эту точку')),
              ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------- Новости ----------------

class NewsTab extends StatelessWidget {
  const NewsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final s = app.spot;
    final scopes = [
      if (s != null && s.district.isNotEmpty && s.district != s.city) ('district', s.district),
      if (s != null && s.city.isNotEmpty) ('city', s.city),
      if (s != null && s.region.isNotEmpty) ('region', s.region),
    ];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(children: [
          Expanded(child: Text(s == null ? 'Сначала выбери место' : 'Новости за неделю: ${app.newsPlace}', style: W.h2, maxLines: 2)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: app.loadNews),
        ]),
      ),
      if (scopes.length > 1)
        SizedBox(
          height: 38,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final sc in scopes)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Chip2('${sc.$1 == 'district' ? 'Район' : sc.$1 == 'city' ? 'Город' : 'Область'}: ${sc.$2}', selected: app.newsScope == sc.$1, onTap: () => app.setScope(sc.$1)),
              ),
          ]),
        ),
      if (app.loadingNews) const LinearProgressIndicator(color: _sky),
      if (app.newsError != null) Padding(padding: const EdgeInsets.all(16), child: Text(app.newsError!, style: W.body)),
      if (!app.loadingNews && app.newsError == null && app.news.isEmpty && s != null)
        const Padding(padding: EdgeInsets.all(24), child: Text('За неделю новостей не нашлось. Попробуй «Город» или «Область».', textAlign: TextAlign.center, style: W.body)),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
          itemCount: app.news.length,
          itemBuilder: (_, i) {
            final n = app.news[i];
            final newDay = i == 0 || !_sameDay(app.news[i - 1].date, n.date);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (newDay) Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 6), child: Text(_dayTitle(n.date), style: W.small.copyWith(color: _sky, fontWeight: FontWeight.w700))),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: WCard(
                  padding: const EdgeInsets.all(12),
                  onTap: () => launchUrl(Uri.parse(n.link), mode: LaunchMode.externalApplication),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n.title, style: W.body.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('${n.source} · ${ago(n.date)}', style: W.small),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
      const Padding(padding: EdgeInsets.only(bottom: 4), child: Text('Источник: Google Новости. Нажми на новость, чтобы открыть статью.', style: W.small)),
    ]);
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dayTitle(DateTime d) {
    final now = DateTime.now();
    if (_sameDay(d, now)) return 'СЕГОДНЯ';
    if (_sameDay(d, now.subtract(const Duration(days: 1)))) return 'ВЧЕРА';
    const m = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];
    const w = ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'];
    return '${w[d.weekday - 1]}, ${d.day} ${m[d.month - 1]}'.toUpperCase();
  }
}

// ---------------- Избранное ----------------

class FavsTab extends StatelessWidget {
  const FavsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final list = app.favs.values.toList();
    final s = app.spot;
    if (s != null) {
      for (final p in list) {
        p.dist = distanceM(s.pos, p.pos);
      }
      list.sort((a, b) => a.dist.compareTo(b.dist));
    }
    if (list.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('Сохраняй места значком 🔖 — они появятся здесь, даже без интернета.', textAlign: TextAlign.center, style: W.body)),
      );
    }
    return ListView(padding: const EdgeInsets.fromLTRB(12, 6, 12, 24), children: [
      Text('Сохранено: ${list.length} · был в ${list.where((p) => app.visited.contains(p.id)).length}', style: W.small),
      const SizedBox(height: 8),
      for (final p in list) PlaceCard(p),
    ]);
  }
}
