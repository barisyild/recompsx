package shim;

/** Host pacing only. The portable continuation runner knows cycles, never DOM or wall time. */
class BrowserLoop {
	public static function drive(step:Void -> Bool):Void {
		if (!js.Syntax.code("(typeof window !== 'undefined' && typeof requestAnimationFrame === 'function')")) {
			while (step()) {}
			return;
		} else {}
		js.Syntax.code("(function(step, frameMs) {
			const host = globalThis.recompsxHost;
			let base = {0}, t0 = performance.now(), active = true;
			function frames() { return {0}; }
			function state(value) { if (host && host.state) host.state(value); }
			function schedule() {
				let ran = false;
				const raf = requestAnimationFrame(go);
				const timer = setTimeout(go, 20);
				function go() {
					if (ran || !active) return;
					ran = true; cancelAnimationFrame(raf); clearTimeout(timer);
					try { tick(); } catch (e) {
						active = false;
						if (host && host.log) host.log(3, '[fatal] ' + (e.stack || String(e)));
						state('error');
					}
				}
			}
			function tick() {
				const start = performance.now();
				if (host && host.paused) { base = frames(); t0 = start; schedule(); return; }
				// Rebase only when the page cannot keep up — more than a second of backlog, as a
				// throttled tab leaves — never merely because a second has passed, and not for
				// being hidden either: the sound still plays then. Comparing the age of the
				// origin instead of the backlog rebased every tick after the first second, and
				// with the origin always fresh a tick could never be ahead of schedule, so the
				// game ran as fast as the ticks allowed, two to three times real time.
				if ((start - t0) - (frames() - base) * frameMs > 1000) { base = frames(); t0 = start; }
				while (performance.now() - start < 8) {
					if ((frames() - base) * frameMs > performance.now() - t0 + frameMs) break;
					if (!step()) { active = false; state('stopped'); return; }
				}
				if (host && host.progress) host.progress(frames(), {1});
				schedule();
			}
			state('running'); schedule();
		})({2}, {3} * 1000 / 33868800)", gpu.Scanout.frames, core.Cooperative.yields,
			step, core.TimeBase.cyclesPerFrame());
	}
}
