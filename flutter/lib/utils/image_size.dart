import 'dart:typed_data';

/// Reads the pixel dimensions of a common image format from its header
/// without decoding the payload. Returns null for unrecognized or truncated
/// data.
(int, int)? intrinsicImageSize(Uint8List b) {
  // PNG: 8-byte signature, then the IHDR width/height as big-endian u32.
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return (_be32(b, 16), _be32(b, 20));
  }
  // GIF: 'GIF8' signature, logical screen size as little-endian u16.
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return (_le16(b, 6), _le16(b, 8));
  }
  // BMP: 'BM', signed little-endian i32 size (height is negative when rows
  // are stored top-down).
  if (b.length >= 26 && b[0] == 0x42 && b[1] == 0x4D) {
    return (_le32s(b, 18), _le32s(b, 22).abs());
  }
  // JPEG: SOI then a walk of length-prefixed markers to the start of frame.
  if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    return _jpegSize(b);
  }
  // WebP: RIFF container with a VP8/VP8L/VP8X chunk.
  if (b.length >= 30 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return _webpSize(b);
  }
  return null;
}

(int, int)? _jpegSize(Uint8List b) {
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final marker = b[i + 1];
    // RST, TEM, SOI and EOI markers carry no payload length.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
      i += 2;
      continue;
    }
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      return (_be16(b, i + 7), _be16(b, i + 5));
    }
    i += 2 + _be16(b, i + 2);
  }
  return null;
}

(int, int)? _webpSize(Uint8List b) {
  switch (String.fromCharCodes(b.sublist(12, 16))) {
    case 'VP8X':
      // 24-bit little-endian fields, stored minus one.
      return (_le24(b, 24) + 1, _le24(b, 27) + 1);
    case 'VP8L':
      if (b[20] != 0x2F) return null;
      final bits = _le32(b, 21);
      return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    case 'VP8 ':
      // 3-byte frame tag, then the 9D 01 2A start code, then 14-bit dims.
      if (b[23] != 0x9D || b[24] != 0x01 || b[25] != 0x2A) return null;
      return (_le16(b, 26) & 0x3FFF, _le16(b, 28) & 0x3FFF);
  }
  return null;
}

int _be16(Uint8List b, int o) => (b[o] << 8) | b[o + 1];

int _be32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

int _le24(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16);

int _le32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _le32s(Uint8List b, int o) => _le32(b, o).toSigned(32);
