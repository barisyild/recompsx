import core.CpuState;
import core.Cooperative;
import core.Runtime;
import core.Scheduler;
import kernel.Kernel;
import mem.Memory;

/** Composed ordinary calls against original guest frames, at every public root entry.
    Events and browser deadlines exercise the internal observations that a helper may skip
    only when the whole call tree is proved to finish before them. */
@:access(ScalarCodegen)
class ScalarCompose {
	static inline var STACK = 0x80047020;
	static var optimized = false;
	static function dispatch(addr:Int, ctx:CpuState):Bool return optimized ? ComposeOptimized.dispatch(addr,ctx) : ComposeReference.dispatch(addr,ctx);
	static function resume(fn:Int,entry:Int,ctx:CpuState):Void {
		if(optimized) ComposeOptimized.resume(fn,entry,ctx); else ComposeReference.resume(fn,entry,ctx);
	}
	static function prepare(ctx:CpuState, kind:Int, x:Int, y:Int, at:Int, other:Int, opt:Bool):Void {
		ScalarCodegen.prepare(ctx,x,y,opt); optimized=opt;
		ctx.sp=STACK; ctx.s0=ctx.ra; ctx.s1=ctx.ra; ctx.a2=x; ctx.a3=y;
		if(kind==2 || kind==6 || kind==7 || kind==10 || kind>=12 && kind<=15 || kind>=18) {
			ctx.a0=at; ctx.a1=other;
		} else {}
		for(base in [at,other,STACK-16]) for(k in 0...32) {
			final addr=(base+k)|0;
			if(Memory.isPlainMemory(addr)) Memory.write8(addr,(k*37+x+(base==other?19:0))&255); else {}
		}
		Memory.write32(STACK-4,ctx.ra); Memory.write32(STACK+12,ctx.ra);
		// The public continuation can enter after the pointer-producing call. Supply its
		// already-loaded pointer too: MemA requires aligned wide accesses on every target.
		if(kind==10) { Memory.write32(at,other); ctx.v0=other; } else {}
		if(kind==13) ctx.v0=at; else {}
	}
	static function memory(at:Int,other:Int,bytes:Array<Int>,record:Bool):Void {
		var n=0;
		for(base in [at,other,STACK-16]) for(k in 0...32) {
			final addr=(base+k)|0; final value=Memory.isPlainMemory(addr)?Memory.read8u(addr):0;
			if(record) bytes[n]=value; else Conf.expect('composed memory',value,bytes[n]);
			n++;
		}
	}
	static function run(ctx:CpuState,kind:Int,entry:Int,frequency:Int,budget:Int):Int {
		final addr=ComposeOptimized.entryAddress(kind,entry); var trace=0;
		if(frequency<0) dispatch(addr,ctx); else {
			Cooperative.every=frequency; var slices=0;
			while(Cooperative.step(ctx,addr,budget)) {
				trace=((trace<<5)^(trace>>>27)^ctx.v0^ctx.v1^ctx.ra^ctx.cycles^ctx.pc)|0;
				if(++slices>100) { Conf.expect('composed resume progress',0,1); return 0; } else {}
				// Change live inputs and memory at an actual observation; cached values cannot
				// survive across it. Keep architectural control pointers valid for resumption.
				ctx.a2=(ctx.a2+1)|0; Memory.write32(0x80045020,ctx.a2);
				// A previously disjoint borrowed view can become an alias while suspended.
				// Resumption must reconstruct and recheck it before entering the child helper.
				if(kind==34) ctx.a0=STACK-4; else {}
			}
		}
		return trace;
	}
	static function compare(a:CpuState,b:CpuState,kind:Int,x:Int,y:Int,at:Int,other:Int,entry:Int,frequency:Int,budget:Int,bytes:Array<Int>):Void {
		prepare(a,kind,x,y,at,other,false); final trace=run(a,kind,entry,frequency,budget);
		final ni=Runtime.insns; final nb=Runtime.blocks; final yields=Cooperative.yields; memory(at,other,bytes,true);
		prepare(b,kind,x,y,at,other,true); final actual=run(b,kind,entry,frequency,budget);
		ScalarCodegen.compare(a,b,ni,nb); memory(at,other,bytes,false);
		Conf.expect('composed checkpoint trace',actual,trace); Conf.expect('composed checkpoint count',Cooperative.yields,yields);
	}
	static function due(ctx:CpuState,kind:Int,cycles:Int,offset:Int):Void {
		ctx.cycles=cycles; Scheduler.init(ctx);
		for(slot in 0...Scheduler.SLOTS) Scheduler.cancel(ctx,slot);
		Scheduler.schedule(ctx,Scheduler.VBLANK_START,(cycles+offset)|0); Kernel.haltAt=Kernel.vblankCount+1;
		run(ctx,kind,0,-1,0);
	}
	static function fifo(ctx:CpuState,opt:Bool,kind:Int):Int {
		prepare(ctx,kind,1,2,0x1f801801,0x80045020,opt);
		ctx.cycles=0; Scheduler.init(ctx); cd.Cdrom.init();
		cd.Cdrom.write8(0x1f801802,0x20,0); cd.Cdrom.write8(0x1f801801,0x19,0); cd.Cdrom.onEvent(ctx);
		run(ctx,kind,0,-1,0); return Memory.read8u(0x1f801801);
	}
	public static function main():Void {
		final a=new CpuState(); final b=new CpuState(); final bytes=[for(_ in 0...96) 0];
		Runtime.boot(a); Runtime.bindDispatch(dispatch); Cooperative.bind(resume); Kernel.vramDump=false; Kernel.reportOps=false;
		final values=[0,1,-1,0x80000000,0x7fffffff,0x12345678];
		for(kind in 0...ComposeOptimized.COUNT) for(x in values) for(y in values)
			for(at in [0x80040020,0x1f800040,0x801ffff0]) for(other in [at,0x80045020])
				for(entry in 0...ComposeOptimized.entryCount(kind)) compare(a,b,kind,x,y,at,other,entry,-1,0,bytes);
		for(kind in 0...ComposeOptimized.COUNT) for(frequency in 0...4) for(budget in [1,8,1024])
			compare(a,b,kind,-1,7,0x80040020,0x80045020,0,frequency,budget,bytes);
		// Exact physical aliases, including KSEG and 2 MB mirrors, must fail the guard
		// before the saved return word or any other guest bytes are written.
		for(kind in [7,12,28,29,31,33,34]) for(x in [-1,0,1])
			for(at in [STACK-4,0xa004701c,0x8024701c,STACK]) for(other in [at,0x80045020]) {
				compare(a,b,kind,x,7,at,other,0,-1,0,bytes);
				compare(a,b,kind,x,7,at,other,0,0,1024,bytes);
			}
		for(kind in 0...ComposeOptimized.COUNT) {
			final bound=ComposeOptimized.bound(kind);
			if(bound>0) for(cycles in [0,0x7ffffff0,0xfffffff0]) for(offset in 0...bound+2) {
				prepare(a,kind,-1,7,0x80040020,0x80045020,false); due(a,kind,cycles,offset);
				final ni=Runtime.insns; final nb=Runtime.blocks; memory(0x80040020,0x80045020,bytes,true);
				prepare(b,kind,-1,7,0x80040020,0x80045020,true); due(b,kind,cycles,offset);
				ScalarCodegen.compare(a,b,ni,nb); memory(0x80040020,0x80045020,bytes,false);
			} else {}
		}
		for(kind in [0,1,5,11,15,17]) {
			prepare(a,kind,-1,7,0x80040020,0x80045020,false); a.unwindToken=1; run(a,kind,0,-1,0);
			final ni=Runtime.insns; final nb=Runtime.blocks; memory(0x80040020,0x80045020,bytes,true);
			prepare(b,kind,-1,7,0x80040020,0x80045020,true); b.unwindToken=1; run(b,kind,0,-1,0);
			ScalarCodegen.compare(a,b,ni,nb); memory(0x80040020,0x80045020,bytes,false);
		}
		for(kind in [18,35]) {
			final next=fifo(a,false,kind); final ni=Runtime.insns; final nb=Runtime.blocks;
			final actual=fifo(b,true,kind); ScalarCodegen.compare(a,b,ni,nb); Conf.expect('composed FIFO order',actual,next);
			Conf.expect('first response read once',b.v0,0x94); Conf.expect('second response read once',b.v1,9);
			Conf.expect('FIFO fallback has no speculative reads',actual,0x19);
		}
		Conf.report('ScalarCompose');
	}
}
