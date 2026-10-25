import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/cover_art_utils.dart';

void main() {
  group('highResCoverUrl', () {
    test('upgrades a small Deezer cover to display quality', () {
      expect(
        highResCoverUrl(
          'https://cdn-images.dzcdn.net/images/cover/hash/'
          '250x250-000000-80-0-0.jpg',
        ),
        'https://cdn-images.dzcdn.net/images/cover/hash/'
        '1000x1000-000000-80-0-0.jpg',
      );
    });

    test('does not downgrade provider-supplied Deezer artwork', () {
      const url =
          'https://cdn-images.dzcdn.net/images/cover/hash/'
          '1400x1400-000000-80-0-0.jpg';
      expect(highResCoverUrl(url), url);
    });

    test('still upgrades a Spotify 300px cover to 640px', () {
      expect(
        highResCoverUrl('https://i.scdn.co/image/ab67616d00001e02abcdef'),
        'https://i.scdn.co/image/ab67616d0000b273abcdef',
      );
    });
  });
}
