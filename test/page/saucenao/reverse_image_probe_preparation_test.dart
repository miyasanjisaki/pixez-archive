import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixez/page/saucenao/sauce_store.dart';
import 'package:pixez/utils/reverse_image_search.dart';

Uint8List _orientedJpeg() {
  final source = img.Image(width: 20, height: 40, numChannels: 3);
  for (var y = 0; y < source.height; y++) {
    for (var x = 0; x < source.width; x++) {
      source.setPixelRgb(x, y, x * 8, y * 4, 32);
    }
  }
  source.exif.imageIfd.orientation = 6;
  return img.encodeJpg(source, quality: 100);
}

Uint8List _threeBandPng() {
  final source = img.Image(width: 60, height: 30, numChannels: 3);
  for (var y = 0; y < source.height; y++) {
    final (red, green, blue) = switch (y) {
      < 10 => (240, 15, 15),
      < 20 => (15, 240, 15),
      _ => (15, 15, 240),
    };
    for (var x = 0; x < source.width; x++) {
      source.setPixelRgb(x, y, red, green, blue);
    }
  }
  return img.encodePng(source);
}

Uint8List _jpegClaimingTooManyPixels() {
  final bytes = img.encodeJpg(
    img.Image(width: 8, height: 8, numChannels: 3),
    quality: 100,
  );
  for (var index = 0; index + 8 < bytes.length; index++) {
    if (bytes[index] != 0xff ||
        (bytes[index + 1] != 0xc0 && bytes[index + 1] != 0xc2)) {
      continue;
    }
    const width = 8192;
    const height = 4097;
    bytes[index + 5] = height >> 8;
    bytes[index + 6] = height & 0xff;
    bytes[index + 7] = width >> 8;
    bytes[index + 8] = width & 0xff;
    return bytes;
  }
  throw StateError('JPEG start-of-frame marker not found');
}

img.Image _decodePrepared(Map<String, Object>? prepared) {
  expect(prepared, isNotNull);
  expect(prepared, isNot(contains('error')));
  final decoded = img.decodeJpg(prepared!['bytes'] as Uint8List);
  expect(decoded, isNotNull);
  return decoded!;
}

void _expectDominant(img.Pixel pixel, String channel) {
  final values = <String, num>{
    'red': pixel.r,
    'green': pixel.g,
    'blue': pixel.b,
  };
  final selected = values[channel]!;
  final others = values.entries
      .where((entry) => entry.key != channel)
      .map((entry) => entry.value);
  expect(selected, greaterThan(others.reduce((a, b) => a > b ? a : b) + 40));
}

void main() {
  test('normalizes EXIF orientation before making the provider JPEG', () {
    final output = _decodePrepared(
      prepareExternalSearchImageForTesting(_orientedJpeg()),
    );

    expect(output.width, 40);
    expect(output.height, 20);
    expect(output.exif.imageIfd.hasOrientation, isFalse);
  });

  test('half-image probes keep all content on the requested canvas side', () {
    final input = _threeBandPng();
    final top = _decodePrepared(
      prepareExternalSearchProbeForTesting(
        input,
        ReverseImageProbeKind.inputTopHalf,
      ),
    );
    final bottom = _decodePrepared(
      prepareExternalSearchProbeForTesting(
        input,
        ReverseImageProbeKind.inputBottomHalf,
      ),
    );

    expect((top.width, top.height), (60, 60));
    expect((bottom.width, bottom.height), (60, 60));
    _expectDominant(top.getPixel(30, 5), 'red');
    _expectDominant(top.getPixel(30, 15), 'green');
    _expectDominant(top.getPixel(30, 25), 'blue');
    _expectDominant(top.getPixel(30, 45), 'blue');
    _expectDominant(bottom.getPixel(30, 15), 'red');
    _expectDominant(bottom.getPixel(30, 35), 'red');
    _expectDominant(bottom.getPixel(30, 45), 'green');
    _expectDominant(bottom.getPixel(30, 55), 'blue');
    expect(top.exif.imageIfd.hasOrientation, isFalse);
    expect(bottom.exif.imageIfd.hasOrientation, isFalse);
  });

  test('distinguishes the 32 megapixel decode limit from file size', () {
    final result = prepareExternalSearchImageForTesting(
      _jpegClaimingTooManyPixels(),
    );

    expect(result, const <String, Object>{'error': 'pixel_limit'});
  });
}
