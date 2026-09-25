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
  which is what the hardware did. Primitives are batched by state; a batch is flushed before a
  dirty rectangle is applied, so an upload between two draws lands between them.

  Semi-transparency is the PlayStation's four blend equations. Inside one textured primitive a
  texel blends only if its bit 15 is set, so a textured semi-transparent primitive is drawn twice
  — opaque texels, then blending texels — and each such primitive is its own batch, which keeps
  submission order exact across overlapping sprites.

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

  const W = 1024, H = 512;
  const VERTEX_BYTES = 16;            // f32 x, f32 y, u8 r g b pad, u8 u v pad pad
  const MAX_VERTICES = 1 << 17;
  const vertexData = new ArrayBuffer(MAX_VERTICES * VERTEX_BYTES);
  const posView = new Float32Array(vertexData);
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
  const primVs = `#version 300 es
    layout(location=0) in vec2 aPos;
    layout(location=1) in vec3 aColor;
    layout(location=2) in vec2 aUv;
    out vec3 vColor;
    out vec2 vUv;
    void main() {
      gl_Position = vec4(aPos.x / 512.0 - 1.0, aPos.y / 256.0 - 1.0, 0.0, 1.0);
      vColor = aColor;
      vUv = aUv;
    }`;
  const primFs = `#version 300 es
    precision highp float;
    precision highp int;
    precision highp usampler2D;
    uniform usampler2D uVram;
    uniform ivec2 uTexBase;
    uniform int uDepth;
    uniform ivec2 uClut;
    uniform ivec4 uWindow;       // u AND, u OR, v AND, v OR
    uniform int uFlags;
    uniform int uPass;           // 0 every texel, 1 opaque texels only, 2 blending texels only
    in vec3 vColor;
    in vec2 vUv;
    out vec4 oColor;
    uint word(int x, int y) { return texelFetch(uVram, ivec2(x & 1023, y & 511), 0).r; }
    void main() {
      if ((uFlags & 1) != 0) {
        int tu = (int(floor(vUv.x)) & uWindow.x) | uWindow.y;
        int tv = (int(floor(vUv.y)) & uWindow.z) | uWindow.w;
        int row = uTexBase.y + tv;
        uint t;
        if (uDepth == 2) {
          t = word(uTexBase.x + tu, row);
        } else if (uDepth == 1) {
          uint w = word(uTexBase.x + (tu >> 1), row);
          t = word(uClut.x + int((w >> uint((tu & 1) << 3)) & 255u), uClut.y);
        } else {
          uint w = word(uTexBase.x + (tu >> 2), row);
          t = word(uClut.x + int((w >> uint((tu & 3) << 2)) & 15u), uClut.y);
        }
        if (t == 0u) discard;
        bool blending = (t & 0x8000u) != 0u;
        if (uPass == 1 && blending) discard;
        if (uPass == 2 && !blending) discard;
        // Five bits widened to eight by a shift, as the software path does; then texel * colour
        // / 128, with the colour arriving in 0..1 so 255/128 is the factor.
        vec3 c = vec3(float(t & 31u), float((t >> 5) & 31u), float((t >> 10) & 31u)) * (8.0 / 255.0);
        if ((uFlags & 4) == 0) c = min(c * vColor * (255.0 / 128.0), vec3(1.0));
        oColor = vec4(c, 1.0);
      } else {
        oColor = vec4(vColor, 1.0);
      }
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
  // The framebuffer texture to the screen.
  const blitFs = `#version 300 es
    precision highp float;
    uniform sampler2D uFrame;
    in vec2 vTexel;
    out vec4 oColor;
    void main() {
      oColor = texture(uFrame, vTexel / vec2(1024.0, 512.0));
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
  const prim = { vram: U(primProgram, 'uVram'), texBase: U(primProgram, 'uTexBase'),
    depth: U(primProgram, 'uDepth'), clut: U(primProgram, 'uClut'), window: U(primProgram, 'uWindow'),
    flags: U(primProgram, 'uFlags'), pass: U(primProgram, 'uPass') };
  const quad = (p) => ({ dst: U(p, 'uDst'), src: U(p, 'uSrc'), tex: U(p, 'uVram') || U(p, 'uFrame'),
    srcX: U(p, 'uSrcX'), maskedOnly: U(p, 'uMaskedOnly') });
  const copyU = quad(copyProgram), blitU = quad(blitProgram), present24U = quad(present24Program);

  const vramTex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, vramTex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R16UI, W, H);

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

  const quadVao = gl.createVertexArray();
  const quadVbo = gl.createBuffer();
  gl.bindVertexArray(quadVao);
  gl.bindBuffer(gl.ARRAY_BUFFER, quadVbo);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 1]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  gl.bindVertexArray(null);

  // ---- state and batches ----------------------------------------------------------------------
  const cur = { tx: 0, ty: 0, depth: 0, cx: 0, cy: 0, semiMode: 0, flags: 0, window: 0, dx: 0, dy: 0 };
  const clipRect = { x0: 0, y0: 0, x1: 1023, y1: 511 };
  const maskBits = { set: 0, check: 0 };
  const batches = [];
  let open = null;          // the batch primitives are being appended to, or null

  function mask(setBit, checkBit) {
    if (maskBits.set === setBit && maskBits.check === checkBit) return;
    maskBits.set = setBit; maskBits.check = checkBit;
    open = null;
  }

  function clip(x0, y0, x1, y1) {
    if (clipRect.x0 === x0 && clipRect.y0 === y0 && clipRect.x1 === x1 && clipRect.y1 === y1) return;
    clipRect.x0 = x0; clipRect.y0 = y0; clipRect.x1 = x1; clipRect.y1 = y1;
    open = null;
  }

  function state(tx, ty, depth, cx, cy, semiMode, flags, window, dx, dy) {
    if (cur.tx === tx && cur.ty === ty && cur.depth === depth && cur.cx === cx && cur.cy === cy
        && cur.semiMode === semiMode && cur.flags === flags && cur.window === window
        && cur.dx === dx && cur.dy === dy) return;
    cur.tx = tx; cur.ty = ty; cur.depth = depth; cur.cx = cx; cur.cy = cy;
    cur.semiMode = semiMode; cur.flags = flags; cur.window = window; cur.dx = dx; cur.dy = dy;
    open = null;
  }

  function batchFor(count, clipped) {
    if (vertexCount + count > MAX_VERTICES) flush();
    // A textured, blending primitive is its own batch: it draws in two passes, and the passes
    // of one primitive must not straddle another's. A batch also has one clip setting.
    const twoPass = (cur.flags & (TEXTURED | SEMI)) === (TEXTURED | SEMI);
    if (open === null || twoPass || open.clipped !== clipped) {
      const mx = cur.window & 31, my = (cur.window >> 5) & 31;
      open = { start: vertexCount, count: 0, tx: cur.tx, ty: cur.ty, depth: cur.depth,
        cx: cur.cx, cy: cur.cy, semiMode: cur.semiMode, flags: cur.flags, clipped,
        maskSet: maskBits.set, maskCheck: maskBits.check,
        sx: clipRect.x0, sy: clipRect.y0, sw: clipRect.x1 - clipRect.x0 + 1, sh: clipRect.y1 - clipRect.y0 + 1,
        uAnd: (~(mx << 3)) & 255, uOr: (((cur.window >> 10) & 31) & mx) << 3,
        vAnd: (~(my << 3)) & 255, vOr: (((cur.window >> 15) & 31) & my) << 3 };
      batches.push(open);
    }
    open.count += count;
    const at = vertexCount;
    vertexCount += count;
    return at;
  }

  function vertex(i, x, y, bgr, u, v) {
    posView[i * 4] = x;
    posView[i * 4 + 1] = y;
    const b = i * VERTEX_BYTES;
    byteView[b + 8] = bgr & 255;
    byteView[b + 9] = (bgr >> 8) & 255;
    byteView[b + 10] = (bgr >> 16) & 255;
    byteView[b + 12] = u & 255;
    byteView[b + 13] = v & 255;
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

  function setBlend(flags, semiMode) {
    if ((flags & SEMI) === 0) { gl.disable(gl.BLEND); return; }
    gl.enable(gl.BLEND);
    gl.blendEquation(semiMode === 2 ? gl.FUNC_REVERSE_SUBTRACT : gl.FUNC_ADD);
    if (semiMode === 0) { gl.blendColor(0, 0, 0, 0.5); gl.blendFunc(gl.CONSTANT_ALPHA, gl.ONE_MINUS_CONSTANT_ALPHA); }
    else if (semiMode === 3) { gl.blendColor(0, 0, 0, 0.25); gl.blendFunc(gl.CONSTANT_ALPHA, gl.ONE); }
    else gl.blendFunc(gl.ONE, gl.ONE);
  }

  /** Draw every queued primitive into the framebuffer texture, in submission order. */
  function flush() {
    if (batches.length === 0) return;
    gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
    gl.viewport(0, 0, W, H);
    gl.useProgram(primProgram);
    gl.bindVertexArray(primVao);
    gl.bindBuffer(gl.ARRAY_BUFFER, primVbo);
    gl.bufferSubData(gl.ARRAY_BUFFER, 0, byteView, 0, vertexCount * VERTEX_BYTES);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, vramTex);
    gl.uniform1i(prim.vram, 0);
    gl.enable(gl.STENCIL_TEST);
    for (const b of batches) {
      if (b.clipped && b.sw > 0 && b.sh > 0) {
        gl.enable(gl.SCISSOR_TEST);
        gl.scissor(b.sx, b.sy, b.sw, b.sh);
      } else {
        gl.disable(gl.SCISSOR_TEST);
      }
      // "check": draw only where no mask bit is set. "set": leave a mask bit on what is drawn,
      // by incrementing, so the check's reference of zero needs no second value.
      if (b.maskCheck) gl.stencilFunc(gl.EQUAL, 0, 0xFF); else gl.stencilFunc(gl.ALWAYS, 0, 0xFF);
      gl.stencilOp(gl.KEEP, gl.KEEP, b.maskSet ? gl.INCR : gl.KEEP);
      gl.uniform2i(prim.texBase, b.tx, b.ty);
      gl.uniform1i(prim.depth, b.depth);
      gl.uniform2i(prim.clut, b.cx, b.cy);
      gl.uniform4i(prim.window, b.uAnd, b.uOr, b.vAnd, b.vOr);
      gl.uniform1i(prim.flags, b.flags);
      if ((b.flags & (TEXTURED | SEMI)) === (TEXTURED | SEMI)) {
        gl.uniform1i(prim.pass, 1);
        gl.disable(gl.BLEND);
        gl.drawArrays(gl.TRIANGLES, b.start, b.count);
        gl.uniform1i(prim.pass, 2);
        setBlend(b.flags, b.semiMode);
        gl.drawArrays(gl.TRIANGLES, b.start, b.count);
      } else {
        gl.uniform1i(prim.pass, 0);
        setBlend(b.flags, b.semiMode);
        gl.drawArrays(gl.TRIANGLES, b.start, b.count);
      }
    }
    gl.disable(gl.BLEND);
    gl.disable(gl.SCISSOR_TEST);
    gl.disable(gl.STENCIL_TEST);
    batches.length = 0;
    open = null;
    vertexCount = 0;
  }

  /** A rectangle of texels from one texture onto the current target, both in pixels. */
  function quadDraw(prog, u, tex, dstX, dstY, dstW, dstH, targetW, targetH, srcX, srcY, srcW, srcH, flipY) {
    gl.useProgram(prog);
    gl.bindVertexArray(quadVao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(u.tex, 0);
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
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, W);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, x);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, y);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 2);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, x, y, w, h, gl.RED_INTEGER, gl.UNSIGNED_SHORT, vramWords);
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, 0);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, 0);
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
    const xs = x + w > W ? [[x, W - x], [0, x + w - W]] : [[x, w]];
    const ys = y + h > H ? [[y, H - y], [0, y + h - H]] : [[y, h]];
    for (const [px, pw] of xs) for (const [py, ph] of ys) refresh(px, py, pw, ph);
  }

  function vram(words) {
    vramWords = words;
    refresh(0, 0, W, H);
  }

  function present(_vramBytes, sx, sy, sw, sh, flags) {
    flush();
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
