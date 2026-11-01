import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geo.dart';

enum Kind { walk, photo }

class Category {
  final String id, title, emoji;
  final Kind kind;
  const Category(this.id, this.title, this.emoji, this.kind);
}

const categories = <Category>[
  Category('park', 'Парк', '🌳', Kind.walk),
  Category('garden', 'Сад', '🌷', Kind.walk),
  Category('nature', 'Природа и заповедник', '🌲', Kind.walk),
  Category('water', 'Набережная и вода', '🌊', Kind.walk),
  Category('beach', 'Пляж', '🏖️', Kind.walk),
  Category('trail', 'Тропа', '🥾', Kind.walk),
  Category('viewpoint', 'Смотровая площадка', '🔭', Kind.photo),
  Category('attraction', 'Достопримечательность', '📸', Kind.photo),
  Category('historic', 'История и архитектура', '🏰', Kind.photo),
  Category('art', 'Арт и скульптура', '🗿', Kind.photo),
  Category('waterfall', 'Водопад', '💦', Kind.photo),
  Category('peak', 'Вершина и скалы', '⛰️', Kind.photo),
  Category('wiki', 'Интересное место', '📖', Kind.photo),
];

Category catOf(String id) => categories.firstWhere((c) => c.id == id, orElse: () => categories.first);

class Place {
  final String id;
  final String name;
  final LatLng pos;
  final String cat;
  final Map<String, String> tags;
  String? image; // ссылка на фото
  String? wiki; // ссылка на статью
  String? about;
  double dist = 0;
  int score = 0;
  Place(this.id, this.name, this.pos, this.cat, this.tags, {this.image, this.wiki, this.about});

  Category get category => catOf(cat);
  Kind get kind => category.kind;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'lat': pos.latitude, 'lon': pos.longitude, 'cat': cat, 'image': image, 'wiki': wiki, 'about': about};
  static Place fromJson(Map j) => Place('${j['id']}', '${j['name']}', LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()), '${j['cat']}', const {},
      image: j['image'] as String?, wiki: j['wiki'] as String?, about: j['about'] as String?);
}

String? _classify(Map<String, String> t) {
  final leisure = t['leisure'] ?? '', tourism = t['tourism'] ?? '', historic = t['historic'] ?? '', natural = t['natural'] ?? '';
  if (natural == 'waterfall' || t['waterway'] == 'waterfall') return 'waterfall';
  if (tourism == 'viewpoint') return 'viewpoint';
  if (natural == 'peak' || natural == 'cliff' || natural == 'rock' || natural == 'cave_entrance') return 'peak';
  if (leisure == 'nature_reserve' || t['boundary'] == 'protected_area' || t['boundary'] == 'national_park' || natural == 'wood') return 'nature';
  if (leisure == 'garden' || t['garden:type'] != null) return 'garden';
  if (leisure == 'park' || t['landuse'] == 'recreation_ground') return 'park';
  if (natural == 'beach' || leisure == 'beach_resort') return 'beach';
  if (leisure == 'promenade' || t['highway'] == 'pedestrian' && (t['name'] ?? '').isNotEmpty || natural == 'water' || t['waterway'] == 'riverbank') return 'water';
  if (t['route'] == 'hiking' || t['highway'] == 'path' || t['highway'] == 'footway') return 'trail';
  if (tourism == 'artwork' || historic == 'memorial' && t['memorial'] == 'statue') return 'art';
  if (historic.isNotEmpty || t['building'] == 'castle' || t['amenity'] == 'place_of_worship') return 'historic';
  if (tourism == 'attraction' || tourism == 'museum' || t['man_made'] == 'lighthouse' || t['man_made'] == 'tower') return 'attraction';
  return null;
}

const _overpass = ['https://overpass-api.de/api/interpreter', 'https://overpass.kumi.systems/api/interpreter', 'https://maps.mail.ru/osm/tools/overpass/api/interpreter'];

/// Места из OpenStreetMap в радиусе [radiusM].
Future<List<Place>> fetchOsm(LatLng c, double radiusM) async {
  final r = radiusM.round();
  final a = 'around:$r,${c.latitude},${c.longitude}';
  // На большом радиусе берём только заметные места (с названием и статьёй/описанием), чтобы ответ был быстрым.
  final big = radiusM > 8000;
  final named = big ? '[name][~"^(wikipedia|wikidata)\$"~"."]' : '[name]';
  final q = '''
[out:json][timeout:40];
(
  nwr($a)[leisure~"^(park|garden|nature_reserve)\$"]$named;
  nwr($a)[boundary~"^(protected_area|national_park)\$"]$named;
  nwr($a)[tourism=viewpoint];
  nwr($a)[tourism~"^(attraction|artwork|museum)\$"]$named;
  nwr($a)[historic~"^(castle|monument|memorial|ruins|fort|manor|city_gate|archaeological_site|church|monastery|tower)\$"]$named;
  nwr($a)[natural~"^(waterfall|peak|beach|cliff|cave_entrance|rock)\$"][name];
  nwr($a)[waterway=waterfall];
  nwr($a)[leisure=promenade];
  nwr($a)[man_made~"^(lighthouse|tower)\$"][tourism];
  ${big ? '' : 'way($a)[highway=pedestrian][name];'}
);
out center tags qt 500;
''';
  Object? lastErr;
  for (final url in _overpass) {
    try {
      final res = await http.post(Uri.parse(url), headers: {'User-Agent': userAgent}, body: {'data': q}).timeout(const Duration(seconds: 45));
      if (res.statusCode != 200) {
        lastErr = 'HTTP ${res.statusCode}';
        continue;
      }
      final els = ((jsonDecode(utf8.decode(res.bodyBytes)) as Map)['elements'] as List? ?? const []).whereType<Map>();
      final out = <Place>[];
      final seenNames = <String>{};
      for (final e in els) {
        final tags = {for (final x in ((e['tags'] as Map?) ?? const {}).entries) '${x.key}': '${x.value}'};
        final lat = (e['lat'] ?? (e['center'] as Map?)?['lat']) as num?;
        final lon = (e['lon'] ?? (e['center'] as Map?)?['lon']) as num?;
        if (lat == null || lon == null) continue;
        final cat = _classify(tags);
        if (cat == null) continue;
        var name = tags['name:ru'] ?? tags['name'] ?? '';
        if (name.isEmpty) {
          if (cat == 'viewpoint') {
            name = 'Смотровая точка';
          } else if (cat == 'waterfall') {
            name = 'Водопад';
          } else {
            continue;
          }
        }
        final p = Place('osm_${e['type']}_${e['id']}', name, LatLng(lat.toDouble(), lon.toDouble()), cat, tags);
        // Убираем дубли (парк как участок и как точка).
        final key = '${name.toLowerCase()}_${cat}_${(p.pos.latitude * 200).round()}_${(p.pos.longitude * 200).round()}';
        if (!seenNames.add(key)) continue;
        if (tags['image'] != null && tags['image']!.startsWith('http')) p.image = tags['image'];
        final commons = tags['wikimedia_commons'];
        if (p.image == null && commons != null && commons.startsWith('File:')) p.image = commonsThumb(commons.substring(5));
        final wp = tags['wikipedia'];
        if (wp != null && wp.contains(':')) {
          final i = wp.indexOf(':');
          p.wiki = 'https://${wp.substring(0, i)}.wikipedia.org/wiki/${Uri.encodeComponent(wp.substring(i + 1).replaceAll(' ', '_'))}';
        }
        p.about = tags['description:ru'] ?? tags['description'];
        p.score = (tags['wikipedia'] != null ? 3 : 0) + (tags['wikidata'] != null ? 2 : 0) + (p.image != null ? 2 : 0) + (tags['tourism'] == 'attraction' ? 2 : 0) + (cat == 'viewpoint' ? 2 : 0);
        out.add(p);
      }
      return out;
    } catch (e) {
      lastErr = e;
    }
  }
  throw Exception('Сервер карты не отвечает ($lastErr)');
}

String commonsThumb(String file, {int width = 500}) =>
    'https://commons.wikimedia.org/wiki/Special:FilePath/${Uri.encodeComponent(file.replaceAll(' ', '_'))}?width=$width';

/// Фото для мест с Wikidata (свойство P18).
Future<void> fillWikidataImages(List<Place> places) async {
  final need = places.where((p) => p.image == null && p.tags['wikidata'] != null).toList();
  for (var i = 0; i < need.length; i += 50) {
    final chunk = need.sublist(i, (i + 50).clamp(0, need.length));
    try {
      final ids = chunk.map((p) => p.tags['wikidata']!).toSet().join('|');
      final r = await http.get(
        Uri.https('www.wikidata.org', '/w/api.php', {'action': 'wbgetentities', 'ids': ids, 'props': 'claims|descriptions', 'languages': 'ru|uk|en', 'format': 'json'}),
        headers: {'User-Agent': userAgent},
      ).timeout(const Duration(seconds: 15));
      final ents = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['entities'] as Map?) ?? const {};
      for (final p in chunk) {
        final e = ents[p.tags['wikidata']] as Map?;
        if (e == null) continue;
        final p18 = (((e['claims'] as Map?)?['P18'] as List?)?.firstOrNull as Map?)?['mainsnak'] as Map?;
        final file = (p18?['datavalue'] as Map?)?['value'];
        if (file is String) p.image = commonsThumb(file);
        final d = (e['descriptions'] as Map?) ?? const {};
        p.about ??= ((d['ru'] ?? d['uk'] ?? d['en']) as Map?)?['value'] as String?;
      }
    } catch (_) {}
  }
}

/// Интересные места с фото из Википедии (радиус до 10 км).
Future<List<Place>> fetchWiki(LatLng c, double radiusM, {String lang = 'ru'}) async {
  final out = <Place>[];
  for (final l in {lang, 'en'}) {
    try {
      final r = await http.get(
        Uri.https('$l.wikipedia.org', '/w/api.php', {
          'action': 'query',
          'generator': 'geosearch',
          'ggscoord': '${c.latitude}|${c.longitude}',
          'ggsradius': '${radiusM.clamp(100, 10000).round()}',
          'ggslimit': '80',
          'prop': 'pageimages|coordinates|description',
          'piprop': 'thumbnail',
          'pithumbsize': '500',
          'format': 'json',
        }),
        headers: {'User-Agent': userAgent},
      ).timeout(const Duration(seconds: 15));
      final pages = (((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['query'] as Map?)?['pages'] as Map?) ?? const {};
      for (final pg in pages.values.whereType<Map>()) {
        final thumb = (pg['thumbnail'] as Map?)?['source'] as String?;
        final co = (pg['coordinates'] as List?)?.firstOrNull as Map?;
        if (thumb == null || co == null) continue; // нужны именно места с фото
        final title = '${pg['title']}';
        final desc = '${pg['description'] ?? ''}'.toLowerCase();
        // Пропускаем станции, улицы, учреждения и т.п.
        if (RegExp(r'станци|улица|проспект|школ|больниц|компани|район|микрорайон|station|street|school|company|district|village|село|деревня').hasMatch('$desc ${title.toLowerCase()}')) continue;
        if (out.any((p) => p.name == title)) continue;
        out.add(Place('wiki_${l}_${pg['pageid']}', title, LatLng((co['lat'] as num).toDouble(), (co['lon'] as num).toDouble()), 'wiki', const {},
            image: thumb, wiki: 'https://$l.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}', about: pg['description'] as String?)
          ..score = 3);
      }
      if (out.length >= 20) break;
    } catch (_) {}
  }
  return out;
}

/// Все места вокруг точки, отсортированные по расстоянию.
Future<List<Place>> fetchAll(LatLng c, double radiusM, {String lang = 'ru'}) async {
  final results = await Future.wait([
    fetchOsm(c, radiusM).then<List<Place>?>((v) => v).catchError((_) => null),
    fetchWiki(c, radiusM, lang: lang).catchError((_) => <Place>[]),
  ]);
  final osm = results[0];
  final wiki = results[1] ?? const <Place>[];
  if (osm == null && wiki.isEmpty) throw Exception('Нет связи с картой. Проверь интернет.');
  final all = <Place>[...?osm];
  await fillWikidataImages(all);
  // Статьи Википедии, которых нет среди мест карты.
  for (final w in wiki) {
    final dup = all.any((p) => distanceM(p.pos, w.pos) < 150 && (p.name.toLowerCase() == w.name.toLowerCase() || p.wiki == w.wiki));
    if (!dup) all.add(w);
  }
  for (final p in all) {
    p.dist = distanceM(c, p.pos);
  }
  all.removeWhere((p) => p.dist > radiusM * 1.05);
  all.sort((a, b) => a.dist.compareTo(b.dist));
  return all;
}
