'use strict';

/*
  The browser's hardware renderer: the PlayStation's primitives drawn by WebGL2 instead of the
  runtime's software rasteriser, under the contract of src/backend/api/backend_c_api.h
  ("hardware drawing") and ADR-0008. The runtime keeps parsing GP0, keeps its VRAM uploads and
  its timing exactly as before; only rasterised pixels change owner. It is a fork in
  presentation, never in emulated state, and headless runs never take it, so the digest is
  untouched.

  Two textures stand for the two things the PlayStation keeps in one memory:

    vramTex  R16UI 1024x512   the emulated VRAM as the runtime wrote it — textures, palettes,
                              uploaded pictures. Refreshed by dirty rectangles.
    fbTex    RGBA8 1024x512   what the picture would be if VRAM held the rendered pixels: every
                              dirty rectangle is copied in from vramTex, every primitive is
                              drawn on top, and the display window is blitted from here.

  Texels are decoded in the fragment shader straight out of vramTex — 4-bit and 8-bit indices
  through their CLUT, 15-bit colour direct, the texture window folded in — so there is no page
  cache to keep coherent and a palette repainted mid-frame is simply read as it is at draw time,
  which is what the hardware did. A batch is flushed before a dirty rectangle is applied, so an
  upload between two draws lands between them.

  Every vertex carries its primitive's texture state — page, depth, CLUT, window, flags and blend
  mode — so a texture or palette change does not end a batch. A game switches those between
  almost every pair of primitives (about 190 times a vblank in Crash Bash's gameplay), and a
  batch per switch cost a draw call and a dozen state calls each; now a vblank is one or two.

  Colour is the PlayStation's: five bits a channel, the primitive's colour cut to five bits before
  it blends (gpu.Gpu modulate, pack555) and the blend on five-bit channels (psx-spx, "Semi
  Transparency"). fbTex stores a channel's k as (k + 1/2) / 32 — eight bits keep it within 1/16 of
  a step — and the screen and toWord read it back as the floor of 32 times it. The half step
  above k is what lets mode 0 floor as the hardware does (see primFs) and lets a black texel
  blend without a negative colour, which a blend clamps. In eight-bit colour Crash Bandicoot:
  Warped's level transition never turned black: it repeats (B + F) >> 1 and B - 1/31 every frame,
  and each loses what the cut and the floor lose.

  Semi-transparency is the PlayStation's four blend equations. Three of them add, and they share
  one GL blend state: the source factor is ONE and the destination factor is the fragment's own
  alpha, so the shader writes (F, 0) for an opaque pixel, (F/2, 1/2) for mode 0, (F, 1) for
  mode 1 and (F/4, 1) for mode 3. Opaque and blending primitives therefore draw in one batch, and
  inside a textured primitive each texel picks its own equation by its bit 15, which is what the
  hardware does. Mode 2 subtracts, which needs a different GL equation: such a primitive is a
  batch of its own, and a textured one is drawn twice — opaque texels, then blending texels — so
  submission order stays exact across overlapping sprites.

  Triangles are scissored to the drawing area (bp_gpu_clip): a double-buffered game's geometry
  reaches past the buffer it draws into, and the software rasteriser clips it there. Rectangles
  are not, as in the software path.

  The mask bit (bit 15 of every VRAM halfword) is the depth buffer: 1.0 where it is set, 0.0
  where not, written by every fragment as gl_FragDepth — a dirty rectangle's copy from the
  halfword, a primitive's pixel the bit the PlayStation would store (psx-spx, "GPU Rendering
  Attributes"): 1 under "set", otherwise the texel's bit 15, and 0 for an untextured primitive.
  Depth is not blended and each fragment writes its own, so a texel's bit reaches VRAM inside one
  draw and submission order stays exact (ADR-0054). Crash Bandicoot: Warped's transition reads
  its frame back as a semi-transparent texture, where only texels with the bit blend: with 0
  written for every texel, as the stencil once had it, nothing blended and the colours broke. The
  stencil serves "check" alone: rebuilt from the depth buffer before a batch that checks, it
  passes only where no bit is set, and a "set" batch that checks sets it as it draws. Keeping the
  old bit instead left stale mask bits under everything drawn: Crash Bandicoot: Warped clears its
  shadow texture with a fill over words whose bit 15 was set, and the texture read back through
  its palette as a hatched rectangle across half the shadow. (That texture is now the runtime's
  to draw, being off screen — ADR-0030 — but a fill still arrives here under mask bits of zero,
  as the hardware ignores them for a fill, and clears the bit the same way.) Anything a game
  reads back from VRAM after drawing sees what was there before the draw, by the ABI's own terms.

  Drawn pixels become texels when a primitive samples them. Games render into VRAM and then use
  what they rendered as a texture — Crash Bandicoot: Warped draws Crash's silhouette off screen
  every frame and lays it on the ground as his shadow, through a 4-bit CLUT. vramTex holds only
  what the runtime wrote, so such a texture read stale words: the shadow was a square. Every
  primitive marks the 16x16 tiles it may have drawn into; a textured primitive whose texels or
  palette lie in a marked tile first has those tiles converted back from fbTex into vramTex as
  15-bit words (bit 15 from the depth buffer) — the value the PlayStation would have stored.

  A VRAM-to-VRAM copy (bp_gpu_copy, ADR-0054) is done here, from fbTex and its mask bits: fbTex
  holds everything emulated VRAM does and what was drawn besides, and a copy out of a buffer on
  screen is a copy of what was drawn there — which emulated VRAM's own copy lacks.

  The picture's resolution is the console's setting (bp_gpu_scale, ADR-0056): fbTex, its depth and
  the copy's scratch are VRAM's size times the scale — half of it, the PlayStation's own, twice,
  three times — and everything drawn into them is drawn at it. Coordinates stay VRAM's everywhere:
  the vertex shader maps the whole of VRAM onto the target whatever its size, and only the viewport,
  the scissor and a copy's texels count target pixels. Textures stay VRAM's too: vramTex is what the
  runtime wrote, and a drawn tile is read back into it at one target pixel a VRAM pixel, the one at
  the VRAM pixel's centre — so what a game draws and then samples (Crash's shadow, a transition's
  frame) is sampled at the PlayStation's resolution, and only what goes to the screen is finer.
*/
function createHardwareGpu(canvas) {
  const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, depth: false,
    stencil: false, preserveDrawingBuffer: false, premultipliedAlpha: false });
  if (!gl) return null;

  // The colour and texture-coordinate bytes are written a word at a time, which puts the first
  // byte lowest only on a little-endian host. That is every host WebGL runs on; anything else
  // gets the software rasteriser rather than swapped colours.
  if (new Uint8Array(new Uint16Array([1]).buffer)[0] !== 1) return null;

  const W = 1024, H = 512;
  // f32 x, f32 y, u8 r g b pad, u8 u v pad pad, u32 page, u32 clut, u32 window
  const VERTEX_WORDS = 7, VERTEX_BYTES = VERTEX_WORDS * 4;
  const MAX_VERTICES = 1 << 17;
  const vertexData = new ArrayBuffer(MAX_VERTICES * VERTEX_BYTES);
  const posView = new Float32Array(vertexData);
  const wordView = new Uint32Array(vertexData);
  const byteView = new Uint8Array(vertexData);
  let vertexCount = 0;

  const TEXTURED = 1, SEMI = 2, RAW = 4;
  let vramWords = null;
  let primitives = 0;

  function compile(type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      throw new Error('shader: ' + gl.getShaderInfoLog(shader));
    }
    return shader;
  }
  function program(vs, fs) {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, fs));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error('link: ' + gl.getProgramInfoLog(p));
    return p;
  }

  // Positions are VRAM coordinates; the framebuffer texture is the whole of VRAM, so clip space
  // is a fixed map. Triangle vertices arrive already shifted by half a pixel (see tri()), so a
  // pixel whose integer corner the PlayStation would test is the pixel whose centre GL tests.
  // The primitive's state arrives packed in three words (see state()) and is unpacked once per
  // vertex into flat varyings — identical at all three vertices, so the provoking one is moot.
  const primVs = `#version 300 es
    layout(location=0) in vec2 aPos;
    layout(location=1) in vec3 aColor;
    layout(location=2) in vec2 aUv;
    layout(location=3) in uvec3 aState;   // page, clut, window
    out vec3 vColor;
    out vec2 vUv;
    flat out ivec4 vPage;                 // texture base x, base y, depth, blend mode
    flat out ivec3 vClut;                 // CLUT x, CLUT y, flags
    flat out ivec4 vWindow;               // u AND, u OR, v AND, v OR
    void main() {
      gl_Position = vec4(aPos.x / 512.0 - 1.0, aPos.y / 256.0 - 1.0, 0.0, 1.0);
      vColor = aColor;
      vUv = aUv;
      uint p = aState.x, c = aState.y, w = aState.z;
      vPage = ivec4(p & 1023u, (p >> 10) & 511u, (p >> 19) & 3u, (p >> 24) & 3u);
      vClut = ivec3(c & 1023u, (c >> 16) & 511u, (p >> 21) & 7u);
      vWindow = ivec4(w & 255u, (w >> 8) & 255u, (w >> 16) & 255u, w >> 24);
    }`;
  const primFs = `#version 300 es
    precision highp float;
    precision highp int;
    precision highp usampler2D;
    uniform usampler2D uVram;
    uniform int uPass;           // 0 every texel, 1 opaque texels only, 2 blending texels only
    uniform int uMaskSet;        // GP0(E6h).0: every pixel written gets the mask bit
    in vec3 vColor;
    in vec2 vUv;
    flat in ivec4 vPage;
    flat in ivec3 vClut;
    flat in ivec4 vWindow;
    out vec4 oColor;
    uint word(int x, int y) { return texelFetch(uVram, ivec2(x & 1023, y & 511), 0).r; }
    void main() {
      int flags = vClut.z;
      bool blending = (flags & 2) != 0;
      bool mask = uMaskSet != 0;
      // The colour the PlayStation writes, five bits a channel, as the software rasteriser makes
      // it (gpu.Gpu modulate, pack555): a texel's five bits widened by a shift, times the vertex
      // colour, shifted down by seven, clamped and cut to five bits; an untextured colour cut to
      // five bits. Without the cut Crash Bandicoot: Warped's level transition, which subtracts
      // a one-texel colour of 15.5/255 every frame, took 15.5/255 where the PlayStation takes
      // 1/31, and darkened twice as fast.
      uvec3 c8 = uvec3(floor(vColor * 255.0 + 0.5));
      uvec3 f;
      if ((flags & 1) != 0) {
        // The texel is the interpolated coordinate floored, as the PlayStation truncates its
        // own — but where the exact value is a whole number the interpolation lands a hair
        // below it about half the time, and floor() then takes the texel before: a seam of
        // wrong or transparent texels along polygon edges, the lines across floors and models.
        // Nudged up by 1/1024 (any bias from 1e-4 to 3e-3 measured the same), mismatches
        // against the software rasteriser fall by 90-96 %; nudged down, they grow tenfold.
        int tu = (int(floor(vUv.x + (1.0 / 1024.0))) & vWindow.x) | vWindow.y;
        int tv = (int(floor(vUv.y + (1.0 / 1024.0))) & vWindow.z) | vWindow.w;
        int row = vPage.y + tv;
        uint t;
        if (vPage.z == 2) {
          t = word(vPage.x + tu, row);
        } else if (vPage.z == 1) {
          uint w = word(vPage.x + (tu >> 1), row);
          t = word(vClut.x + int((w >> uint((tu & 1) << 3)) & 255u), vClut.y);
        } else {
          uint w = word(vPage.x + (tu >> 2), row);
          t = word(vClut.x + int((w >> uint((tu & 3) << 2)) & 15u), vClut.y);
        }
        if (t == 0u) discard;
        // The texel's bit 15: what it blends by, and the mask bit its pixel keeps.
        mask = mask || (t & 0x8000u) != 0u;
        blending = blending && (t & 0x8000u) != 0u;
        if (uPass == 1 && blending) discard;
        if (uPass == 2 && !blending) discard;
        uvec3 t5 = uvec3(t & 31u, (t >> 5) & 31u, (t >> 10) & 31u);
        f = (flags & 4) != 0 ? t5 : min(((t5 << 3u) * c8) >> 7u, uvec3(255u)) >> 3u;
      } else {
        f = c8 >> 3u;
      }
      // fbTex holds a five-bit channel k as (k + 1/2) / 32 (see the header). The blend state is
      // src * ONE + dst * SRC_ALPHA: alpha is the destination's weight and the colour is
      // pre-scaled by the source's. Mode 2 is drawn under a subtracting state of its own, for
      // which (F, 1) is what it needs. Modes 1-3 move in whole steps, as on the PlayStation (mode
      // 3 adds F >> 2). Mode 0 is (B + F) >> 1 there, which a blend cannot floor: (B + F) / 2 with
      // F half a step low lands a quarter step under the floor for an even sum and a quarter
      // over it for an odd one, inside the step either way.
      if (!blending) oColor = vec4((vec3(f) + 0.5) / 32.0, 0.0);
      else if (vPage.w == 0) oColor = vec4(vec3(f) / 64.0, 0.5);
      else if (vPage.w == 3) oColor = vec4(vec3(f >> 2u) / 32.0, 1.0);
      else oColor = vec4(vec3(f) / 32.0, 1.0);
      gl_FragDepth = mask ? 1.0 : 0.0;
    }`;
  // A quad from one texture to the current target, with a source rectangle in texels.
  const quadVs = `#version 300 es
    layout(location=0) in vec2 aPos;    // 0..1
    uniform vec4 uDst;                  // x, y, w, h in clip units of the target
    uniform vec4 uSrc;                  // x, y, w, h in texels of the source
    out vec2 vTexel;
    void main() {
      gl_Position = vec4(uDst.x + aPos.x * uDst.z, uDst.y + aPos.y * uDst.w, 0.0, 1.0);
      vTexel = uSrc.xy + aPos * uSrc.zw;
    }`;
  // VRAM halfwords as colour: the copy of a dirty rectangle into the framebuffer texture.
  const copy15Fs = `#version 300 es
    precision highp float;
    precision highp int;
    precision highp usampler2D;
    uniform usampler2D uVram;
    uniform int uMaskedOnly;     // unused: the mask bit is written as depth in the one pass
    in vec2 vTexel;
    out vec4 oColor;
    void main() {
      uint t = texelFetch(uVram, ivec2(int(floor(vTexel.x)) & 1023, int(floor(vTexel.y)) & 511), 0).r;
      oColor = vec4((vec3(float(t & 31u), float((t >> 5) & 31u), float((t >> 10) & 31u)) + 0.5) / 32.0, 1.0);
      gl_FragDepth = (t & 0x8000u) != 0u ? 1.0 : 0.0;
    }`;
  // A copy's pixels from the scratch target, with their mask bits (the scratch depth), under
  // "set" (bp_gpu_copy).
  const copyFbFs = `#version 300 es
    precision highp float;
    uniform sampler2D uFrame;
    uniform sampler2D uDepth;
    uniform int uMaskSet;
    in vec2 vTexel;
    out vec4 oColor;
    void main() {
      ivec2 p = ivec2(floor(vTexel));
      oColor = vec4(texelFetch(uFrame, p, 0).rgb, 1.0);
      gl_FragDepth = (uMaskSet != 0 || texelFetch(uDepth, p, 0).r > 0.5) ? 1.0 : 0.0;
    }`;
  // Nothing but the stencil test's side effect (the stencil rebuilt from the mask bits).
  const noneFs = `#version 300 es
    precision highp float;
    out vec4 oColor;
    void main() { oColor = vec4(0.0); }`;
  // The framebuffer texture to the screen, opaque whatever its alpha says: the canvas is
  // unpremultiplied, so an alpha below one would darken the pixel on the page.
  const blitFs = `#version 300 es
    precision highp float;
    uniform sampler2D uFrame;
    in vec2 vTexel;
    out vec4 oColor;
    void main() {
      // A channel's five bits out of the (k + 1/2) / 32 the framebuffer texture holds, widened
      // as the PlayStation's video output does.
      vec3 k = clamp(floor(texture(uFrame, vTexel / vec2(1024.0, 512.0)).rgb * 32.0), 0.0, 31.0);
      oColor = vec4(k / 31.0, 1.0);
    }`;
  // 24-bit rows straight out of VRAM: three bytes a pixel from byte offset src_x*2 of each row,
  // the layout MDEC video uses. Read through the halfword texture.
  const present24Fs = `#version 300 es
    precision highp float;
    precision highp int;
    precision highp usampler2D;
    uniform usampler2D uVram;
    uniform int uSrcX;
    in vec2 vTexel;
    out vec4 oColor;
    uint byteAt(int b, int y) {
      uint w = texelFetch(uVram, ivec2((b >> 1) & 1023, y & 511), 0).r;
      return (b & 1) == 0 ? (w & 255u) : (w >> 8);
    }
    void main() {
      int x = int(floor(vTexel.x));
      int y = int(floor(vTexel.y));
      int b = uSrcX * 2 + x * 3;
      oColor = vec4(float(byteAt(b, y)), float(byteAt(b + 1, y)), float(byteAt(b + 2, y)), 255.0) / 255.0;
    }`;

  // Rendered colour back to a VRAM halfword, drawn into vramTex over tiles primitives drew into.
  // A channel holds (k + 1/2) / 32 (see the header), within 1/16 of a step after the eight-bit
  // store and within a quarter step more after a mode 0 blend: the floor of 32 times it is k.
  // Bit 15 is read from the depth texture, in the same pass. At a scale the word is the target
  // pixel at the VRAM pixel's centre.
  const toWordFs = `#version 300 es
    precision highp float;
    precision highp int;
    uniform sampler2D uFrame;
    uniform sampler2D uDepth;
    uniform vec2 uScale;
    in vec2 vTexel;
    out uvec4 oWord;
    void main() {
      ivec2 q = ivec2(int(floor(vTexel.x)) & 1023, int(floor(vTexel.y)) & 511);
      ivec2 p = ivec2(floor((vec2(q) + 0.5) * uScale));
      vec3 c = texelFetch(uFrame, p, 0).rgb;
      uvec3 v = uvec3(clamp(floor(c * 32.0), 0.0, 31.0));
      uint mask = texelFetch(uDepth, p, 0).r > 0.5 ? 0x8000u : 0u;
      oWord = uvec4(v.r | (v.g << 5u) | (v.b << 10u) | mask, 0u, 0u, 0u);
    }`;

  const primProgram = program(primVs, primFs);
  const copyProgram = program(quadVs, copy15Fs);
  const blitProgram = program(quadVs, blitFs);
  const present24Program = program(quadVs, present24Fs);
  const toWordProgram = program(quadVs, toWordFs);
  const copyFbProgram = program(quadVs, copyFbFs);
  const noneProgram = program(quadVs, noneFs);
  const U = (p, name) => gl.getUniformLocation(p, name);
  const prim = { pass: U(primProgram, 'uPass'), maskSet: U(primProgram, 'uMaskSet') };
  const quad = (p) => ({ dst: U(p, 'uDst'), src: U(p, 'uSrc'), srcX: U(p, 'uSrcX'),
    maskedOnly: U(p, 'uMaskedOnly'), maskBit: U(p, 'uMaskBit') });
  const copyU = quad(copyProgram), blitU = quad(blitProgram), present24U = quad(present24Program);
  const toWordU = Object.assign(quad(toWordProgram), { scale: U(toWordProgram, 'uScale') });
  const copyFbU = Object.assign(quad(copyFbProgram), { maskSet: U(copyFbProgram, 'uMaskSet') });
  const noneU = quad(noneProgram);
  // Every sampler reads unit 0, which a program keeps from here on; set once, not per draw.
  for (const [p, name] of [[primProgram, 'uVram'], [copyProgram, 'uVram'], [blitProgram, 'uFrame'],
      [present24Program, 'uVram'], [toWordProgram, 'uFrame'], [copyFbProgram, 'uFrame']]) {
    gl.useProgram(p);
    gl.uniform1i(U(p, name), 0);
  }
  gl.useProgram(copyFbProgram);
  gl.uniform1i(U(copyFbProgram, 'uDepth'), 1);
  gl.useProgram(toWordProgram);
  gl.uniform1i(U(toWordProgram, 'uDepth'), 1);
  gl.uniform2f(toWordU.scale, 1, 1);

  // The scale the targets are drawn at (ADR-0056): FW x FH in all, SX x SY target pixels a VRAM
  // pixel (the scale, as the rounding of FW and FH leaves it; S as it was asked for).
  let S = 1, SX = 1, SY = 1, FW = W, FH = H;

  function texture(format, w, h) {
    const t = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texStorage2D(gl.TEXTURE_2D, 1, format, w, h);
    return t;
  }

  const vramTex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, vramTex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R16UI, W, H);
  // Uploads are rows of VRAM, 1024 halfwords apart; the only pixel transfer this context makes.
  gl.pixelStorei(gl.UNPACK_ROW_LENGTH, W);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);

  let fbTex = texture(gl.RGBA8, FW, FH);
  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fbTex, 0);
  // The mask bits (depth) and the "check" stencil: a texture, so that a copy can read them.
  let fbDepth = texture(gl.DEPTH24_STENCIL8, FW, FH);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.TEXTURE_2D, fbDepth, 0);
  gl.clearColor(0, 0, 0, 1);
  gl.clearStencil(0);
  gl.clearDepth(0);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  // vramTex as a target, for drawn tiles turned back into halfwords: colour only, the mask bits
  // read from fbDepth as a texture. Attached again before every use (syncDrawn).
  const wordFbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, wordFbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, vramTex, 0);
  // A copy's scratch (bp_gpu_copy): what its source held, colour and mask bits, before the copy
  // writes — source and destination may overlap. Filled and read by drawing, as everything else
  // here is: the mask bits are read from the depth texture by the shader that writes them.
  let copyTex = texture(gl.RGBA8, FW, FH);
  let copyDepth = texture(gl.DEPTH24_STENCIL8, FW, FH);
  const copyFbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, copyFbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, copyTex, 0);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.TEXTURE_2D, copyDepth, 0);
  gl.bindFramebuffer(gl.FRAMEBUFFER, null);

  const primVao = gl.createVertexArray();
  const primVbo = gl.createBuffer();
  gl.bindVertexArray(primVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, primVbo);
  gl.bufferData(gl.ARRAY_BUFFER, vertexData.byteLength, gl.STREAM_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, VERTEX_BYTES, 0);
  gl.enableVertexAttribArray(1);
  gl.vertexAttribPointer(1, 3, gl.UNSIGNED_BYTE, true, VERTEX_BYTES, 8);
  gl.enableVertexAttribArray(2);
  // Texture coordinates as signed halfwords: a polygon's are 0-255, a sprite's run past 255 or
  // below 0 where it wraps (sprite()), and the shader takes them modulo 256.
  gl.vertexAttribPointer(2, 2, gl.SHORT, false, VERTEX_BYTES, 12);
  gl.enableVertexAttribArray(3);
  gl.vertexAttribIPointer(3, 3, gl.UNSIGNED_INT, VERTEX_BYTES, 16);

  const quadVao = gl.createVertexArray();
  const quadVbo = gl.createBuffer();
  gl.bindVertexArray(quadVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, quadVbo);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 1]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.bindVertexArray(null);

  // ---- state and batches ----------------------------------------------------------------------
  // What a batch's GL state depends on: its blend equation, its clip and its mask bits. The
  // texture state is per vertex and ends nothing.
  const ADD = 0;            // opaque and blend modes 0, 1, 3: one state for all of them
  const SUBTRACT = 1;       // mode 2, untextured: every pixel subtracts
  const SUBTRACT_TEX = 2;   // mode 2, textured: opaque texels, then subtracting texels
  let sTx = 0, sTy = 0, sDepth = 0, sCx = 0, sCy = 0, sSemiMode = 0, sFlags = 0, sWindow = 0;
  let pageWord = 0, clutWord = 0, windowWord = 0xFF00FF;   // no window: AND 255, OR 0
  let kind = ADD;
  let clipX0 = 0, clipY0 = 0, clipX1 = 1023, clipY1 = 511;
  let maskSet = 0, maskCheck = 0;
  // Batch records are pooled: a frame reuses the same objects in the same order, so a
  // steady frame allocates nothing. Hundreds of fresh records a frame were a steady minor-GC
  // load, which a phone notices.
  const batches = [];
  let batchCount = 0;
  let open = null;          // the batch primitives are being appended to, or null

  function mask(setBit, checkBit) {
    if (maskSet === setBit && maskCheck === checkBit) return;
    maskSet = setBit; maskCheck = checkBit;
    open = null;
  }

  function clip(x0, y0, x1, y1) {
    if (clipX0 === x0 && clipY0 === y0 && clipX1 === x1 && clipY1 === y1) return;
    clipX0 = x0; clipY0 = y0; clipX1 = x1; clipY1 = y1;
    open = null;
  }

  // The drawing offset (the last two arguments) is already in the coordinates the runtime
  // sends, so it changes nothing here.
  function state(tx, ty, depth, cx, cy, semiMode, flags, window, _dx, _dy) {
    if (sTx === tx && sTy === ty && sDepth === depth && sCx === cx && sCy === cy
        && sSemiMode === semiMode && sFlags === flags && sWindow === window) return;
    sTx = tx; sTy = ty; sDepth = depth; sCx = cx; sCy = cy;
    sSemiMode = semiMode; sFlags = flags; sWindow = window;
    pageWord = (tx & 1023) | ((ty & 511) << 10) | ((depth & 3) << 19) | ((flags & 7) << 21)
      | ((semiMode & 3) << 24);
    clutWord = (cx & 1023) | ((cy & 511) << 16);
    const mx = window & 31, my = (window >> 5) & 31;
    windowWord = ((~(mx << 3)) & 255) | (((((window >> 10) & 31) & mx) << 3) << 8)
      | (((~(my << 3)) & 255) << 16) | (((((window >> 15) & 31) & my) << 3) << 24);
    kind = (flags & SEMI) === 0 || semiMode !== 2 ? ADD : (flags & TEXTURED) !== 0 ? SUBTRACT_TEX : SUBTRACT;
  }

  function batchFor(count, clipped) {
    if (vertexCount + count > MAX_VERTICES) flush();
    // A textured, subtracting primitive is its own batch: it draws in two passes, and the
    // passes of one primitive must not straddle another's. A batch also has one clip setting.
    if (open === null || kind === SUBTRACT_TEX || open.kind !== kind || open.clipped !== clipped) {
      let b = batches[batchCount];
      if (b === undefined) {
        b = { start: 0, count: 0, kind: ADD, clipped: false, maskSet: 0, maskCheck: 0,
          sx: 0, sy: 0, sw: 0, sh: 0 };
        batches[batchCount] = b;
      }
      batchCount++;
      b.start = vertexCount; b.count = 0; b.kind = kind; b.clipped = clipped;
      b.maskSet = maskSet; b.maskCheck = maskCheck;
      b.sx = clipX0; b.sy = clipY0; b.sw = clipX1 - clipX0 + 1; b.sh = clipY1 - clipY0 + 1;
      open = b;
    }
    open.count += count;
    const at = vertexCount;
    vertexCount += count;
    return at;
  }

  // ---- drawn tiles: render to texture (see the header) ------------------------------------------
  // The 16x16 tiles of VRAM a primitive may have drawn into since vramTex last held them. A row
  // of 64 tiles is two words: bit n of the first for tile n, of the second for tile 32 + n.
  const drawnLo = new Uint32Array(H >> 4), drawnHi = new Uint32Array(H >> 4);
  let syncs = 0;
  let copies = 0;

  function upTo(n) { return n < 0 ? 0 : (n >= 31 ? -1 : (1 << (n + 1)) - 1); }
  // Tiles tx0..tx1 (0 <= tx0 <= tx1 <= 63) as the two words of a row.
  function spanLo(tx0, tx1) { return tx0 > 31 ? 0 : upTo(tx1 > 31 ? 31 : tx1) & ~upTo(tx0 - 1); }
  function spanHi(tx0, tx1) { return tx1 < 32 ? 0 : upTo(tx1 - 32) & ~upTo((tx0 > 32 ? tx0 : 32) - 33); }

  /** Pixels x0..x1, y0..y1 (inclusive) were drawn; what lies outside VRAM was clipped by GL. */
  function markDrawn(x0, y0, x1, y1) {
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > W - 1) x1 = W - 1;
    if (y1 > H - 1) y1 = H - 1;
    if (x0 > x1 || y0 > y1) return;
    const lo = spanLo(x0 >> 4, x1 >> 4), hi = spanHi(x0 >> 4, x1 >> 4);
    for (let ty = y0 >> 4, end = y1 >> 4; ty <= end; ty++) { drawnLo[ty] |= lo; drawnHi[ty] |= hi; }
  }

  /** vramTex was written under this rectangle: tiles wholly inside it hold what fbTex does. */
  function markClean(x, y, w, h) {
    const tx0 = (x + 15) >> 4, tx1 = ((x + w) >> 4) - 1, ty0 = (y + 15) >> 4, ty1 = ((y + h) >> 4) - 1;
    if (tx0 > tx1 || ty0 > ty1) return;
    const lo = ~spanLo(tx0, tx1), hi = ~spanHi(tx0, tx1);
    for (let ty = ty0; ty <= ty1; ty++) { drawnLo[ty] &= lo; drawnHi[ty] &= hi; }
  }

  /**
    A primitive is about to read VRAM words x0..x1, y0..y1 (inclusive, inside VRAM): the tiles
    among them that primitives drew into are converted from fbTex into vramTex first, after
    everything queued so far is drawn. The whole tile-aligned rectangle is converted — a tile
    nothing drew into converts to the halfwords it already holds.
  **/
  function syncDrawn(x0, y0, x1, y1) {
    const tx0 = x0 >> 4, tx1 = x1 >> 4, ty0 = y0 >> 4, ty1 = y1 >> 4;
    const lo = spanLo(tx0, tx1), hi = spanHi(tx0, tx1);
    let any = false;
    for (let ty = ty0; ty <= ty1 && !any; ty++) any = (drawnLo[ty] & lo) !== 0 || (drawnHi[ty] & hi) !== 0;
    if (!any) return;
    flush();
    const px = tx0 << 4, py = ty0 << 4, pw = (tx1 - tx0 + 1) << 4, ph = (ty1 - ty0 + 1) << 4;
    gl.bindFramebuffer(gl.FRAMEBUFFER, wordFbo);
    // vramTex detached and attached anew each time. ANGLE on Metal (Chrome 152, an Apple GPU)
    // gives a texture fresh storage when it is uploaded to while the GPU may still read it, and a
    // framebuffer that had it attached keeps drawing into the old storage: after a palette upload
    // the words converted here went nowhere, and primitives sampled what vramTex held before.
    // Crash Bandicoot: Warped's attract loop ends its second demo with a transition 40 frames
    // after such an upload, and it halved to black at once instead of turning (verified: a word
    // written here read back unchanged until the attachment was renewed, and right after it was).
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, null, 0);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, vramTex, 0);
    gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.STENCIL_TEST);
    gl.disable(gl.DEPTH_TEST);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, fbDepth);
    gl.activeTexture(gl.TEXTURE0);
    quadDraw(toWordProgram, toWordU, fbTex, px, py, pw, ph, W, H, px, py, pw, ph, false);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, null);
    gl.activeTexture(gl.TEXTURE0);
    for (let ty = ty0; ty <= ty1; ty++) { drawnLo[ty] &= ~lo; drawnHi[ty] &= ~hi; }
    syncs++;
  }

  // syncDrawn over a run of words that may pass the right edge of VRAM, where reads wrap.
  function syncRow(x0, x1, y0, y1) {
    if (x1 <= W - 1) { syncDrawn(x0, y0, x1, y1); return; }
    syncDrawn(x0, y0, W - 1, y1);
    syncDrawn(0, y0, (x1 & (W - 1)) < x0 ? x1 & (W - 1) : x0 - 1, y1);
  }

  /** A textured primitive with these texture coordinates reads its texels and palette from here. */
  function sampled(u0, v0, u1, v1, u2, v2) {
    let umin = 0, umax = 255, vmin = 0, vmax = 255;
    if (windowWord === 0xFF00FF) {   // no texture window: the coordinates are the texels
      umin = Math.min(u0, u1, u2) & 255; umax = Math.max(u0, u1, u2) & 255;
      vmin = Math.min(v0, v1, v2) & 255; vmax = Math.max(v0, v1, v2) & 255;
    }
    const shift = sDepth === 0 ? 2 : (sDepth === 1 ? 1 : 0);
    const y0 = (sTy + vmin) & (H - 1), y1 = (sTy + vmax) & (H - 1);
    if (y0 <= y1) syncRow(sTx + (umin >> shift), sTx + (umax >> shift), y0, y1);
    else {
      syncRow(sTx + (umin >> shift), sTx + (umax >> shift), y0, H - 1);
      syncRow(sTx + (umin >> shift), sTx + (umax >> shift), 0, y1);
    }
    if (sDepth < 2) syncRow(sCx, sCx + (sDepth === 0 ? 15 : 255), sCy, sCy);
  }

  function vertex(i, x, y, bgr, u, v) {
    const w = i * VERTEX_WORDS;
    posView[w] = x;
    posView[w + 1] = y;
    wordView[w + 2] = bgr;                        // r g b, then a byte the attribute ignores
    wordView[w + 3] = (u & 0xFFFF) | ((v & 0xFFFF) << 16);
    wordView[w + 4] = pageWord;
    wordView[w + 5] = clutWord;
    wordView[w + 6] = windowWord;
  }

  function tri(x0, y0, c0, u0, v0, x1, y1, c1, u1, v1, x2, y2, c2, u2, v2) {
    // Before it is queued: what it samples must already hold what was drawn there.
    if ((sFlags & TEXTURED) !== 0) sampled(u0, v0, u1, v1, u2, v2);
    const at = batchFor(3, true);
    vertex(at, x0 + 0.5, y0 + 0.5, c0, u0, v0);
    vertex(at + 1, x1 + 0.5, y1 + 0.5, c1, u1, v1);
    vertex(at + 2, x2 + 0.5, y2 + 0.5, c2, u2, v2);
    primitives++;
    // Its bounding box, inside the drawing area it is scissored to.
    const bx0 = Math.max(Math.min(x0, x1, x2), clipX0), bx1 = Math.min(Math.max(x0, x1, x2), clipX1);
    const by0 = Math.max(Math.min(y0, y1, y2), clipY0), by1 = Math.min(Math.max(y0, y1, y2), clipY1);
    markDrawn(bx0, by0, bx1, by1);
  }

  /**
    A textured rectangle (bp_gpu_sprite), already clipped to the drawing area: texel u, v at x, y
    and the next one a pixel to the right and down — the one before under flip's bit 0 (x) and bit
    1 (y). Two triangles whose coordinates run on past 255 or below 0 where the sprite wraps, as
    the shader takes them modulo 256 through the window's AND. Unlike tri()'s, the corners are not
    shifted half a pixel: a texel's edges are the pixel's, coordinate u + i from the left edge of
    pixel i to its right one (u + 1 - i down to u - i under a flip), so wherever a target pixel's
    centre falls inside a VRAM pixel — at any scale (ADR-0056) — it takes that pixel's texel.
  **/
  function sprite(x, y, w, h, u, v, bgr, flip) {
    const fx = (flip & 1) !== 0, fy = (flip & 2) !== 0;
    const ul = fx ? u + 1 : u, ur = fx ? u + 1 - w : u + w;
    const vt = fy ? v + 1 : v, vb = fy ? v + 1 - h : v + h;
    if ((sFlags & TEXTURED) !== 0) {
      // The texels it reads, every one of a row or column it wraps around.
      let u0 = fx ? u - w + 1 : u, u1 = fx ? u : u + w - 1;
      let v0 = fy ? v - h + 1 : v, v1 = fy ? v : v + h - 1;
      if (u0 < 0 || u1 > 255) { u0 = 0; u1 = 255; }
      if (v0 < 0 || v1 > 255) { v0 = 0; v1 = 255; }
      sampled(u0, v0, u1, v1, u0, v0);
    }
    const at = batchFor(6, false);
    const x1 = x + w, y1 = y + h;
    vertex(at, x, y, bgr, ul, vt); vertex(at + 1, x1, y, bgr, ur, vt); vertex(at + 2, x, y1, bgr, ul, vb);
    vertex(at + 3, x, y1, bgr, ul, vb); vertex(at + 4, x1, y, bgr, ur, vt); vertex(at + 5, x1, y1, bgr, ur, vb);
    primitives++;
    markDrawn(x, y, x1 - 1, y1 - 1);
  }

  function rect(x, y, w, h, bgr) {
    const at = batchFor(6, false);
    const x1 = x + w, y1 = y + h;
    vertex(at, x, y, bgr, 0, 0); vertex(at + 1, x1, y, bgr, 0, 0); vertex(at + 2, x, y1, bgr, 0, 0);
    vertex(at + 3, x, y1, bgr, 0, 0); vertex(at + 4, x1, y, bgr, 0, 0); vertex(at + 5, x1, y1, bgr, 0, 0);
    primitives++;
    markDrawn(x, y, x1 - 1, y1 - 1);
  }

  // GL state as last set inside flush(), so a run of batches that agree issues nothing between
  // draws. Reset at the start of every flush: refresh() and present() change it in between.
  let glScissor = -1, glScissorX = 0, glScissorY = 0, glScissorW = 0, glScissorH = 0;
  let glStencil = -1, glSubtract = -1, glPass = -1;

  function setScissor(b) {
    if (b.clipped && b.sw > 0 && b.sh > 0) {
      if (glScissor !== 1) { gl.enable(gl.SCISSOR_TEST); glScissor = 1; }
      if (glScissorX !== b.sx || glScissorY !== b.sy || glScissorW !== b.sw || glScissorH !== b.sh) {
        // The drawing area in target pixels: every one a VRAM pixel inside it covers, even in part.
        const x0 = Math.floor(b.sx * SX), y0 = Math.floor(b.sy * SY);
        gl.scissor(x0, y0, Math.ceil((b.sx + b.sw) * SX) - x0, Math.ceil((b.sy + b.sh) * SY) - y0);
        glScissorX = b.sx; glScissorY = b.sy; glScissorW = b.sw; glScissorH = b.sh;
      }
    } else if (glScissor !== 0) {
      gl.disable(gl.SCISSOR_TEST); glScissor = 0;
    }
  }

  // The mask bits are the depth buffer (see the header); the stencil holds them only for "check",
  // rebuilt from the depth buffer when something has been written since.
  let stencilStale = true;
  let glMaskSet = -1;

  /** The stencil from the mask bits: 1 where the depth buffer holds a set bit (a quad at 0.5 passes
   *  LESS only where the stored 1.0 is), 0 elsewhere. Leaves fbo bound, blending and the scissor
   *  off, the depth test ALWAYS with writes on, and the stencil test enabled. */
  function stencilFromDepth() {
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, FW, FH);
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    gl.colorMask(false, false, false, false);
    gl.enable(gl.DEPTH_TEST);
    gl.depthMask(false);
    gl.depthFunc(gl.LESS);
    gl.enable(gl.STENCIL_TEST);
    gl.stencilFunc(gl.ALWAYS, 1, 0xFF);
    gl.stencilOp(gl.ZERO, gl.ZERO, gl.REPLACE);
    quadDraw(noneProgram, noneU, vramTex, 0, 0, W, H, W, H, 0, 0, W, H, false);
    gl.colorMask(true, true, true, true);
    gl.depthMask(true);
    gl.depthFunc(gl.ALWAYS);
    stencilStale = false;
  }

  // "check": draw only where no mask bit is set; under "set" the stencil takes what is drawn as it
  // goes (incrementing, so the check's reference of zero needs no second value). The mask bit
  // itself every fragment writes as depth (uMaskSet and the texel's bit 15).
  function setMask(b) {
    if (glMaskSet !== b.maskSet) { gl.uniform1i(prim.maskSet, b.maskSet); glMaskSet = b.maskSet; }
    if (!b.maskCheck) {
      if (glStencil !== 0) { gl.disable(gl.STENCIL_TEST); glStencil = 0; }
      return;
    }
    if (stencilStale) {
      stencilFromDepth();
      gl.useProgram(primProgram);
      gl.bindVertexArray(primVao);
      gl.enable(gl.BLEND);
      glScissor = -1; glSubtract = -1; glStencil = -1;
      setScissor(b);
    }
    const s = b.maskSet ? 2 : 1;
    if (glStencil === s) return;
    gl.enable(gl.STENCIL_TEST);
    gl.stencilFunc(gl.EQUAL, 0, 0xFF);
    gl.stencilOp(gl.KEEP, gl.KEEP, b.maskSet ? gl.INCR : gl.KEEP);
    glStencil = s;
  }

  function setSubtract(on) {
    if (glSubtract === on) return;
    // Alpha is the destination's own under both states, so the framebuffer texture's stays at
    // the 1 that clearing and every upload's copy put there. The shader's alpha is a blend
    // weight, not coverage; had it been stored, dst - src = 0 under the subtracting state, and
    // the page composites an unpremultiplied canvas by multiplying through its alpha — every
    // pixel a subtracting primitive had touched turned black, and stayed black, since no later
    // draw writes alpha any more.
    if (on) {
      gl.blendEquationSeparate(gl.FUNC_REVERSE_SUBTRACT, gl.FUNC_ADD);
      gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE);
    } else {
      gl.blendEquation(gl.FUNC_ADD);
      gl.blendFuncSeparate(gl.ONE, gl.SRC_ALPHA, gl.ZERO, gl.ONE);
    }
    glSubtract = on;
  }

  function setPass(pass) {
    if (glPass === pass) return;
    gl.uniform1i(prim.pass, pass);
    glPass = pass;
  }

  /** Draw every queued primitive into the framebuffer texture, in submission order. */
  function flush() {
    if (batchCount === 0) return;
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, FW, FH);
    gl.useProgram(primProgram);
    gl.bindVertexArray(primVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, primVbo);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, byteView, 0, vertexCount * VERTEX_BYTES);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, vramTex);
    gl.disable(gl.STENCIL_TEST);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.ALWAYS);
    gl.depthMask(true);
    gl.enable(gl.BLEND);
    glScissor = -1; glScissorW = -1; glStencil = 0; glSubtract = -1; glPass = -1; glMaskSet = -1;
    for (let i = 0; i < batchCount; i++) {
      const b = batches[i];
      setScissor(b);
      setMask(b);
      if (b.kind === SUBTRACT_TEX) {
        setSubtract(0); setPass(1);
        gl.drawArrays(gl.TRIANGLES, b.start, b.count);
        setSubtract(1); setPass(2);
      } else {
        setSubtract(b.kind === SUBTRACT ? 1 : 0); setPass(0);
      }
      gl.drawArrays(gl.TRIANGLES, b.start, b.count);
      stencilStale = true;
    }
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.STENCIL_TEST);
    gl.disable(gl.DEPTH_TEST);
    batchCount = 0;
    open = null;
    vertexCount = 0;
  }

  /** A rectangle of texels from one texture onto the current target, both in pixels. */
  function quadDraw(prog, u, tex, dstX, dstY, dstW, dstH, targetW, targetH, srcX, srcY, srcW, srcH, flipY) {
    gl.useProgram(prog);
    gl.bindVertexArray(quadVao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    const cx = dstX / targetW * 2 - 1, cw = dstW / targetW * 2;
    const cy = flipY ? 1 - dstY / targetH * 2 : dstY / targetH * 2 - 1;
    const ch = flipY ? -dstH / targetH * 2 : dstH / targetH * 2;
    gl.uniform4f(u.dst, cx, cy, cw, ch);
    gl.uniform4f(u.src, srcX, srcY, srcW, srcH);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  /** Refresh vramTex and fbTex under one rectangle that does not cross the VRAM edge. */
  function refresh(x, y, w, h) {
    gl.bindTexture(gl.TEXTURE_2D, vramTex);
    // Only the span the rectangle's rows occupy, not the whole of VRAM with skip parameters:
    // a browser that runs WebGL in another process (Safari) may copy the entire view it is
    // handed across that boundary, a megabyte for a sixteen-texel palette.
    gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RED_INTEGER, gl.UNSIGNED_SHORT,
      vramWords.subarray(y * W + x, (y + h - 1) * W + x + w));
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, FW, FH);
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    // The colour, and each halfword's bit 15 as depth: the mask bits an upload carried are the
    // depth buffer's, exactly as the software path left them in VRAM.
    gl.disable(gl.STENCIL_TEST);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.ALWAYS);
    gl.depthMask(true);
    gl.useProgram(copyProgram);
    gl.uniform1i(copyU.maskedOnly, 0);
    quadDraw(copyProgram, copyU, vramTex, x, y, w, h, W, H, x, y, w, h, false);
    gl.disable(gl.DEPTH_TEST);
    stencilStale = true;
    markClean(x, y, w, h);
  }

  /** GP0(80h) (bp_gpu_copy, ADR-0054): w x h of fbTex and its mask bits from (sx, sy) to (dx, dy),
   *  both wrapping at VRAM's edges as the PlayStation's copy does, under the mask bits — "check"
   *  keeps a pixel whose bit is set, "set" sets the bit of every pixel written. fbTex holds what
   *  emulated VRAM does and what was drawn besides, so this is the copy of a buffer on screen
   *  too, which emulated VRAM's own copy lacks. */
  function copy(sx, sy, dx, dy, w, h, _changed) {
    if (vramWords === null) return;
    flush();
    sx &= W - 1; sy &= H - 1; dx &= W - 1; dy &= H - 1;
    if (w <= 0 || h <= 0) return;
    if (w > W) w = W;
    if (h > H) h = H;
    // Pieces where neither rectangle wraps: the offsets at which either crosses an edge.
    const cuts = (a, b, n, size) => {
      const c = [0];
      for (const at of [size - a, size - b]) if (at > 0 && at < n && c.indexOf(at) < 0) c.push(at);
      c.sort((p, q) => p - q);
      c.push(n);
      return c;
    };
    const xs = cuts(sx, dx, w, W), ys = cuts(sy, dy, h, H);
    for (let j = 0; j + 1 < ys.length; j++) {
      for (let i = 0; i + 1 < xs.length; i++) {
        copyPiece((sx + xs[i]) & (W - 1), (sy + ys[j]) & (H - 1), (dx + xs[i]) & (W - 1),
          (dy + ys[j]) & (H - 1), xs[i + 1] - xs[i], ys[j + 1] - ys[j]);
      }
    }
  }

  function copyPiece(sx, sy, dx, dy, w, h) {
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.BLEND);
    // The source, colour and mask bits, into the scratch at the same place: drawn from fbTex and
    // its depth, which only fbo has attached.
    gl.bindFramebuffer(gl.FRAMEBUFFER, copyFbo);
    gl.viewport(0, 0, FW, FH);
    gl.disable(gl.STENCIL_TEST);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.ALWAYS);
    gl.depthMask(true);
    gl.useProgram(copyFbProgram);
    gl.uniform1i(copyFbU.maskSet, 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, fbDepth);
    gl.activeTexture(gl.TEXTURE0);
    quadDraw(copyFbProgram, copyFbU, fbTex, sx, sy, w, h, W, H, sx * SX, sy * SY, w * SX, h * SY, false);
    // Then from the scratch to the destination, under the mask bits.
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, null);
    gl.activeTexture(gl.TEXTURE0);
    if (maskCheck) stencilFromDepth();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, FW, FH);
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    if (maskCheck) {
      gl.enable(gl.STENCIL_TEST);
      gl.stencilFunc(gl.EQUAL, 0, 0xFF);
      gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
    } else gl.disable(gl.STENCIL_TEST);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.ALWAYS);
    gl.depthMask(true);
    gl.useProgram(copyFbProgram);
    gl.uniform1i(copyFbU.maskSet, maskSet);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, copyDepth);
    gl.activeTexture(gl.TEXTURE0);
    quadDraw(copyFbProgram, copyFbU, copyTex, dx, dy, w, h, W, H, sx * SX, sy * SY, w * SX, h * SY, false);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, null);
    gl.activeTexture(gl.TEXTURE0);
    gl.disable(gl.DEPTH_TEST);
    gl.disable(gl.STENCIL_TEST);
    stencilStale = true;
    markDrawn(dx, dy, dx + w - 1, dy + h - 1);
    copies++;
  }

  /** Emulated VRAM changed under this rectangle, which may wrap at either edge. */
  function dirty(x, y, w, h) {
    if (vramWords === null) return;
    flush();
    x &= 1023; y &= 511;
    if (w <= 0 || h <= 0) return;
    if (w > W) w = W;
    if (h > H) h = H;
    // Up to four pieces where the rectangle wraps; written out rather than built as arrays of
    // pairs, which allocated on every upload.
    const w0 = x + w > W ? W - x : w, h0 = y + h > H ? H - y : h;
    refresh(x, y, w0, h0);
    if (h0 < h) refresh(x, 0, w0, h - h0);
    if (w0 < w) {
      refresh(0, y, w - w0, h0);
      if (h0 < h) refresh(0, 0, w - w0, h - h0);
    }
  }

  function vram(words) {
    vramWords = words;
    refresh(0, 0, W, H);
  }

  /**
    bp_gpu_scale (ADR-0056): from the next primitive on, the targets are VRAM's size times `percent`
    percent, rounded — 80 four fifths of it, 100 the PlayStation's own, 200 twice, 300 three times
    (25 to 400). Coordinates stay VRAM's, so a scale that is no whole number of target pixels a VRAM
    pixel (0.8) needs nothing else: the viewport maps VRAM onto the target. They are made anew at
    that size with what they held carried over, scaled: the picture on screen, what was drawn and
    not yet read back, the mask bits. A size the GPU cannot hold keeps the scale there was.
  **/
  function scale(percent) {
    const p = Math.max(25, Math.min(400, percent | 0));
    const fw = Math.round(W * p / 100), fh = Math.round(H * p / 100);
    if (fw === FW && fh === FH) return;
    const most = gl.getParameter(gl.MAX_TEXTURE_SIZE);
    if (fw > most || fh > most) {
      console.log(`[webgl] a ${fw}x${fh} picture is past this GPU's ${most}: the scale stays ${S}`);
      return;
    }
    flush();
    const oldTex = fbTex, oldDepth = fbDepth, oldW = FW, oldH = FH;
    fbTex = texture(gl.RGBA8, fw, fh);
    fbDepth = texture(gl.DEPTH24_STENCIL8, fw, fh);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fbTex, 0);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.TEXTURE_2D, fbDepth, 0);
    // The old picture and its mask bits, nearest texel for each new pixel, as a copy draws them.
    gl.viewport(0, 0, fw, fh);
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.STENCIL_TEST);
    gl.enable(gl.DEPTH_TEST);
    gl.depthFunc(gl.ALWAYS);
    gl.depthMask(true);
    gl.useProgram(copyFbProgram);
    gl.uniform1i(copyFbU.maskSet, 0);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, oldDepth);
    gl.activeTexture(gl.TEXTURE0);
    quadDraw(copyFbProgram, copyFbU, oldTex, 0, 0, W, H, W, H, 0, 0, oldW, oldH, false);
    gl.activeTexture(gl.TEXTURE1);
    gl.bindTexture(gl.TEXTURE_2D, null);
    gl.activeTexture(gl.TEXTURE0);
    gl.disable(gl.DEPTH_TEST);
    gl.deleteTexture(oldTex);
    gl.deleteTexture(oldDepth);
    // The copy's scratch holds nothing between copies: made anew, empty.
    gl.deleteTexture(copyTex);
    gl.deleteTexture(copyDepth);
    copyTex = texture(gl.RGBA8, fw, fh);
    copyDepth = texture(gl.DEPTH24_STENCIL8, fw, fh);
    gl.bindFramebuffer(gl.FRAMEBUFFER, copyFbo);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, copyTex, 0);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.TEXTURE_2D, copyDepth, 0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    FW = fw; FH = fh; S = p / 100; SX = fw / W; SY = fh / H;
    gl.useProgram(toWordProgram);
    gl.uniform2f(toWordU.scale, SX, SY);
    stencilStale = true;
    console.log(`[webgl] drawing at ${S}x: ${fw}x${fh}`);
  }

  function present(_vramBytes, sx, sy, sw, sh, flags) {
    flush();
    // Nothing composites a hidden page, and a blit into its drawing buffer can stall the main
    // thread on the GPU process instead: measured at about a millisecond a frame. The
    // framebuffer texture is complete either way; the next visible present shows it.
    if (document.hidden) { primitives = 0; return; }
    if (sw > W) sw = W;
    if (sh > H) sh = H;
    // The canvas holds the picture at its own resolution (ADR-0056): the display's pixels times
    // the scale, one target pixel each.
    const cw = Math.max(Math.round(sw * SX), 1), ch = Math.max(Math.round(sh * SY), 1);
    if (canvas.width !== cw || canvas.height !== ch) {
      canvas.width = cw;
      canvas.height = ch;
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.disable(gl.BLEND);
    if (sw <= 0 || sh <= 0) {
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      primitives = 0;
      return;
    }
    if ((flags & 1) !== 0) {
      gl.useProgram(present24Program);
      gl.uniform1i(present24U.srcX, sx);
      quadDraw(present24Program, present24U, vramTex, 0, 0, sw, sh, sw, sh, 0, sy, sw, sh, true);
    } else {
      quadDraw(blitProgram, blitU, fbTex, 0, 0, sw, sh, sw, sh, sx, sy, sw, sh, true);
    }
    primitives = 0;
  }

  // A pixel of fbTex as the next present would show it (diagnostics: what was drawn where), at
  // VRAM's (x, y): the target pixel at its centre.
  function peek(x, y) {
    flush();
    const out = new Uint8Array(4);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.readPixels(Math.floor((x + 0.5) * SX), Math.floor((y + 0.5) * SY), 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, out);
    return [out[0], out[1], out[2]];
  }

  // Whether the 16x16 tile holding (x, y) is marked drawn (diagnostics: what a sample will sync).
  function drawnTile(x, y) {
    const tx = (x & (W - 1)) >> 4, ty = (y & (H - 1)) >> 4;
    return tx < 32 ? (drawnLo[ty] >>> tx) & 1 : (drawnHi[ty] >>> (tx - 32)) & 1;
  }

  // GL's own view (diagnostics): the pending error and both targets' completeness.
  function glCheck() {
    const err = gl.getError();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    const a = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
    gl.bindFramebuffer(gl.FRAMEBUFFER, copyFbo);
    const b = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    return { err, fbo: a === gl.FRAMEBUFFER_COMPLETE, copyFbo: b === gl.FRAMEBUFFER_COMPLETE };
  }

  // A halfword of vramTex as a primitive samples it (diagnostics), through a 1x1 RGBA8 target.
  let peekTex = null, peekFbo = null, peekProgram = null, peekU = null;
  function peekVram(x, y) {
    flush();
    if (peekTex === null) {
      peekTex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, peekTex);
      gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, 1, 1);
      peekFbo = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, peekFbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, peekTex, 0);
      peekProgram = program(quadVs, `#version 300 es
        precision highp float; precision highp int; precision highp usampler2D;
        uniform usampler2D uVram; in vec2 vTexel; out vec4 oColor;
        void main() { uint t = texelFetch(uVram, ivec2(floor(vTexel)), 0).r;
          oColor = vec4(float(t & 255u), float(t >> 8u), 0.0, 255.0) / 255.0; }`);
      peekU = quad(peekProgram);
      gl.useProgram(peekProgram);
      gl.uniform1i(U(peekProgram, 'uVram'), 0);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, peekFbo);
    gl.viewport(0, 0, 1, 1);
    gl.disable(gl.BLEND); gl.disable(gl.SCISSOR_TEST); gl.disable(gl.STENCIL_TEST); gl.disable(gl.DEPTH_TEST);
    quadDraw(peekProgram, peekU, vramTex, 0, 0, 1, 1, 1, 1, x, y, 1, 1, false);
    const out = new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, out);
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    return (out[0] | (out[1] << 8)).toString(16);
  }

  return { vram, state, tri, rect, sprite, dirty, copy, clip, mask, scale, present, peek, peekVram, drawnTile, glCheck,
    get primitives() { return primitives; }, get syncs() { return syncs; }, get copies() { return copies; },
    get scaled() { return S; } };
}
