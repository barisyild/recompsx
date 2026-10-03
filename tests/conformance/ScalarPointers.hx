import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Execute dependent-address helpers against original guest bodies. Guard-only probes
    additionally check invalid wide addresses without invoking unsupported guest alignment. */
@:access(ScalarCodegen)
class ScalarPointers {
	static inline var TABLE = 0x80048000;
	static inline var FIRST = 0x80048100;
	static inline var SECOND = 0x80048200;
	static inline var OTHER = 0x80048300;
	static var optimized = false;
	static function dispatch(addr:Int,ctx:CpuState):Bool return optimized?PointersOptimized.dispatch(addr,ctx):PointersReference.dispatch(addr,ctx);
	static function resume(fn:Int,entry:Int,ctx:CpuState):Void {
		if(optimized) PointersOptimized.resume(fn,entry,ctx); else PointersReference.resume(fn,entry,ctx);
	}
	static function prepare(ctx:CpuState,kind:Int,at:Int,other:Int,x:Int,opt:Bool):Void {
		ScalarCodegen.prepare(ctx,at,other,opt); optimized=opt;
		ctx.a2=x; ctx.a3=kind==23 ? x & 0xfc : x; ctx.s0=ctx.ra; ctx.s1=ctx.ra;
		// Case 23 dereferences a word after the byte store may alter the first pointer.
		// Keep that guest word aligned on fallback; invalid alignment is probed below
		// without executing the runtime's separately documented unsupported wide access.
		ctx.t0=FIRST; ctx.t1=SECOND; ctx.v0=FIRST;
		for(base in [at,FIRST,SECOND,OTHER,0xc0,0x1c0,0x100c0]) for(k in 0...64)
			Memory.write8((base+k)|0,(k*37+x+base)&255);
		// Any low-byte mutation of these pointers remains a readable byte address.
		for(k in 32...256) { Memory.write8(FIRST+k,(k+x)&255); Memory.write8(SECOND+k,(k-x)&255); }
		Memory.write32(FIRST,SECOND); Memory.write32(SECOND,FIRST);
		Memory.write32(at,FIRST); Memory.write32(at+4,SECOND);
		if(kind>=8 && kind<=11 || kind==29 || kind==45 || kind==50) Memory.write32(at,0xffc0); else {}
	}
	static function memory(at:Int,bytes:Array<Int>,record:Bool):Void {
		var n=0;
		for(base in [at,FIRST,SECOND,OTHER,0xc0,0x1c0,0x100c0]) for(k in 0...64) {
			final value=Memory.read8u((base+k)|0);
			if(record) bytes[n]=value; else Conf.expect('pointer memory',value,bytes[n]);
			n++;
		}
	}
	static function run(ctx:CpuState,kind:Int,entry:Int,frequency:Int,budget:Int,at:Int):Int {
		final addr=PointersOptimized.entryAddress(kind,entry); var trace=0;
		if(frequency<0) dispatch(addr,ctx); else {
			Cooperative.every=frequency; var slices=0;
			while(Cooperative.step(ctx,addr,budget)) {
				trace=((trace<<5)^(trace>>>27)^ctx.v0^ctx.t0^ctx.ra^ctx.cycles^ctx.pc)|0;
				if(++slices>100) { Conf.expect('pointer resume progress',0,1); return 0; } else {}
				// Entry proofs may not survive actual suspension and changed pointer tables.
				if((kind<8 || kind>11) && kind!=29 && kind!=45 && kind!=50) Memory.write32(at,SECOND); else {}
			}
		}
		return trace;
	}
	static function compare(a:CpuState,b:CpuState,kind:Int,at:Int,other:Int,x:Int,entry:Int,frequency:Int,budget:Int,bytes:Array<Int>):Void {
		prepare(a,kind,at,other,x,false); final trace=run(a,kind,entry,frequency,budget,at);
		final ni=Runtime.insns; final nb=Runtime.blocks; final yields=Cooperative.yields; memory(at,bytes,true);
		prepare(b,kind,at,other,x,true); final actual=run(b,kind,entry,frequency,budget,at);
		ScalarCodegen.compare(a,b,ni,nb); memory(at,bytes,false);
		Conf.expect('pointer checkpoints',actual,trace); Conf.expect('pointer yields',Cooperative.yields,yields);
	}
	static function due(ctx:CpuState,kind:Int,cycles:Int,offset:Int):Void {
		ctx.cycles=cycles; Scheduler.init(ctx);
		for(slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx,slot);
		Scheduler.schedule(ctx,Scheduler.VBLANK_START,(cycles+offset)|0); Kernel.haltAt=Kernel.vblankCount+1;
		run(ctx,kind,0,-1,0,TABLE);
	}
	static function queue(ctx:CpuState):Void {
		ctx.cycles=0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802,0x20,0); cd.Cdrom.write8(0x1f801801,0x19,0); cd.Cdrom.onEvent(ctx);
	}
	static function fifo(ctx:CpuState,opt:Bool,source:Bool):Int {
		final kind=source?11:0;
		prepare(ctx,kind,TABLE,OTHER,1,opt); queue(ctx);
		if(source) ctx.a0=0x1f801801; else Memory.write32(TABLE,0x1f801801);
		Conf.expect('device source/target rejects preflight',PointersOptimized.guarded(kind,ctx)?1:0,0);
		run(ctx,kind,0,-1,0,TABLE);
		return Memory.read8u(0x1f801801);
	}
	public static function main():Void {
		final a=new CpuState(); final b=new CpuState(); final bytes=[for(_ in 0...448) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump=false; Kernel.reportOps=false;
		for(kind in 0...PointersOptimized.COUNT) for(x in [0,1,-1,0x34,0x80,0x7fffffff,0x80000000])
			for(at in [TABLE,0xa0048000,0x1f800040]) for(other in [OTHER,at,(at+4)|0])
				for(entry in 0...PointersOptimized.entryCount(kind)) compare(a,b,kind,at,other,x,entry,-1,0,bytes);
		for(kind in 0...PointersOptimized.COUNT) for(frequency in 0...4) for(budget in [1,8,1024])
			compare(a,b,kind,TABLE,OTHER,1,0,frequency,budget,bytes);
		for(kind in 0...PointersOptimized.COUNT) {
			prepare(b,kind,TABLE,OTHER,1,true);
			Conf.expect('proved entry actually admits helper',PointersOptimized.guarded(kind,b)?1:0,[5,18,19,40,47,53,54].contains(kind)?0:1);
			final bound=PointersOptimized.bound(kind);
			for(cycles in [0,0x7ffffff0,0xfffffff0]) for(offset in 0...bound+2) {
				prepare(a,kind,TABLE,OTHER,1,false); due(a,kind,cycles,offset);
				final ni=Runtime.insns; final nb=Runtime.blocks; memory(TABLE,bytes,true);
				prepare(b,kind,TABLE,OTHER,1,true); due(b,kind,cycles,offset);
				ScalarCodegen.compare(a,b,ni,nb); memory(TABLE,bytes,false);
			}
		}
		for(kind in [3,16,20,21,23,24,26,29,36,50]) for(other in [TABLE,0xa0048000,0x80248000]) {
			prepare(b,kind,TABLE,other,1,true);
			Conf.expect('physical prior-write alias rejects preflight',PointersOptimized.guarded(kind,b)?1:0,0);
			compare(a,b,kind,TABLE,other,1,0,-1,0,bytes);
		}
		for(kind in [4,7,17]) {
			prepare(b,kind,TABLE,TABLE,1,true);
			Conf.expect('later aliasing write preserves old pointer',PointersOptimized.guarded(kind,b)?1:0,1);
		}
		for(at in [TABLE+1,0x801ffffe,0x1f8003fe,0x1f801801,0x1fc00000]) {
			prepare(b,0,TABLE,OTHER,1,true); b.a0=at;
			Conf.expect('invalid/unaligned wide source rejects preflight',PointersOptimized.guarded(0,b)?1:0,0);
		}
		prepare(b,1,TABLE,OTHER,1,true); Memory.write32(TABLE,FIRST+1);
		Conf.expect('unaligned intermediate pointer rejects before wide read',PointersOptimized.guarded(1,b)?1:0,0);
		prepare(b,23,TABLE,FIRST,1,true);
		Conf.expect('deeper pointer source excludes preceding write',PointersOptimized.guarded(23,b)?1:0,0);
		compare(a,b,23,TABLE,FIRST,1,0,-1,0,bytes);
		prepare(a,22,TABLE,OTHER,1,false); Memory.write32(TABLE,0xfffffffc); Memory.write8(0,83);
		run(a,22,0,-1,0,TABLE); final wrapInsns=Runtime.insns; final wrapBlocks=Runtime.blocks;
		prepare(b,22,TABLE,OTHER,1,true); Memory.write32(TABLE,0xfffffffc); Memory.write8(0,83);
		Conf.expect('wrapped pointer range admitted',PointersOptimized.guarded(22,b)?1:0,1);
		run(b,22,0,-1,0,TABLE); ScalarCodegen.compare(a,b,wrapInsns,wrapBlocks);
		Conf.expect('wrapped loaded pointer is a signed word',b.t0,0);
		Conf.expect('wrapped loaded pointer reaches byte zero',b.v0,83);
		for(source in [false,true]) {
			final expected=fifo(a,false,source); final ni=Runtime.insns; final nb=Runtime.blocks;
			final actual=fifo(b,true,source); ScalarCodegen.compare(a,b,ni,nb);
			Conf.expect('loaded pointer FIFO fallback agrees',actual,expected);
			Conf.expect('guard consumed no FIFO bytes',actual,9);
			if(source) Conf.expect('signedness and offset in source fallback',b.t0,0x194);
			else Conf.expect('device target read exactly once',b.v0,0x94);
		}
		// An untaken path may have an invalid pointer; no speculative device read is allowed.
		prepare(b,12,TABLE,OTHER,0,true); queue(b); b.a0=0x1f801801;
		run(b,12,0,-1,0,TABLE);
		Conf.expect('untaken dependent path',b.v0,7);
		Conf.expect('untaken source FIFO untouched',Memory.read8u(0x1f801801),0x94);
		// A removed child still has every original device-sensitive access in preflight,
		// including a load into zero whose numeric result is never used.
		prepare(a,43,TABLE,OTHER,1,false); queue(a); a.a1=0x1f801801;
		run(a,43,0,-1,0,TABLE); final deadInsns=Runtime.insns; final deadBlocks=Runtime.blocks;
		final deadFifo=Memory.read8u(0x1f801801);
		prepare(b,43,TABLE,OTHER,1,true); queue(b); b.a1=0x1f801801;
		Conf.expect('removed child zero-target device read rejects preflight',PointersOptimized.guarded(43,b)?1:0,0);
		run(b,43,0,-1,0,TABLE); ScalarCodegen.compare(a,b,deadInsns,deadBlocks);
		Conf.expect('removed child fallback consumes exactly one device byte',Memory.read8u(0x1f801801),deadFifo);
		Conf.expect('zero-target read observed FIFO',deadFifo,9);
		Conf.report('ScalarPointers');
	}
}
