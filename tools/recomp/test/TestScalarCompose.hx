import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarCall;
import recomp.codegen.ScalarPlan;
import recomp.codegen.ScalarPlan.ScalarMemory;
import recomp.codegen.ScalarPlan.ScalarWrite;
import recomp.codegen.ScalarGraph;
import recomp.codegen.ScalarGraph.ScalarValue;
import recomp.codegen.ScalarMemoryValues;
import sys.io.File;

@:access(TestCodegen)
class TestScalarCompose {
	static inline var BASE = 0x80160000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 36;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op, rt, rs, n);
	static function alu(op:Int, rd:Int, rs:Int, rt:Int):Int return TestCodegen.alu(op, rd, rs, rt);
	static function move(rd:Int, rs:Int):Int return alu(0x21, rd, rs, 0);
	static function jump(addr:Int):Int return 0x08000000 | ((addr & 0xfffffff) >>> 2);
	static function words(kind:Int, base:Int):Array<Int> {
		final child = base + 256; final grand = base + 384;
		var root = [move(16, 31), TestCodegen.jal(child), imm(9, 4, 4, 1), move(31, 16), JR, imm(9, 3, 2, 1)];
		var leaf = [alu(0x21, 2, 4, 5), JR, alu(0x26, 3, 4, 5)];
		var second = [alu(0x23, 2, 4, 5), JR, alu(0x25, 3, 4, 5)];
		switch (kind) {
			case 1 | 2 | 7 | 18:
				root = [imm(9, 29, 29, -16), imm(0x2b, 31, 29, 12), TestCodegen.jal(child), 0,
					imm(0x23, 31, 29, 12), JR, imm(9, 29, 29, 16)];
				if (kind == 2) leaf = [JR, imm(0x23, 2, 4, 0)];
				if (kind == 7) leaf = [JR, imm(0x2b, 6, 4, 0)]; // Saved ra now requires an alias guard.
				if (kind == 18) leaf = [imm(0x24,2,4,0), JR, imm(0x24,3,4,0)];
			case 3:
				root = [move(16,31), alu(0x26,8,4,5), TestCodegen.jal(child), 0, move(17,3),
					TestCodegen.jal(grand), 0, imm(9,8,0,0), move(31,16), JR, move(3,17)];
			case 4:
				root = [move(16,31), imm(4,0,6,3), 0, TestCodegen.jal(child), 0, move(31,16), JR, 0];
			case 5:
				root = [imm(9,29,29,-16), imm(0x2b,31,29,12), imm(4,0,6,5), 0,
					TestCodegen.jal(child), 0, jump(base+40), 0, TestCodegen.jal(child), imm(9,5,5,1),
					imm(0x23,31,29,12), JR, imm(9,29,29,16)];
			case 6:
				root[2] = 0;
				leaf = [imm(4,0,6,3), 0, JR, imm(0x2b,6,4,4), JR, imm(0x23,2,4,0)];
			case 8 | 9: // Unknown residency / hooked callee, configured in source().
			case 10:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x23,3,2,0)];
				leaf = [JR, imm(0x23,2,4,0)]; // Returned load provenance permits a checked dependent view.
			case 11:
				leaf = [move(17,31), TestCodegen.jal(grand), 0, move(31,17), JR, imm(9,3,2,9)];
			case 12:
				root = [move(16,31), imm(0x23,17,4,0), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x23,2,4,0)];
				leaf = [JR, imm(0x2b,6,5,0)];
			case 13:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x23,2,2,0)];
				leaf = [JR, move(2,4)]; // A proven returned pointer keeps its affine identity.
			case 14:
				root = [move(16,31), imm(0x23,17,4,0), TestCodegen.jal(child), imm(9,4,4,4), move(31,16), JR, 0];
				leaf = [imm(0x23,2,4,4), JR, imm(0x24,3,4,8)];
			case 15:
				root[2] = 0;
				leaf = [imm(0x23,2,4,0), imm(0x23,3,5,0), imm(0x2b,2,5,0), JR, imm(0x2b,3,4,0)];
			case 16: root[2] = move(6,31); leaf = [JR, alu(0x26,2,4,6)];
			case 17:
				root = [move(16,31), TestCodegen.jal(child), 0, move(17,2), TestCodegen.jal(child), 0, move(31,16), JR, alu(0x26,2,2,17)];
				leaf = [imm(4,0,6,3), 0, JR, imm(9,2,4,7), JR, imm(9,2,5,9)];
			case 19 | 20 | 21 | 22 | 24 | 25 | 26 | 27 | 28 | 29 | 30 | 35:
				root = [imm(9,29,29,-16), imm(0x2b,31,29,12), TestCodegen.jal(child), 0,
					imm(0x23,31,29,12), imm(9,29,29,16), JR, 0];
				leaf = [JR, imm(0x2b,6,29,4)];
				switch(kind) {
					case 20: leaf[1] = imm(0x2b,6,29,8); // Adjacent below the saved word.
					case 21: leaf[1] = imm(0x2b,6,29,16); // Adjacent above it.
					case 22: leaf[1] = imm(0x28,6,29,15); // One overlapping byte kills the fact.
					case 24: root[3] = move(4,29); leaf[1] = imm(0x2b,6,4,4);
					case 25: root[3] = imm(9,4,29,8); leaf[1] = imm(0x2b,6,4,-4);
					case 26: leaf = [imm(0x2b,6,29,8), JR, imm(0x2b,7,29,16)]; // Preserve the hole.
					case 27: leaf = [imm(4,0,6,3), 0, JR, imm(0x2b,7,29,12), JR, imm(0x2b,7,29,4)];
					case 28: leaf = [imm(0x23,2,4,0), JR, imm(0x2b,6,29,4)]; // Other span is read-only.
					case 29: leaf = [imm(0x2b,6,29,4), JR, imm(0x2b,7,4,0)]; // Needs an alias guard too.
					case 30: root[3] = imm(9,4,29,12); leaf[1] = imm(0x2b,6,4,0); // Proved overlap.
					case 35: leaf = [imm(0x28,6,5,0), imm(0x24,2,4,0), JR, imm(0x24,3,4,0)];
					case _:
				}
			case 23 | 33 | 34:
				root = [imm(0x2b,31,29,12), TestCodegen.jal(child), 0,
					imm(0x23,31,29,12), 0, JR, 0];
				leaf = [imm(9,29,29,-16), imm(0x2b,31,29,12), TestCodegen.jal(grand), 0,
					imm(0x23,31,29,12), imm(9,29,29,16), JR, 0];
				second = [JR, imm(0x2b,6,29,4)];
				if (kind == 33) { root[2] = imm(9,4,29,-4); second[1] = imm(0x2b,6,4,0); }
				if (kind == 34) {
					root = [move(16,31), imm(0x2b,6,4,0), imm(0x2b,7,29,-4), imm(0x24,8,4,0), imm(0x24,9,29,0), alu(0x10,3,0,0),
						TestCodegen.jal(child), 0, move(31,16), JR, 0];
					second[1] = imm(0x2b,6,4,0);
				}
			case 31:
				root = [imm(9,29,29,-16), imm(0x2b,31,29,12), imm(4,0,6,5), 0,
					imm(0x2b,7,4,0), jump(base+36), 0, 0, imm(0x2b,7,5,0), TestCodegen.jal(child), 0,
					imm(0x23,31,29,12), imm(9,29,29,16), JR, 0];
				leaf = [JR, move(2,6)];
			case 32:
				root = [move(16,31), imm(0x23,17,4,0), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x23,2,4,0)];
				leaf = [JR, imm(0x2b,6,4,4)];
		}
		while(root.length < 64) root.push(0);
		root = root.concat(leaf);
		while(root.length < 96) root.push(0);
		return root.concat(second);
	}
	static function source(opt:Bool, check:Bool):String {
		final cls = opt ? 'ComposeOptimized' : 'ComposeReference';
		final bodies = new StringBuf(); final dispatch = new StringBuf(); final resume = new StringBuf();
		final entries = new StringBuf(); final counts = new StringBuf(); final bounds = new StringBuf();
		for (kind in 0...COUNT) {
			final base = BASE + (kind << 12); final w = words(kind, base); final bytes = haxe.io.Bytes.alloc(w.length*4);
			for(i in 0...w.length) bytes.setInt32(i*4,w[i]);
			final image = new Image('composed signatures',base,bytes); final d = new Discovery(image);
			d.addSeed(base, Discovery.defaultName(base), Confidence.Entry); d.run(false);
			final emitter = new Emitter(image,d,opt);
			emitter.staticTargetOf = a -> kind != 8 && d.functions.exists(a) ? cls : null;
			if(kind == 9) emitter.hooks = [base+256 => true];
			final caller = d.functions.get(base); final plan = emitter.scalarPlan(caller);
			final expected = opt && [8,9,22,27,30,33,34].indexOf(kind) < 0;
			if(check) {
				Assert.equals(plan != null, expected, 'composed signature eligibility $kind');
				if(plan != null) {
					final helper = plan.emitHelper();
					Assert.isTrue(helper.indexOf('ctx') < 0, 'composed computation carries no CpuState');
					Assert.isTrue(plan.horizon > 0 && plan.bounds.calls, 'whole-call observation bound');
					Assert.isTrue(helper.indexOf(cls+'.f_') >= 0 || [10,13,31].contains(kind), 'ordinary typed helper call or proved dead computation $kind');
					if (kind==10) Assert.isTrue(helper.indexOf(cls+'.f_') < 0,'proved returned read needs no child call');
					Assert.isTrue(!plan.outputs.contains(31), 'return register proved preserved');
					if(kind==3) {
						final shared=plan.sharedBody();
						Assert.isTrue(shared.indexOf('core.ScalarResult.value1')>=0,'shared call keeps the ABI member name');
						Assert.isTrue(shared.indexOf('core.ScalarResult.value0')<0,'SSA renaming cannot turn an ABI member into a local name');
					}
					if ([19,20,21,23,24,25,26,28,32].contains(kind))
						Assert.equals(plan.memory.separations.length,0,'proved disjoint writes require no runtime alias guard');
					if ([7,12,29].contains(kind)) Assert.equals(plan.memory.separations.length,1,'possibly aliased reused word needs one guard');
					if (kind==31) Assert.equals(plan.memory.separations.length,2,'a join retains both path exclusions');
					if (kind==32) Assert.equals(helper.split('Memory.spanRead32').length-1,1,'callee disjoint write preserves the loaded word');
				}
				if (opt && kind==34) Assert.isTrue(emitter.emitFunction(caller).indexOf('_withSpans(ctx,')>=0,'composed alias guards survive borrowed entry');
			}
			bounds.add('case $kind: ${plan==null?0:plan.horizon};\n');
			final blocks=Emitter.blockOrder(caller);
			counts.add('case $kind: ${blocks.length};\n'); entries.add('case $kind: switch(entry) {\n');
			for(i in 0...blocks.length) entries.add('case $i: ${blocks[i]};\n');
			entries.add('default: -1; }\n');
			final functions=[for(a in d.functions.keys()) a]; functions.sort((a,b)->a-b);
			for(a in functions) {
				final fn=d.functions.get(a); bodies.add(emitter.emitFunction(fn));
				resume.add('case $a: ${fn.name}(ctx,entry);\n');
				final ordered=Emitter.blockOrder(fn);
				for(i in 0...ordered.length) dispatch.add('case ${ordered[i]}: ${fn.name}(ctx,$i); return true;\n');
			}
			if(check && opt && kind==11) {
				emitter.hooks=[base+384 => true];
				Assert.isTrue(emitter.scalarPlan(caller)==null, 'transitive hook invalidates caller signature cache');
			}
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+ 'public static inline var BASE=$BASE;\npublic static inline var COUNT=$COUNT;\n'+bodies.toString()
			+ 'public static function bound(kind:Int):Int return switch(kind) {\n'+bounds.toString()+'default:0; };\n'
			+ 'public static function entryCount(kind:Int):Int return switch(kind) {\n'+counts.toString()+'default:0; };\n'
			+ 'public static function entryAddress(kind:Int,entry:Int):Int return switch(kind) {\n'+entries.toString()+'default:-1; };\n'
			+ 'public static function resume(fn:Int,entry:Int,ctx:CpuState):Void { switch(fn) {\n'+resume.toString()+'default: } }\n'
			+ 'public static function dispatch(addr:Int,ctx:CpuState):Bool { switch(addr) {\n'+dispatch.toString()+'default:return false; } }\n}\n';
	}
	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/ComposeOptimized.hx',source(true,check));
		File.saveContent('out/_codegen/fixtures/ComposeReference.hx',source(false,check));
	}
	public static function main():Void generate(false);
	static function probe(words:Array<Int>):Emitter {
		final bytes=haxe.io.Bytes.alloc(words.length*4);
		for(i in 0...words.length) bytes.setInt32(i*4,words[i]);
		final image=new Image('composition rejection',BASE,bytes); final d=new Discovery(image);
		d.addSeed(BASE,Discovery.defaultName(BASE),Confidence.Entry); d.run(false);
		final emitter=new Emitter(image,d);
		emitter.staticTargetOf=a->d.functions.exists(a)?'Probe':null;
		return emitter;
	}
	@:access(recomp.codegen.Emitter)
	static function boundaries():Void {
		final recursive=probe([move(16,31),TestCodegen.jal(BASE),0,move(31,16),JR,0]);
		Assert.isTrue(recursive.scalarPlan(recursive.discovery.functions.get(BASE))==null,'recursive signatures are rejected');
		final mutual=[move(16,31),TestCodegen.jal(BASE+256),0,move(31,16),JR,0];
		while(mutual.length<64) mutual.push(0);
		for(word in [move(17,31),TestCodegen.jal(BASE),0,move(31,17),JR,0]) mutual.push(word);
		final cycle=probe(mutual);
		Assert.isTrue(cycle.scalarPlan(cycle.discovery.functions.get(BASE))==null,'mutual recursion cannot consume pending plans');
		Assert.isTrue(cycle.scalarPlan(cycle.discovery.functions.get(BASE+256))==null,'both recursive frames stay generic');
		final large:Array<Int>=[];
		for(level in 0...2) {
			while(large.length<level*64) large.push(0);
			large.push(move(16+level,31));
			for(_ in 0...9) { large.push(TestCodegen.jal(BASE+(level+1)*256)); large.push(0); }
			for(word in [move(31,16+level),JR,0]) large.push(word);
		}
		while(large.length<128) large.push(0);
		for(_ in 0...28) large.push(imm(9,2,2,1));
		large.push(JR); large.push(0);
		final bounded=probe(large);
		Assert.isTrue(bounded.scalarPlan(bounded.discovery.functions.get(BASE+256))!=null,'bounded child composition is accepted');
		Assert.isTrue(bounded.scalarPlan(bounded.discovery.functions.get(BASE))==null,'transitive accounting lanes cannot overflow');
	}
	static function memoryFlow():Void {
		final graph=new ScalarGraph(); final value=graph.initial[31]; final facts=new ScalarMemoryValues();
		facts.store('stack',12,4,value); final left=facts.copy(); final right=facts.copy();
		left.store('stack',4,4,graph.initial[4]); right.store('stack',8,4,graph.initial[5]);
		Assert.isTrue(ScalarMemoryValues.intersect([left,right]).load('stack',12,4,false,graph)==value,'disjoint stores preserve a common saved value');
		left.store('stack',15,1,graph.initial[0]);
		Assert.isTrue(ScalarMemoryValues.intersect([left,right]).load('stack',12,4,false,graph)==null,'partial overwrite on one path kills whole-word fact');
		Assert.isTrue(facts.load('stack',12,4,false,graph)==value,'mutating a successor does not mutate its predecessor snapshot');
		right.store('other',0,4,graph.initial[0]);
		Assert.isTrue(ScalarMemoryValues.intersect([facts,right]).load('stack',12,4,false,graph)==null,'another possibly aliased span kills the saved fact');
		final a=new ScalarMemoryValues(); final b=new ScalarMemoryValues();
		a.remember('stack',0,4,new ScalarValue('old',[],'load()'),0);
		b.remember('stack',0,4,new ScalarValue('new',[],'load()'),0);
		Assert.isTrue(ScalarMemoryValues.intersect([a,b]).load('stack',0,4,false,graph)==null,'identical load text does not identify memory versions');
		final guarded=new ScalarGraph(); guarded.memory=new ScalarMemory();
		final stack=guarded.memory.add(29,-4,4); final other=guarded.memory.add(4,0,4); final third=guarded.memory.add(5,0,4);
		final saved=new ScalarMemoryValues(); saved.store(stack.name,0,4,guarded.initial[31]);
		final l=saved.copy(); final r=saved.copy();
		l.invalidate(other.name,0,4,true); r.invalidate(third.name,0,1,true);
		Assert.equals(guarded.memory.separations.length,0,'unused memory facts do not request alias guards');
		Assert.isTrue(ScalarMemoryValues.intersect([l,r]).load(stack.name,0,4,false,guarded)==guarded.initial[31],
			'joined saved value is reusable behind all path exclusions');
		Assert.equals(guarded.memory.separations.length,2,'join carries every path exclusion');
		Assert.isTrue(saved.load(stack.name,0,4,false,graph)==guarded.initial[31],'guard exclusions do not mutate snapshots');
		final pair=guarded.memory.separations[0]; guarded.memory.requireSeparate(pair.b,pair.a);
		Assert.equals(guarded.memory.separations.length,2,'symmetric duplicate exclusion is emitted once');
		final budget=new ScalarMemory(); final first=budget.add(4,0,4); final second=budget.add(5,0,4);
		budget.add(4,128,4);
		for(i in 0...16) budget.requireSeparate(new ScalarWrite(first.name,i*8,4),new ScalarWrite(second.name,0,4));
		Assert.isTrue(budget.possible(),'bounded alias guard budget');
		budget.requireSeparate(new ScalarWrite(first.name,128,4),new ScalarWrite(second.name,0,4));
		Assert.isTrue(!budget.possible(),'excessive alias guards reject the whole helper, never drop checks');
		final joined=new ScalarMemory();
		for (offset in [0,4]) for (n in 0...3) joined.requireSeparate(new ScalarWrite('saved',offset,4),
			new ScalarWrite('writes',n==0?0:n==1?1:5,n==0?1:4));
		Assert.equals(joined.separations.length,1,'adjacent saved words and writes need one equivalent guard');
		final wide=joined.separations[0];
		Assert.equals(wide.a.width+wide.b.width,17,'coalesced exclusion covers exactly eight and nine bytes');
		// Compare the original conjunction with the merged condition for every relative
		// placement around both endpoints, including all byte-sized partial overlaps.
		for (savedBase in -16...16) for (writeBase in -16...16) {
			var expected=true;
			for (offset in [0,4]) for (n in 0...3) {
				final a=savedBase+offset; final b=writeBase+(n==0?0:n==1?1:5); final width=n==0?1:4;
				if (!(a+4<=b || b+width<=a)) expected=false;
			}
			final a=(wide.a.span=='saved'?savedBase:writeBase)+wide.a.offset;
			final b=(wide.b.span=='saved'?savedBase:writeBase)+wide.b.offset;
			Assert.equals(a+wide.a.width<=b || b+wide.b.width<=a,expected,'coalesced guard has exactly the original truth condition');
		}
	}
	public static function run():Void {
		Assert.group('composed scalar calls: signatures, stack facts and observation horizons');
		generate(true); boundaries(); memoryFlow();
	}
}
