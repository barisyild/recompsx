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

  The mask bit (bp_gpu_mask) is the stencil: a dirty rectangle's copy writes 1 where VRAM's bit 15
  is set and 0 elsewhere, a primitive drawn with "set" increments the stencil of every pixel it
  writes, and one drawn with "check" passes only where the stencil is zero. Anything a game reads
  back from VRAM after drawing sees what was there before the draw, by the ABI's own terms.
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
      vec3 c;
      if ((flags & 1) != 0) {
        int tu = (int(floor(vUv.x)) & vWindow.x) | vWindow.y;
        int tv = (int(floor(vUv.y)) & vWindow.z) | vWindow.w;
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
        blending = blending && (t & 0x8000u) != 0u;
        if (uPass == 1 && blending) discard;
        if (uPass == 2 && !blending) discard;
        // Five bits widened to eight by a shift, as the software path does; then texel * colour
        // / 128, with the colour arriving in 0..1 so 255/128 is the factor.
        c = vec3(float(t & 31u), float((t >> 5) & 31u), float((t >> 10) & 31u)) * (8.0 / 255.0);
        if ((flags & 4) == 0) c = min(c * vColor * (255.0 / 128.0), vec3(1.0));
      } else {
        c = vColor;
      }
      // The blend state is src * ONE + dst * SRC_ALPHA (see the header): alpha is the
      // destination's weight and the colour is pre-scaled by the source's. Mode 2 is drawn
      // under a subtracting state of its own, for which (F, 1) is what it needs.
      if (!blending) oColor = vec4(c, 0.0);
      else if (vPage.w == 0) oColor = vec4(c * 0.5, 0.5);
      else if (vPage.w == 3) oColor = vec4(c * 0.25, 1.0);
      else oColor = vec4(c, 1.0);
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
    uniform int uMaskedOnly;     // 1: keep only halfwords with bit 15 set (the stencil pass)
    in vec2 vTexel;
    out vec4 oColor;
    void main() {
      uint t = texelFetch(uVram, ivec2(int(floor(vTexel.x)) & 1023, int(floor(vTexel.y)) & 511), 0).r;
      if (uMaskedOnly != 0 && (t & 0x8000u) == 0u) discard;
      oColor = vec4(vec3(float(t & 31u), float((t >> 5) & 31u), float((t >> 10) & 31u)) / 31.0, 1.0);
    }`;
  // The framebuffer texture to the screen, opaque whatever its alpha says: the canvas is
  // unpremultiplied, so an alpha below one would darken the pixel on the page.
  const blitFs = `#version 300 es
    precision highp float;
    uniform sampler2D uFrame;
    in vec2 vTexel;
    out vec4 oColor;
    void main() {
      oColor = vec4(texture(uFrame, vTexel / vec2(1024.0, 512.0)).rgb, 1.0);
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

  const primProgram = program(primVs, primFs);
  const copyProgram = program(quadVs, copy15Fs);
  const blitProgram = program(quadVs, blitFs);
  const present24Program = program(quadVs, present24Fs);
  const U = (p, name) => gl.getUniformLocation(p, name);
  const prim = { pass: U(primProgram, 'uPass') };
  const quad = (p) => ({ dst: U(p, 'uDst'), src: U(p, 'uSrc'), srcX: U(p, 'uSrcX'),
    maskedOnly: U(p, 'uMaskedOnly') });
  const copyU = quad(copyProgram), blitU = quad(blitProgram), present24U = quad(present24Program);
  // Every sampler reads unit 0, which a program keeps from here on; set once, not per draw.
  for (const [p, name] of [[primProgram, 'uVram'], [copyProgram, 'uVram'], [blitProgram, 'uFrame'],
      [present24Program, 'uVram']]) {
    gl.useProgram(p);
    gl.uniform1i(U(p, name), 0);
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

  const fbTex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, fbTex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.RGBA8, W, H);
  const fbo = gl.createFramebuffer();
  gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, fbTex, 0);
  const stencilRb = gl.createRenderbuffer();
  gl.bindRenderbuffer(gl.RENDERBUFFER, stencilRb);
  gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH24_STENCIL8, W, H);
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, stencilRb);
  gl.clearColor(0, 0, 0, 1);
  gl.clearStencil(0);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
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
  gl.vertexAttribPointer(2, 2, gl.UNSIGNED_BYTE, false, VERTEX_BYTES, 12);
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

  function vertex(i, x, y, bgr, u, v) {
    const w = i * VERTEX_WORDS;
    posView[w] = x;
    posView[w + 1] = y;
    wordView[w + 2] = bgr;                        // r g b, then a byte the attribute ignores
    wordView[w + 3] = (u & 255) | ((v & 255) << 8);
    wordView[w + 4] = pageWord;
    wordView[w + 5] = clutWord;
    wordView[w + 6] = windowWord;
  }

  function tri(x0, y0, c0, u0, v0, x1, y1, c1, u1, v1, x2, y2, c2, u2, v2) {
    const at = batchFor(3, true);
    vertex(at, x0 + 0.5, y0 + 0.5, c0, u0, v0);
    vertex(at + 1, x1 + 0.5, y1 + 0.5, c1, u1, v1);
    vertex(at + 2, x2 + 0.5, y2 + 0.5, c2, u2, v2);
    primitives++;
  }

  function rect(x, y, w, h, bgr) {
    const at = batchFor(6, false);
    const x1 = x + w, y1 = y + h;
    vertex(at, x, y, bgr, 0, 0); vertex(at + 1, x1, y, bgr, 0, 0); vertex(at + 2, x, y1, bgr, 0, 0);
    vertex(at + 3, x, y1, bgr, 0, 0); vertex(at + 4, x1, y, bgr, 0, 0); vertex(at + 5, x1, y1, bgr, 0, 0);
    primitives++;
  }

  // GL state as last set inside flush(), so a run of batches that agree issues nothing between
  // draws. Reset at the start of every flush: refresh() and present() change it in between.
  let glScissor = -1, glScissorX = 0, glScissorY = 0, glScissorW = 0, glScissorH = 0;
  let glStencil = -1, glSubtract = -1, glPass = -1;

  function setScissor(b) {
    if (b.clipped && b.sw > 0 && b.sh > 0) {
      if (glScissor !== 1) { gl.enable(gl.SCISSOR_TEST); glScissor = 1; }
      if (glScissorX !== b.sx || glScissorY !== b.sy || glScissorW !== b.sw || glScissorH !== b.sh) {
        gl.scissor(b.sx, b.sy, b.sw, b.sh);
        glScissorX = b.sx; glScissorY = b.sy; glScissorW = b.sw; glScissorH = b.sh;
      }
    } else if (glScissor !== 0) {
      gl.disable(gl.SCISSOR_TEST); glScissor = 0;
    }
  }

  // "check": draw only where no mask bit is set. "set": leave a mask bit on what is drawn,
  // by incrementing, so the check's reference of zero needs no second value.
  function setStencil(b) {
    const s = (b.maskCheck ? 1 : 0) | (b.maskSet ? 2 : 0);
    if (s === glStencil) return;
    gl.stencilFunc(b.maskCheck ? gl.EQUAL : gl.ALWAYS, 0, 0xFF);
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
    gl.viewport(0, 0, W, H);
    gl.useProgram(primProgram);
    gl.bindVertexArray(primVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, primVbo);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, byteView, 0, vertexCount * VERTEX_BYTES);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, vramTex);
    gl.enable(gl.STENCIL_TEST);
    gl.enable(gl.BLEND);
    glScissor = -1; glScissorW = -1; glStencil = -1; glSubtract = -1; glPass = -1;
    for (let i = 0; i < batchCount; i++) {
      const b = batches[i];
      setScissor(b);
      setStencil(b);
      if (b.kind === SUBTRACT_TEX) {
        setSubtract(0); setPass(1);
        gl.drawArrays(gl.TRIANGLES, b.start, b.count);
        setSubtract(1); setPass(2);
      } else {
        setSubtract(b.kind === SUBTRACT ? 1 : 0); setPass(0);
      }
      gl.drawArrays(gl.TRIANGLES, b.start, b.count);
    }
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.STENCIL_TEST);
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
    gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    // The colour, with the stencil cleared under the rectangle; then the stencil set again
    // wherever the halfword's bit 15 is on. The mask bits an upload carried are now the
    // stencil's, exactly as the software path left them in VRAM.
    gl.enable(gl.STENCIL_TEST);
    gl.useProgram(copyProgram);
    gl.uniform1i(copyU.maskedOnly, 0);
    gl.stencilFunc(gl.ALWAYS, 0, 0xFF);
    gl.stencilOp(gl.REPLACE, gl.REPLACE, gl.REPLACE);
    quadDraw(copyProgram, copyU, vramTex, x, y, w, h, W, H, x, y, w, h, false);
    gl.uniform1i(copyU.maskedOnly, 1);
    gl.stencilFunc(gl.ALWAYS, 1, 0xFF);
    quadDraw(copyProgram, copyU, vramTex, x, y, w, h, W, H, x, y, w, h, false);
    gl.disable(gl.STENCIL_TEST);
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

  function present(_vramBytes, sx, sy, sw, sh, flags) {
    flush();
    // Nothing composites a hidden page, and a blit into its drawing buffer can stall the main
    // thread on the GPU process instead: measured at about a millisecond a frame. The
    // framebuffer texture is complete either way; the next visible present shows it.
    if (document.hidden) { primitives = 0; return; }
    if (sw > W) sw = W;
    if (sh > H) sh = H;
    if (canvas.width !== sw || canvas.height !== sh) {
      canvas.width = Math.max(sw, 1);
      canvas.height = Math.max(sh, 1);
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

  return { vram, state, tri, rect, dirty, clip, mask, present, get primitives() { return primitives; } };
}
