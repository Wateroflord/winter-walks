import 'package:flutter_test/flutter_test.dart';
import 'package:winter_walks/news.dart';

void main() {
  final since = DateTime.utc(2026, 10, 29);

  test('RSS Google Новостей: заголовок без источника, сортировка, без повторов', () {
    const rss = '''<?xml version="1.0"?><rss><channel>
<item><title>Открыли новый парк - Город24</title><link>https://a</link><pubDate>Sun, 01 Nov 2026 10:20:00 GMT</pubDate><source url="x">Город24</source></item>
<item><title>Открыли новый парк</title><link>https://b</link><pubDate>Sun, 01 Nov 2026 09:00:00 GMT</pubDate><source url="y">Другой</source></item>
<item><title>Свежая новость - Н</title><link>https://c</link><pubDate>Mon, 02 Nov 2026 08:00:00 GMT</pubDate><source url="z">Н</source></item>
<item><title>Старая - Н</title><link>https://d</link><pubDate>Mon, 05 Oct 2026 08:00:00 GMT</pubDate><source url="z">Н</source></item>
<item><title>Погода - Gismeteo</title><link>https://e</link><pubDate>Mon, 02 Nov 2026 09:00:00 GMT</pubDate><source url="g">Gismeteo</source></item>
</channel></rss>''';
    final list = parseGoogleRss(rss, since);
    expect(list.map((n) => n.title), ['Свежая новость', 'Открыли новый парк']);
    expect(list[1].source, 'Город24');
    expect(list[1].link, 'https://a');
  });

  test('GDELT: статьи, даты, фильтр старых и битых', () {
    const json = '{"articles":['
        '{"url":"https://news1","title":"Новость про район","seendate":"20261101T102000Z","domain":"news1.ua"},'
        '{"url":"https://news2","title":"Ещё новость","seendate":"20261102T080000Z","domain":"news2.ua"},'
        '{"url":"https://old","title":"Старая","seendate":"20261001T080000Z","domain":"old.ua"},'
        '{"url":"","title":"Без ссылки","seendate":"20261102T080000Z"},'
        '{"url":"https://news3","title":"","seendate":"20261102T080000Z"}'
        ']}';
    final list = parseGdelt(json, since);
    expect(list.map((n) => n.title), ['Ещё новость', 'Новость про район']);
    expect(list.first.source, 'news2.ua');
    expect(list.last.date.toUtc(), DateTime.utc(2026, 11, 1, 10, 20));
  });

  test('GDELT: текст вместо JSON не ломает приложение', () {
    expect(parseGdelt('Your query was too short', since), isEmpty);
    expect(parseGdelt('{}', since), isEmpty);
  });

  test('язык и страна новостей', () {
    expect(newsLocale('uk', 'UA'), ('uk', 'UA'));
    expect(newsLocale('de', ''), ('ru', 'UA'));
  });
}
