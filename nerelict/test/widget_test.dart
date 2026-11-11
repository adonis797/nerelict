import 'package:flutter_test/flutter_test.dart';
import 'package:nerelict/models/sniffed_media.dart';
import 'package:nerelict/services/hls_parser.dart';

void main() {
  test('解析媒体播放列表的分片与加密信息', () {
    const text = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:7
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0000000000000000000000000000000A
#EXTINF:9.0,
seg0.ts
#EXTINF:9.0,
https://cdn.example.com/seg1.ts
''';

    final playlist = parseMediaPlaylist(
        text, Uri.parse('https://cdn.example.com/hls/index.m3u8'));

    expect(playlist.segments.length, 2);
    expect(playlist.segments.first.uri.toString(),
        'https://cdn.example.com/hls/seg0.ts');
    expect(playlist.segments[1].uri.toString(),
        'https://cdn.example.com/seg1.ts');
    expect(playlist.segments.first.key!.isAes128, isTrue);
    expect(playlist.segments.first.key!.uri.toString(),
        'https://cdn.example.com/hls/key.bin');
    expect(playlist.segments.first.key!.iv!.last, 0x0A);
    expect(playlist.segments.first.sequence, 7);
    expect(playlist.isLive, isTrue);
  });

  test('未给 IV 时用分片序号推导', () {
    final iv = ivFromSequence(258);
    expect(iv.sublist(14), [0x01, 0x02]);
    expect(iv.sublist(0, 14).every((b) => b == 0), isTrue);
  });

  test('主播放列表按码率排序', () {
    const text = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080
high.m3u8
''';
    final variants = parseMasterPlaylist(
        text, Uri.parse('https://cdn.example.com/hls/master.m3u8'));

    expect(variants.length, 2);
    expect(variants.first.resolution, '1920x1080');
    expect(variants.first.uri.toString(),
        'https://cdn.example.com/hls/high.m3u8');
  });

  test('嗅探结果推导文件名', () {
    final media = SniffedMedia(
      url: 'https://cdn.example.com/a/b/movie_1080p.m3u8?token=1',
      pageUrl: 'https://example.com/watch',
      source: 'fetch',
    );
    expect(media.suggestedName, 'movie_1080p');
    expect(media.label, contains('cdn.example.com'));
  });
}
