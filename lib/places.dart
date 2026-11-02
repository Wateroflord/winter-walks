import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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

const _overpass = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.private.coffee/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];

/// Спрашиваем все зеркала сразу и берём первый успешный ответ.
Future<List> _overpassQuery(String q) {
  final done = Completer<List>();
  var failed = 0;
  final errors = <String>[];
  for (final url in _overpass) {
    http.post(Uri.parse(url), headers: {'User-Agent': userAgent}, body: {'data': q}).timeout(const Duration(seconds: 35)).then((res) {
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      final m = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
      final remark = '${m['remark'] ?? ''}';
      if (remark.contains('timed out') || remark.contains('out of memory')) throw remark;
      if (!done.isCompleted) done.complete((m['elements'] as List?) ?? const []);
    }).catchError((Object e) {
      errors.add('${Uri.parse(url).host}: $e');
      if (++failed == _overpass.length && !done.isCompleted) done.completeError(Exception('Сервер карты не отвечает (${errors.join('; ')})'));
    });
  }
  return done.future;
}

/// Места из OpenStreetMap в радиусе [radiusM].
Future<List<Place>> fetchOsm(LatLng c, double radiusM, {bool light = false}) async {
  // Квадрат вокруг точки: так сервер отвечает в разы быстрее, чем с «кругом»; лишнее отрежем по расстоянию.
  final dLat = radiusM / 111320.0;
  final dLon = radiusM / (111320.0 * math.cos(c.latitude * math.pi / 180)).abs().clamp(1000, 111320);
  final bbox = '${c.latitude - dLat},${c.longitude - dLon},${c.latitude + dLat},${c.longitude + dLon}';
  // На большом радиусе берём только заметные места (со статьёй в Википедии/Викиданных), чтобы ответ был быстрым.
  final big = radiusM > 8000;
  final named = big ? '[name][wikidata]' : '[name]';
  final small = big ? '[wikidata]' : '';
  // Лёгкий запрос: только парки, природа, смотровые и главные достопримечательности — отвечает быстро даже в центре большого города.
  final q = light
      ? """
[out:json][timeout:20][bbox:$bbox];
(
  nw[leisure~"^(park|garden|nature_reserve)\$"][name]${big ? '[wikidata]' : ''};
  nw[tourism=viewpoint]$small;
  nw[tourism=attraction][name][wikidata];
  nw[historic~"^(castle|monument|fort|city_gate)\$"][name][wikidata];
  nw[natural~"^(waterfall|peak|beach|cliff)\$"][name]$small;
);
out center tags qt 300;
"""
      : """
[out:json][timeout:30][bbox:$bbox];
(
  nwr[leisure~"^(park|garden|nature_reserve)\$"]$named;
  ${big ? 'nwr[boundary~"^(protected_area|national_park)\$"]$named;' : ''}
  nw[tourism=viewpoint]$small;
  nwr[tourism~"^(attraction|museum)\$"]$named;
  nw[tourism=artwork][artwork_type!=plaque]$named;
  nw[historic~"^(castle|monument|ruins|fort|manor|city_gate|archaeological_site|church|monastery|tower)\$"]$named;
  nw[historic=memorial][memorial~"^(statue|war_memorial|sculpture)\$"]$named;
  nw[natural~"^(waterfall|peak|beach|cliff|cave_entrance|rock)\$"]$named;
  nw[waterway=waterfall]$small;
  nw[leisure=promenade]$small;
  nw[man_made~"^(lighthouse|tower)\$"][tourism];
  ${big ? '' : 'way[highway=pedestrian][name];'}
);
out center tags qt 800;
""";
  final els = (await _overpassQuery(q)).whereType<Map>();
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
    p.score = (tags['wikipedia'] != null ? 3 : 0) + (tags['wikidata'] != null ? 2 : 0) + (p.image != null ? 2 : 0) + (tags['tourism'] == 'attraction' ? 2 : 0) + (cat == 'viewpoint' ? 2 : 0) + (cat == 'park' || cat == 'nature' ? 1 : 0);
    out.add(p);
  }
  return out;
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
  final seen = <String>{};
  // Типы координат, которые означают «целая страна/город/событие», а не место для прогулки.
  const badTypes = {'country', 'satellite', 'adm1st', 'adm2nd', 'adm3rd', 'city', 'event', 'railwaystation', 'airport', 'edu'};
  for (final l in {lang, 'en'}) {
    try {
      final r = await http.get(
        Uri.https('$l.wikipedia.org', '/w/api.php', {
          'action': 'query',
          'generator': 'geosearch',
          'ggscoord': '${c.latitude}|${c.longitude}',
          'ggsradius': '${radiusM.clamp(100, 10000).round()}',
          'ggslimit': '100',
          'prop': 'pageimages|coordinates|description|pageprops',
          'coprop': 'type',
          'ppprop': 'wikibase_item',
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
        if (badTypes.contains('${co['type'] ?? ''}'.toLowerCase())) continue;
        final qid = '${(pg['pageprops'] as Map?)?['wikibase_item'] ?? ''}';
        final title = '${pg['title']}';
        final desc = '${pg['description'] ?? ''}'.toLowerCase();
        // Пропускаем станции, улицы, учреждения, события и т.п.
        if (RegExp(r'станци|улица|проспект|школ|больниц|компани|район|микрорайон|воеводств|губерни|государств|сражени|битва|восстани|оборона|гетто|станция|посольств|магазин|отел|гостиниц|station|street|school|company|district|village|село|деревня|battle|uprising|\bstate\b|voivodeship|governorate|embassy|hotel|ghetto')
            .hasMatch('$desc ${title.toLowerCase()}')) continue;
        // Статьи о городах, странах, регионах и событиях — не место для прогулки.
        if (RegExp(r'^(город|столица|страна|регион|историческ|область|посёлок|массов|убийств|city|town|capital|country|historical|region|municipality|village|province|county|massacre|\d{3,4})').hasMatch(desc)) continue;
        if (RegExp(r'massacre|mass murder|genocide|убийство|расстрел|резня').hasMatch(desc)) continue;
        if (qid.isNotEmpty && !seen.add(qid)) continue;
        if (out.any((p) => p.name == title)) continue;
        out.add(Place('wiki_${l}_${pg['pageid']}', title, LatLng((co['lat'] as num).toDouble(), (co['lon'] as num).toDouble()), 'wiki', {if (qid.isNotEmpty) 'wikidata': qid},
            image: thumb, wiki: 'https://$l.wikipedia.org/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}', about: pg['description'] as String?)
          ..score = 3);
      }
      if (out.length >= 8) break; // английскую Википедию спрашиваем, только если на своём языке мало
    } catch (_) {}
  }
  return out;
}

/// Все места вокруг точки, отсортированные по расстоянию.
/// [onPartial] получает быстрые результаты из Википедии, пока карта ещё грузится.
Future<List<Place>> fetchAll(LatLng c, double radiusM, {String lang = 'ru', void Function(List<Place>)? onPartial}) async {
  List<Place> finish(List<Place> all) {
    for (final p in all) {
      p.dist = distanceM(c, p.pos);
    }
    all.removeWhere((p) => p.dist > radiusM * 1.05);
    // Не больше 300 мест: самые интересные, потом по расстоянию.
    if (all.length > 300) {
      all.sort((a, b) => b.score != a.score ? b.score.compareTo(a.score) : a.dist.compareTo(b.dist));
      all.removeRange(300, all.length);
    }
    all.sort((a, b) => a.dist.compareTo(b.dist));
    return all;
  }

  var osmDone = false;
  List<Place> shown = [];
  void partial(List<Place> more) {
    if (osmDone || more.isEmpty) return;
    final ids = {for (final p in shown) p.id};
    shown = finish([...shown, ...more.where((p) => !ids.contains(p.id))]);
    onPartial?.call(shown);
  }

  final wikiF = fetchWiki(c, radiusM, lang: lang).catchError((_) => <Place>[]);
  wikiF.then(partial);
  // Лёгкий и полный запросы идут параллельно: лёгкий быстро показывает главное, полный дополняет.
  final lightF = fetchOsm(c, radiusM, light: true).then<List<Place>?>((v) async {
    await fillWikidataImages(v);
    return v;
  }).catchError((Object _) => null);
  lightF.then((v) => partial(v ?? const []));
  Object? osmErr;
  var osm = await fetchOsm(c, radiusM).then<List<Place>?>((v) => v).catchError((Object e) {
    osmErr = e;
    return null;
  });
  osm ??= await lightF;
  osmDone = true;
  final wiki = await wikiF;
  if (osm == null && wiki.isEmpty) throw Exception('Нет связи с картой. Проверь интернет. (${'$osmErr'.replaceFirst('Exception: ', '')})');
  final all = <Place>[...?osm];
  await fillWikidataImages(all);
  // Статьи Википедии, которых нет среди мест карты.
  final qids = {for (final p in all) if (p.tags['wikidata'] != null) p.tags['wikidata']!};
  for (final w in wiki) {
    if (w.tags['wikidata'] != null && qids.contains(w.tags['wikidata'])) continue;
    final dup = all.any((p) => distanceM(p.pos, w.pos) < 150 && (p.name.toLowerCase() == w.name.toLowerCase() || p.wiki == w.wiki));
    if (!dup) all.add(w);
  }
  return finish(all);
}
