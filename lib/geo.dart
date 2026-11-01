import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

const userAgent = 'WinterWalks/1.0 (github.com/Wateroflord/winter-walks)';

/// Расстояние в метрах.
double distanceM(LatLng a, LatLng b) {
  const r = 6371000.0;
  final dLat = (b.latitude - a.latitude) * math.pi / 180;
  final dLon = (b.longitude - a.longitude) * math.pi / 180;
  final la1 = a.latitude * math.pi / 180, la2 = b.latitude * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(la1) * math.cos(la2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.sqrt(h));
}

String fmtDist(double m) => m < 1000 ? '${(m / 10).round() * 10} м' : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} км';

/// Примерное время пешком (5 км/ч).
String walkTime(double m) {
  final min = (m / 1000 / 5 * 60).round();
  return min < 60 ? '$min мин пешком' : '${min ~/ 60} ч ${min % 60} мин пешком';
}

/// Выбранное место: координаты и названия для новостей.
class Spot {
  final LatLng pos;
  final String label; // как показывать
  final String city, district, region, country, countryCode;
  const Spot(this.pos, this.label, {this.city = '', this.district = '', this.region = '', this.country = '', this.countryCode = ''});

  Map<String, dynamic> toJson() => {
        'lat': pos.latitude,
        'lon': pos.longitude,
        'label': label,
        'city': city,
        'district': district,
        'region': region,
        'country': country,
        'cc': countryCode,
      };

  static Spot? fromJson(Map? j) {
    if (j == null || j['lat'] == null) return null;
    return Spot(
      LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()),
      '${j['label'] ?? ''}',
      city: '${j['city'] ?? ''}',
      district: '${j['district'] ?? ''}',
      region: '${j['region'] ?? ''}',
      country: '${j['country'] ?? ''}',
      countryCode: '${j['cc'] ?? ''}',
    );
  }
}

/// Определить местоположение: GPS/Windows, а если не вышло — примерно по интернет-адресу.
Future<(LatLng?, String?)> locateMe() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) throw Exception('off');
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) throw Exception('denied');
    final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 15)));
    return (LatLng(pos.latitude, pos.longitude), null);
  } catch (e) {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return (LatLng(last.latitude, last.longitude), null);
    } catch (_) {}
    // Примерно по IP (город).
    try {
      final r = await http.get(Uri.parse('https://ipwho.is/'), headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map;
      if (j['success'] == true) {
        return (
          LatLng((j['latitude'] as num).toDouble(), (j['longitude'] as num).toDouble()),
          Platform.isAndroid ? 'GPS недоступен — определил примерно по интернету. Включи геолокацию для точности.' : 'Определил примерно по интернету. Можно уточнить на карте.'
        );
      }
    } catch (_) {}
    return (null, 'Не удалось определить местоположение. Найди город поиском или выбери точку на карте.');
  }
}

/// Название места по координатам (OpenStreetMap Nominatim).
Future<Spot> reverse(LatLng p, {String lang = 'ru'}) async {
  try {
    final r = await http.get(
      Uri.https('nominatim.openstreetmap.org', '/reverse', {'lat': '${p.latitude}', 'lon': '${p.longitude}', 'format': 'jsonv2', 'zoom': '14', 'accept-language': lang}),
      headers: {'User-Agent': userAgent},
    ).timeout(const Duration(seconds: 12));
    final a = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['address'] as Map?) ?? const {};
    String s(String k) => '${a[k] ?? ''}';
    final city = [s('city'), s('town'), s('village'), s('municipality'), s('hamlet')].firstWhere((x) => x.isNotEmpty, orElse: () => '');
    final district = [s('city_district'), s('borough'), s('suburb'), s('district'), s('county')].firstWhere((x) => x.isNotEmpty, orElse: () => '');
    final region = s('state');
    return Spot(
      p,
      [if (district.isNotEmpty && district != city) district, if (city.isNotEmpty) city].join(', ').ifEmpty(region.isEmpty ? 'Выбранная точка' : region),
      city: city,
      district: district,
      region: region,
      country: s('country'),
      countryCode: s('country_code').toUpperCase(),
    );
  } catch (_) {
    return Spot(p, 'Выбранная точка');
  }
}

/// Поиск города или адреса.
Future<List<(String, LatLng)>> searchPlace(String q, {String lang = 'ru'}) async {
  final r = await http.get(
    Uri.https('nominatim.openstreetmap.org', '/search', {'q': q, 'format': 'jsonv2', 'limit': '8', 'accept-language': lang}),
    headers: {'User-Agent': userAgent},
  ).timeout(const Duration(seconds: 12));
  final list = jsonDecode(utf8.decode(r.bodyBytes)) as List;
  return [
    for (final e in list.whereType<Map>())
      ('${e['display_name']}', LatLng(double.parse('${e['lat']}'), double.parse('${e['lon']}'))),
  ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
