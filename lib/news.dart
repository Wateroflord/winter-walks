import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'geo.dart';

class NewsItem {
  final String title, source, link;
  final DateTime date;
  const NewsItem(this.title, this.source, this.link, this.date);
}

/// Язык и страна для Google Новостей.
(String, String) newsLocale(String lang, String cc) {
  final country = cc.isEmpty ? 'UA' : cc;
  final hl = switch (lang) {
    'uk' => 'uk',
    'en' => 'en',
    'pl' => 'pl',
    _ => 'ru',
  };
  return (hl, country);
}

/// Новости по названию места за последние [days] дней.
///
/// Основной источник — Google Новости (RSS). Это неофициальный способ, и он
/// может перестать работать, поэтому при ошибке или пустом ответе пробуем
/// запасной источник — открытый API GDELT (новости со всего мира, без ключа).
Future<List<NewsItem>> fetchNews(String place, {String lang = 'ru', String cc = '', int days = 7, String extra = ''}) async {
  Object? googleError;
  try {
    final g = await fetchGoogleNews(place, lang: lang, cc: cc, days: days, extra: extra);
    if (g.isNotEmpty) return g;
  } catch (e) {
    googleError = e;
  }
  try {
    final d = await fetchGdeltNews(place, lang: lang, days: days);
    if (d.isNotEmpty || googleError == null) return d;
  } catch (_) {
    if (googleError == null) return const [];
  }
  throw googleError;
}

Future<List<NewsItem>> fetchGoogleNews(String place, {String lang = 'ru', String cc = '', int days = 7, String extra = ''}) async {
  final (hl, gl) = newsLocale(lang, cc);
  final q = '"$place"${extra.isEmpty ? '' : ' $extra'} when:${days}d';
  final uri = Uri.https('news.google.com', '/rss/search', {'q': q, 'hl': hl, 'gl': gl, 'ceid': '$gl:$hl'});
  final r = await http.get(uri, headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  return parseGoogleRss(r.body, DateTime.now().subtract(Duration(days: days)));
}

/// Разбор RSS Google Новостей.
List<NewsItem> parseGoogleRss(String body, DateTime since) {
  final doc = XmlDocument.parse(body);
  final out = <NewsItem>[];
  for (final it in doc.findAllElements('item')) {
    String text(String n) => it.getElement(n)?.innerText.trim() ?? '';
    var title = text('title');
    final source = text('source');
    if (source.isNotEmpty && title.endsWith(' - $source')) title = title.substring(0, title.length - source.length - 3);
    final date = _parseRfc822(text('pubDate')) ?? DateTime.now();
    if (date.isBefore(since)) continue;
    if (source.toLowerCase().contains('gismeteo')) continue;
    out.add(NewsItem(title, source, text('link'), date));
  }
  return _tidy(out);
}

const _gdeltLang = {'ru': 'russian', 'uk': 'ukrainian', 'en': 'english', 'pl': 'polish'};

Future<List<NewsItem>> fetchGdeltNews(String place, {String lang = 'ru', int days = 7}) async {
  final l = _gdeltLang[lang] ?? 'russian';
  final uri = Uri.https('api.gdeltproject.org', '/api/v2/doc/doc', {
    'query': '"$place" sourcelang:$l',
    'mode': 'artlist',
    'format': 'json',
    'timespan': '${days}d',
    'maxrecords': '60',
    'sort': 'datedesc',
  });
  final r = await http.get(uri, headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 20));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  return parseGdelt(utf8.decode(r.bodyBytes, allowMalformed: true), DateTime.now().subtract(Duration(days: days)));
}

/// Разбор ответа GDELT (mode=artlist, format=json).
List<NewsItem> parseGdelt(String body, DateTime since) {
  final dynamic j;
  try {
    j = jsonDecode(body);
  } catch (_) {
    return const []; // GDELT отвечает текстом, если запрос ему не понравился
  }
  final out = <NewsItem>[];
  for (final a in (j is Map ? j['articles'] as List? ?? const [] : const [])) {
    if (a is! Map) continue;
    final title = '${a['title'] ?? ''}'.trim();
    final link = '${a['url'] ?? ''}';
    if (title.isEmpty || !link.startsWith('http')) continue;
    final date = _parseGdeltDate('${a['seendate'] ?? ''}') ?? DateTime.now();
    if (date.isBefore(since)) continue;
    out.add(NewsItem(title, '${a['domain'] ?? ''}', link, date));
  }
  return _tidy(out);
}

/// Свежие сверху, без повторов одного и того же заголовка.
List<NewsItem> _tidy(List<NewsItem> out) {
  out.sort((a, b) => b.date.compareTo(a.date));
  final seen = <String>{};
  return [for (final n in out) if (seen.add(n.title.toLowerCase())) n];
}

DateTime? _parseGdeltDate(String s) {
  // 20261101T102000Z
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$').firstMatch(s.trim());
  if (m == null) return null;
  int g(int i) => int.parse(m.group(i)!);
  return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6)).toLocal();
}

const _months = {'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6, 'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12};

DateTime? _parseRfc822(String s) {
  // Sun, 01 Nov 2026 10:20:00 GMT
  final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(s);
  if (m == null) return null;
  final mon = _months[m.group(2)];
  if (mon == null) return null;
  return DateTime.utc(int.parse(m.group(3)!), mon, int.parse(m.group(1)!), int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6)!)).toLocal();
}

String ago(DateTime d) {
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 60) return '${diff.inMinutes.clamp(1, 59)} мин назад';
  if (diff.inHours < 24) return '${diff.inHours} ч назад';
  if (diff.inDays == 1) return 'вчера';
  return '${diff.inDays} дн назад';
}
