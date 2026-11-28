/** WebGL fluid backdrop. Falls back to a CSS class on the host when shaders fail. */

const VERT = `attribute vec2 a; void main(){ gl_Position = vec4(a,0.0,1.0); }`;

const FRAG = `
precision highp float;
uniform vec2 uRes;
uniform float uTime;
uniform float uDark;
uniform float uRefract;
uniform float uQuality;

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453); }
float noise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  f = f*f*(3.0-2.0*f);
  return mix(mix(hash(i), hash(i+vec2(1.0,0.0)), f.x),
             mix(hash(i+vec2(0.0,1.0)), hash(i+vec2(1.0,1.0)), f.x), f.y);
}
float fbm(vec2 p){
  float a = 0.5, s = 0.0;
  for (int i=0;i<5;i++){ s += a*noise(p); p *= 2.03; a *= 0.5; }
  return s;
}

void main(){
  vec2 uv = gl_FragCoord.xy / uRes;
  vec2 p = (uv - 0.5) * vec2(uRes.x/uRes.y, 1.0);
  float t = uTime * 0.08;
  float steps = mix(3.0, 5.0, clamp(uQuality, 0.0, 1.0));

  vec2 q = p;
  q += 0.18 * vec2(sin(t*1.1 + q.y*2.2), cos(t*0.9 + q.x*1.7));
  float n = fbm(q*1.6 + vec2(t*0.4, -t*0.25));
  float n2 = fbm(q*2.4 - vec2(t*0.3, t*0.45) + n);

  // Refraction offset: stronger slider warps the field more visibly.
  vec2 grad = vec2(dFdx(n2), dFdy(n2));
  vec2 warp = grad * (0.15 + uRefract * 1.35);
  float field = fbm(q*1.8 + warp * 8.0 + vec2(n, n2));

  vec3 darkA = vec3(0.03, 0.05, 0.10);
  vec3 darkB = vec3(0.05, 0.16, 0.28);
  vec3 darkC = vec3(0.22, 0.18, 0.42);
  vec3 darkD = vec3(0.10, 0.38, 0.46);
  vec3 lightA = vec3(0.86, 0.90, 0.97);
  vec3 lightB = vec3(0.70, 0.86, 0.98);
  vec3 lightC = vec3(0.82, 0.76, 0.96);
  vec3 lightD = vec3(0.62, 0.90, 0.88);

  vec3 a = mix(lightA, darkA, uDark);
  vec3 b = mix(lightB, darkB, uDark);
  vec3 c = mix(lightC, darkC, uDark);
  vec3 d = mix(lightD, darkD, uDark);

  vec3 col = mix(a, b, smoothstep(0.25, 0.7, field));
  col = mix(col, c, smoothstep(0.45, 0.9, n2));
  col = mix(col, d, 0.35 * smoothstep(0.55, 1.0, n));

  // Prism fringe grows with refraction.
  float fringe = uRefract * 0.12;
  col += vec3(fringe, fringe*0.4, -fringe) * (field - 0.5);

  // Soft vignette and a moving caustic highlight.
  float vig = smoothstep(1.15, 0.2, length(p));
  col *= mix(0.82, 1.0, vig);
  float spark = smoothstep(0.72, 1.0, fbm(q*3.0 + t));
  col += spark * mix(vec3(0.18,0.22,0.28), vec3(0.10,0.16,0.22), uDark) * (0.35 + uRefract);

  // Avoid unused warning on older compilers.
  col += 0.0 * steps;
  gl_FragColor = vec4(col, 1.0);
}
`;

export interface FluidHandle {
  set(opts: { dark: boolean; refraction: number; quality: 'high' | 'medium' | 'low' | 'off'; running: boolean }): void;
  destroy(): void;
}

export function mountFluid(canvas: HTMLCanvasElement): FluidHandle {
  const gl = canvas.getContext('webgl', { alpha: false, antialias: false, premultipliedAlpha: false });
  if (!gl) throw new Error('no webgl');

  const compile = (type: number, src: string) => {
    const sh = gl.createShader(type);
    if (!sh) throw new Error('shader');
    gl.shaderSource(sh, src);
    gl.compileShader(sh);
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(sh);
      gl.deleteShader(sh);
      throw new Error(log ?? 'compile');
    }
    return sh;
  };

  const vs = compile(gl.VERTEX_SHADER, VERT);
  const fs = compile(gl.FRAGMENT_SHADER, FRAG);
  const prog = gl.createProgram();
  if (!prog) throw new Error('program');
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.bindAttribLocation(prog, 0, 'a');
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog) ?? 'link');
  gl.useProgram(prog);

  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

  const uRes = gl.getUniformLocation(prog, 'uRes');
  const uTime = gl.getUniformLocation(prog, 'uTime');
  const uDark = gl.getUniformLocation(prog, 'uDark');
  const uRefract = gl.getUniformLocation(prog, 'uRefract');
  const uQuality = gl.getUniformLocation(prog, 'uQuality');

  let dark = 1;
  let refraction = 0.65;
  let quality: 'high' | 'medium' | 'low' | 'off' = 'high';
  let running = true;
  let raf = 0;
  const start = performance.now();

  const scaleOf = () => (quality === 'high' ? 1 : quality === 'medium' ? 0.6 : 0.35);

  const resize = () => {
    const dpr = Math.min(window.devicePixelRatio || 1, quality === 'high' ? 1.5 : 1);
    const s = scaleOf();
    const w = Math.max(1, Math.floor(canvas.clientWidth * dpr * s));
    const h = Math.max(1, Math.floor(canvas.clientHeight * dpr * s));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    gl.viewport(0, 0, w, h);
  };

  const frame = (now: number) => {
    if (!running || quality === 'off') return;
    resize();
    gl.uniform2f(uRes, canvas.width, canvas.height);
    gl.uniform1f(uTime, (now - start) / 1000);
    gl.uniform1f(uDark, dark);
    gl.uniform1f(uRefract, refraction);
    gl.uniform1f(uQuality, quality === 'high' ? 1 : quality === 'medium' ? 0.5 : 0.2);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    raf = requestAnimationFrame(frame);
  };

  const onVis = () => {
    if (document.hidden) {
      cancelAnimationFrame(raf);
    } else if (running && quality !== 'off') {
      raf = requestAnimationFrame(frame);
    }
  };
  document.addEventListener('visibilitychange', onVis);
  raf = requestAnimationFrame(frame);

  return {
    set(opts) {
      dark = opts.dark ? 1 : 0;
      refraction = opts.refraction;
      quality = opts.quality;
      running = opts.running && opts.quality !== 'off';
      cancelAnimationFrame(raf);
      if (running) raf = requestAnimationFrame(frame);
    },
    destroy() {
      running = false;
      cancelAnimationFrame(raf);
      document.removeEventListener('visibilitychange', onVis);
      gl.deleteProgram(prog);
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      gl.deleteBuffer(buf);
    },
  };
}
