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

/// Новости по названию места за последние [days] дней (Google Новости, RSS).
Future<List<NewsItem>> fetchNews(String place, {String lang = 'ru', String cc = '', int days = 7, String extra = ''}) async {
  final (hl, gl) = newsLocale(lang, cc);
  final q = '"$place"${extra.isEmpty ? '' : ' $extra'} when:${days}d';
  final uri = Uri.https('news.google.com', '/rss/search', {'q': q, 'hl': hl, 'gl': gl, 'ceid': '$gl:$hl'});
  final r = await http.get(uri, headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
  final doc = XmlDocument.parse(r.body);
  final since = DateTime.now().subtract(Duration(days: days));
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
  out.sort((a, b) => b.date.compareTo(a.date));
  // Убираем повторы одного и того же заголовка.
  final seen = <String>{};
  return [for (final n in out) if (seen.add(n.title.toLowerCase())) n];
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
