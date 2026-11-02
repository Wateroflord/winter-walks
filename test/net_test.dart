// Проверка источников данных (запускается в GitHub Actions, где есть интернет).
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:winter_walks/geo.dart';
import 'package:winter_walks/news.dart';
import 'package:winter_walks/places.dart';

void main() {
  final cities = {
    'Kyiv': const LatLng(50.4501, 30.5234),
    'Lviv': const LatLng(49.8397, 24.0297),
    'Warsaw': const LatLng(52.2297, 21.0122),
  };
  test('osm only timing', () async {
    for (final e in cities.entries) {
      final sw = Stopwatch()..start();
      try {
        final l = await fetchOsm(e.value, 3000, light: true);
        print('OSM-light ${e.key} 3km: ${l.length} in ${sw.elapsedMilliseconds}ms');
        sw.reset();
        final r = await fetchOsm(e.value, 3000);
        print('OSM ${e.key} 3km: ${r.length} in ${sw.elapsedMilliseconds}ms');
      } catch (err) {
        print('OSM ${e.key} 3km FAIL in ${sw.elapsedMilliseconds}ms: $err');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
  for (final e in cities.entries) {
    test('data ${e.key}', () async {
      final spot = await reverse(e.value);
      print('SPOT ${e.key}: label=${spot.label} city=${spot.city} district=${spot.district} region=${spot.region} cc=${spot.countryCode}');
      for (final r in [3, 20]) {
        final sw = Stopwatch()..start();
        final places = await fetchAll(e.value, r * 1000.0, lang: 'ru');
        final byCat = <String, int>{};
        for (final p in places) {
          byCat[p.cat] = (byCat[p.cat] ?? 0) + 1;
        }
        print('PLACES ${e.key} ${r}km: ${places.length} in ${sw.elapsedMilliseconds}ms, images=${places.where((p) => p.image != null).length}, $byCat');
        for (final p in places.take(5)) {
          print('   ${p.category.emoji} ${p.name} ${fmtDist(p.dist)} img=${p.image != null} wiki=${p.wiki != null}');
        }
      }
      for (final place in [spot.district, spot.city, spot.region].where((s) => s.isNotEmpty)) {
        final news = await fetchNews(place, lang: 'ru', cc: spot.countryCode);
        print('NEWS ${e.key} "$place": ${news.length}');
        for (final n in news.take(3)) {
          print('   ${ago(n.date)} | ${n.source} | ${n.title}');
        }
      }
      final found = await searchPlace('Одесса');
      print('SEARCH Одесса: ${found.length} ${found.isEmpty ? '' : found.first.$1}');
      final ip = await locateMe();
      print('LOCATE: ${ip.$1} ${ip.$2}');
    }, timeout: const Timeout(Duration(minutes: 8)));
  }
}
