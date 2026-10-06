// Minimal fragmented-MP4 muxer for one video track (H.264 avc1 or VP9 vp09).
// Each encoded frame becomes one moof+mdat fragment for the lowest possible latency.
(function (global) {
  'use strict';

  function u8(n) { return new Uint8Array(n); }
  function str4(s) { return [s.charCodeAt(0), s.charCodeAt(1), s.charCodeAt(2), s.charCodeAt(3)]; }
  function concat(parts) {
    let len = 0;
    for (const p of parts) len += p.length;
    const out = u8(len);
    let o = 0;
    for (const p of parts) { out.set(p, o); o += p.length; }
    return out;
  }
  function be32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }
  function be16(n) { return [(n >>> 8) & 255, n & 255]; }
  function be64(n) {
    const hi = Math.floor(n / 4294967296), lo = n >>> 0;
    return be32(hi).concat(be32(lo));
  }
  function box(type, ...payload) {
    const body = concat(payload.map(p => (p instanceof Uint8Array ? p : new Uint8Array(p))));
    return concat([new Uint8Array(be32(body.length + 8)), new Uint8Array(str4(type)), body]);
  }
  function fullbox(type, version, flags, ...payload) {
    return box(type, [version, (flags >>> 16) & 255, (flags >>> 8) & 255, flags & 255], ...payload);
  }
  const MATRIX = [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0];

  // codec: 'avc1.xxxxxx' or 'vp09.PP.LL.DD'; description: avcC bytes (H.264 only)
  function initSegment(codec, width, height, timescale, description) {
    const isAvc = codec.startsWith('avc1');
    const brand = isAvc ? 'avc1' : 'vp09';
    const ftyp = box('ftyp', str4('isom'), be32(0x200), str4('isom'), str4('iso6'), str4(brand), str4('mp41'));

    const mvhd = fullbox('mvhd', 0, 0,
      be32(0), be32(0), be32(1000), be32(0),
      be32(0x00010000), be16(0x0100), u8(10), MATRIX, u8(24), be32(2));

    const tkhd = fullbox('tkhd', 0, 3,
      be32(0), be32(0), be32(1), be32(0), be32(0), u8(8),
      be16(0), be16(0), be16(0), be16(0), MATRIX, be32(width << 16), be32(height << 16));

    const mdhd = fullbox('mdhd', 0, 0, be32(0), be32(0), be32(timescale), be32(0), be16(0x55c4), be16(0));
    const hdlr = fullbox('hdlr', 0, 0, be32(0), str4('vide'), u8(12),
      new TextEncoder().encode('VideoHandler\0'));

    let codecBox;
    if (isAvc) {
      codecBox = box('avcC', new Uint8Array(description));
    } else {
      const p = codec.split('.');
      const profile = parseInt(p[1] || '0', 10), level = parseInt(p[2] || '10', 10), depth = parseInt(p[3] || '8', 10);
      // bitDepth(4) | chromaSubsampling(3)=1 (4:2:0) | fullRange(1)=0 ; BT.709 colour
      codecBox = fullbox('vpcC', 1, 0, [profile, level, (depth << 4) | (1 << 1) | 0, 1, 1, 1], be16(0));
    }
    const sampleEntry = box(isAvc ? 'avc1' : 'vp09',
      u8(6), be16(1),                       // reserved, data_reference_index
      be16(0), be16(0), u8(12),             // pre_defined, reserved, pre_defined
      be16(width), be16(height),
      be32(0x00480000), be32(0x00480000), be32(0), be16(1),
      u8(32), be16(0x0018), be16(0xffff),
      codecBox);

    const stbl = box('stbl',
      fullbox('stsd', 0, 0, be32(1), sampleEntry),
      fullbox('stts', 0, 0, be32(0)),
      fullbox('stsc', 0, 0, be32(0)),
      fullbox('stsz', 0, 0, be32(0), be32(0)),
      fullbox('stco', 0, 0, be32(0)));
    const minf = box('minf',
      fullbox('vmhd', 0, 1, be16(0), u8(6)),
      box('dinf', fullbox('dref', 0, 0, be32(1), fullbox('url ', 0, 1))),
      stbl);
    const trak = box('trak', tkhd, box('mdia', mdhd, hdlr, minf));
    const mvex = box('mvex', fullbox('trex', 0, 0, be32(1), be32(1), be32(0), be32(0), be32(0)));
    return concat([ftyp, box('moov', mvhd, trak, mvex)]);
  }

  // One sample per fragment.  decodeTime/duration in track timescale.
  function fragment(seq, decodeTime, duration, data, isKey) {
    const flags = isKey ? 0x02000000 : 0x01010000;
    const build = (dataOffset) => box('moof',
      fullbox('mfhd', 0, 0, be32(seq)),
      box('traf',
        fullbox('tfhd', 0, 0x020000, be32(1)),
        fullbox('tfdt', 1, 0, be64(decodeTime)),
        fullbox('trun', 0, 0x000001 | 0x000100 | 0x000200 | 0x000400,
          be32(1), be32(dataOffset), be32(duration), be32(data.length), be32(flags))));
    const probe = build(0);
    const moof = build(probe.length + 8);
    const mdat = concat([new Uint8Array(be32(data.length + 8)), new Uint8Array(str4('mdat')), data]);
    return concat([moof, mdat]);
  }

  global.Mp4Mux = { initSegment, fragment };
})(typeof self !== 'undefined' ? self : this);
