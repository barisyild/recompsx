import recomp.analysis.Confidence;
import recomp.analysis.Discovery;
import recomp.analysis.Image;
import recomp.codegen.Emitter;
import recomp.codegen.ScalarEntry;
import sys.io.File;

/** Dependent reads and cross-call memory versions, regenerated from synthetic guest code. */
@:access(TestCodegen)
class TestScalarPointers {
	static inline var BASE = 0x80190000;
	static inline var JR = 0x03e00008;
	static inline var COUNT = 58;
	static function imm(op:Int, rt:Int, rs:Int, n:Int):Int return TestCodegen.imm(op,rt,rs,n);
	static function move(rd:Int, rs:Int):Int return TestCodegen.alu(0x21,rd,rs,0);
	static function words(kind:Int, base:Int):Array<Int> {
		final child = base+(kind>=51?2048:256); final grand = base+(kind>=51?3072:384);
		var root = [imm(0x23,8,4,0), JR, imm(0x24,2,8,0)];
		var leaf = [JR, imm(0x23,2,4,0)];
		var second = [JR, imm(0x23,2,4,0)];
		switch(kind) {
			case 1: root = [imm(0x23,8,4,0), imm(0x23,9,8,0), JR, imm(0x24,2,9,0)];
			case 2: root = [imm(0x23,8,4,4), imm(9,8,8,4), JR, imm(0x24,2,8,-4)];
			case 3: root = [imm(0x28,7,5,0), imm(0x23,8,4,0), JR, imm(0x24,2,8,0)];
			case 4: root = [imm(0x23,8,4,0), imm(0x28,7,5,0), JR, imm(0x24,2,8,0)];
			case 5: root = [imm(0x28,7,4,0), imm(0x23,8,4,0), JR, imm(0x24,2,8,0)];
			case 6: root = [imm(0x2b,5,4,0), imm(0x23,8,4,0), JR, imm(0x24,2,8,0)];
			case 7: root = [imm(0x23,8,4,0), imm(0x23,9,4,4), imm(0x28,7,5,0), imm(0x24,2,8,0), JR, imm(0x24,3,9,0)];
			case 8 | 9 | 10 | 11:
				root = [imm(kind==8?0x21:kind==9?0x25:kind==10?0x20:0x24,8,4,0), imm(9,8,8,256), JR, imm(0x24,2,8,0)];
			case 12: root = [imm(4,0,6,4), 0, imm(0x23,8,4,0), JR, imm(0x24,2,8,0), JR, imm(9,2,0,7)];
			case 13:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,-4)];
				leaf = [imm(0x23,2,4,0), JR, imm(9,2,2,4)];
			case 14:
				root = [move(16,31), imm(0x23,4,4,0), TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = [imm(0x24,3,4,0), JR, imm(9,2,4,4)];
			case 15:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = [imm(0x23,8,4,0), JR, imm(0x24,2,8,0)];
			case 16:
				root = [move(16,31), imm(0x28,7,5,0), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,0)];
				leaf = [move(17,31), TestCodegen.jal(grand), 0, move(31,17), JR, 0];
			case 17 | 18:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,0)];
				leaf = kind==17 ? [imm(0x23,2,4,0), JR, imm(0x28,7,5,0)]
					: [imm(0x28,7,4,0), JR, imm(0x23,2,4,0)];
			case 19 | 20:
				root = [move(16,31), TestCodegen.jal(child), 0, imm(0x24,3,2,0),
					imm(0x28,7,kind==19?4:5,0), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,8,2,0)];
			case 21:
				root = [move(16,31), imm(0x28,7,5,0), TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = [imm(0x23,8,4,0), JR, imm(0x24,2,8,0)];
			case 22: root = [imm(0x23,8,4,0), imm(9,8,8,4), JR, imm(0x24,2,8,0)];
			case 23:
				root = [move(16,31), imm(0x28,7,5,0), TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = [imm(0x23,8,4,0), imm(0x23,9,8,0), JR, imm(0x24,2,9,0)];
			case 24:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,0)];
				leaf = [imm(0x28,7,5,0), imm(0x23,2,4,0), JR, 0];
			case 25:
				root = [move(16,31), imm(0x23,4,4,0), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,-4)];
				leaf = [JR, imm(9,2,4,4)];
			case 26:
				root = [imm(0x23,8,4,0), imm(0x28,7,5,0), imm(0x23,9,4,0), imm(0x24,2,8,0), JR, imm(0x24,3,9,0)];
			case 27:
				root = [imm(0x23,8,4,0), imm(0x24,2,8,0), imm(0x2b,6,4,0), imm(0x28,7,5,0),
					TestCodegen.alu(0x26,3,6,10), JR, TestCodegen.alu(0x26,3,3,8)];
			case 28:
				root = [imm(0x23,8,4,0), imm(0x24,2,8,0), imm(0x28,7,4,0), JR, imm(0x23,3,4,0)];
			case 29:
				root = [imm(0x21,8,4,0), imm(9,8,8,256), imm(0x28,7,5,0), imm(0x25,9,4,0),
					imm(9,9,9,256), imm(0x24,2,8,0), JR, imm(0x24,3,9,0)];
			case 30: root = [imm(0x23,8,4,0), JR, imm(0x28,7,8,0)];
			case 31: root = [imm(0x23,8,4,0), JR, imm(0x24,0,8,0)];
			case 32:
				root = [imm(0x23,8,4,0), imm(0x24,0,8,0), move(5,4), move(4,8), JR, imm(9,8,8,4)];
			case 33:
				root = [imm(0x23,8,4,0), imm(4,0,6,4), 0, imm(0x28,7,8,0), JR, 0, JR, 0];
			case 34 | 35:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = kind==34 ? [imm(0x23,8,4,0), JR, imm(0x28,7,8,0)]
					: [imm(4,0,6,4), 0, imm(0x23,8,4,0), JR, imm(0x24,2,8,0), JR, imm(9,2,0,7)];
			case 36:
				root = [move(16,31), TestCodegen.jal(child), 0, move(9,8), imm(0x28,7,5,0),
					TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = [imm(0x23,8,4,0), JR, imm(0x24,0,8,0)];
			case 37:
				root = [move(16,31), imm(4,0,6,4), 0, TestCodegen.jal(child), 0, move(31,16), JR, 0];
				leaf = [imm(0x23,8,4,0), JR, imm(0x28,7,8,0)];
			case 38 | 45:
				root = [move(16,31), TestCodegen.jal(child), 0, imm(0x24,8,2,0), move(31,16), JR, imm(0x24,9,3,0)];
				leaf = kind==38 ? [imm(0x23,2,4,0), JR, imm(0x23,3,4,4)]
					: [imm(0x21,2,4,0), imm(0x25,3,4,0), imm(9,2,2,256), JR, imm(9,3,3,256)];
			case 39:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,8,3,0)];
				leaf = [imm(0x23,3,4,0), JR, TestCodegen.alu(0x26,2,6,7)];
			case 40 | 42 | 43 | 44 | 46:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,0)];
				leaf = switch(kind) {
					case 40: [imm(4,0,6,3), 0, JR, imm(0x23,2,4,0), JR, imm(9,2,5,4)];
					case 42: [imm(0x23,2,4,0), imm(4,0,6,3), 0, 0, 0, JR, 0];
					case 43: [imm(0x23,2,4,0), JR, imm(0x24,0,5,0)];
					case 44: [imm(0x23,2,4,0), imm(4,0,6,3), 0, imm(0x28,7,5,0), 0, JR, 0];
					case _: [imm(0x23,2,4,0), JR, imm(0x28,7,4,0)];
				};
			case 41:
				root = [move(16,31), imm(4,0,6,5), 0, TestCodegen.jal(child), 0,
					imm(0x24,3,2,0), move(31,16), JR, 0];
			case 47:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,3,2,0)];
				leaf = [imm(0x29,7,4,0), imm(0x21,2,4,0), JR, imm(9,2,2,256)];
			case 48 | 50:
				root = [move(16,31), TestCodegen.jal(child), 0, imm(0x24,8,2,0), move(31,16), JR, imm(0x24,9,3,0)];
				leaf = kind==48 ? [imm(0x23,2,4,0), imm(0x24,3,4,1), JR, imm(9,3,3,256)]
					: [imm(0x28,7,5,0), imm(0x21,2,4,0), imm(0x25,3,4,0), imm(9,2,2,256), JR, imm(9,3,3,256)];
			case 49:
				root = [move(16,31), TestCodegen.jal(child), 0, move(31,16), JR, imm(0x24,8,2,0)];
				leaf = [imm(0x23,2,4,0), imm(4,0,6,4), 0, imm(0x24,3,4,1), JR, imm(9,3,3,256), JR, imm(9,3,0,192)];
			case 51 | 54:
				root = [for(_ in 0...(kind==51?96:255)) 0].concat(root);
			case 52 | 53:
				root = [imm(0x23,8,4,0)];
				for(_ in 0...(kind==52?60:100)) root.push(TestCodegen.alu(0x26,2,2,6));
				root = root.concat([JR,imm(0x24,3,8,0)]);
			case 55:
				root = [imm(0x23,8,4,0),imm(4,0,6,27),0];
				for(_ in 0...24) root.push(TestCodegen.alu(0x26,2,2,7));
				root = root.concat([JR,imm(0x24,3,8,0)]);
				for(_ in 0...25) root.push(imm(9,2,2,1));
				root = root.concat([JR,imm(0x24,3,8,0)]);
			case 56:
				root = [imm(0x23,8,4,0)];
				for(i in 0...40) root.push(imm(0x28,7,8,i));
				root = root.concat([JR,0]);
			case 57:
				root = [move(16,31),TestCodegen.jal(child),0,move(31,16),JR,imm(0x24,3,2,0)];
				leaf = [imm(0x23,2,4,0)].concat([for(_ in 0...96) 0]).concat([JR,0]);
			case _:
		}
		while(root.length<((child-base)>>2)) root.push(0);
		root = root.concat(leaf);
		while(root.length<((grand-base)>>2)) root.push(0);
		return root.concat(second);
	}
	static function source(opt:Bool, check:Bool):String {
		final cls = opt?'PointersOptimized':'PointersReference';
		final bodies = new StringBuf(); final dispatch = new StringBuf(); final resume = new StringBuf();
		final counts = new StringBuf(); final entries = new StringBuf(); final bounds = new StringBuf();
		final guards = new StringBuf();
		for(kind in 0...COUNT) {
			final base = BASE+(kind<<12); final w = words(kind,base); final bytes = haxe.io.Bytes.alloc(w.length*4);
			for(i in 0...w.length) bytes.setInt32(i*4,w[i]);
			final image = new Image('loaded pointer signatures',base,bytes); final d = new Discovery(image);
			d.addSeed(base,'pointer$kind',Confidence.Entry); d.run(false);
			final emitter = new Emitter(image,d,opt);
			emitter.staticTargetOf = a -> d.functions.exists(a)?cls:null;
			final fn = d.functions.get(base); final plan = emitter.scalarPlan(fn);
			if(check) {
				Assert.equals(plan!=null,opt && ![5,18,19,40,47,53,54].contains(kind),'loaded pointer eligibility $kind');
				if(plan!=null) {
					final helper = plan.emitHelper(); final guard = plan.memory.guard('');
					Assert.isTrue(helper.indexOf('ctx')<0,'loaded pointer helper has no CpuState');
					if(kind!=6) {
						Assert.isTrue(guard.indexOf('final pointer')>=0,'entry captures loaded pointer $kind');
						Assert.equals(ScalarEntry.borrowedAdapter(plan),'','dependent views cannot borrow unavailable input pointers');
					}
					if([3,16,20,21,24].contains(kind)) Assert.equals(plan.memory.separations.length,1,'prior possibly aliased writes need an exclusion');
					if(kind==23) Assert.equals(plan.memory.separations.length,2,'all dependent read sources exclude the caller prefix');
					if([4,7,17].contains(kind)) Assert.equals(plan.memory.separations.length,0,'later writes do not invalidate an earlier pointer');
					if(kind==20) Assert.equals(plan.memory.reads.filter(r->r.active).length,2,'separate calls retain distinct pointer versions');
					Assert.isTrue(plan.inputs.length+plan.signature.spans.length+plan.signature.samples.length<=6,'lowered parameter budget');
					if([0,1,2,3,4,7,8,9,10,11,12,14,15,21,22,23,25,26,30,31,32,33,34,35,36,37].contains(kind)) {
						Assert.isTrue(helper.indexOf('Memory.spanRead32')<0,'selected pointer reads are absent from helper body');
					}
					if([0,1,2,3,4,8,9,10,11,14,15,21,22,23,25,30,31,32,33,34,36].contains(kind)) {
						Assert.isTrue(helper.indexOf('core.ScalarResult.value')<0,'known samples do not cross result slots');
						Assert.isTrue(plan.apply('').indexOf('pointer')>=0,'boundary reconstructs the known sample output');
					}
					if([30,31,32,33,34,36].contains(kind)) {
						Assert.isTrue(helper.indexOf('):Void')>=0,'all-known outputs permit a Void helper');
						Assert.isTrue(plan.apply('').indexOf('scalarResult0')<0,'Void call is never used as an Int');
						Assert.isTrue(plan.emitHelper('Other').indexOf('return Other')<0,'Void forwarding adapter emits a statement');
					}
					if([12,35,37].contains(kind)) Assert.isTrue(helper.indexOf('):Int')>=0,'conditional values still cross the result ABI');
					if(kind==32) Assert.isTrue(plan.apply('').indexOf('scalarInput4')>=0,'overwritten input is captured before reconstruction');
					if(kind==1) {
						Assert.equals(plan.signature.spans.length,1,'chain source views remain only in the guard');
						Assert.equals(plan.signature.samples.length,0,'boundary-only chain values need no helper parameters');
					}
					if(kind==20 || kind==26) Assert.equals(guard.split('Memory.spanRead32').length-1,1,'equal entry samples read RAM only once');
					if(kind==26) {
						Assert.equals(plan.signature.samples.length,0,'two boundary-only versions need no numeric sample argument');
						Assert.equals(plan.memory.separations.length,1,'shared sample retains the later version exclusion');
					}
					if(kind==27) {
						Assert.equals(plan.signature.samples.length,0,'sample cannot grow a six-argument signature');
						Assert.equals(helper.split('Memory.spanRead32').length-1,1,'budget fallback keeps the ordered helper load');
					}
					if(kind==28) {
						Assert.equals(plan.signature.samples.length,0,'earlier pointer is reconstructed only at the boundary');
						Assert.equals(helper.split('Memory.spanRead32').length-1,1,'later unproved version with the same source still reads RAM');
					}
					if(kind==29) {
						Assert.equals(plan.signature.samples.length,0,'extended boundary outputs need no helper parameters');
						Assert.equals(guard.split('Memory.spanRead16').length-1,2,'sample coalescing includes signedness');
						Assert.isTrue(helper.indexOf('Memory.spanRead16')<0,'both extended inputs replace their helper loads');
					}
					if(kind==36) {
						Assert.equals(plan.memory.reads.filter(r->r.active).length,2,'Void child outputs preserve distinct read versions');
						Assert.equals(plan.memory.separations.length,1,'second reconstructed child output excludes earlier writes');
					}
					if([13,16,20,38,43,45,48].contains(kind)) {
						Assert.isTrue(helper.indexOf(cls+'.f_')<0,'read-only child result proof removes the call $kind');
						Assert.isTrue(plan.apply('').indexOf('pointer')>=0,'imported result equality reconstructs the output $kind');
						Assert.equals(plan.accounting.addressBase,0,'fixed nested charges remain constant $kind');
					}
					if([17,24,39,41,42,44,46,49,50].contains(kind))
						Assert.isTrue(helper.indexOf(cls+'.f_')>=0,'effects, computed results, conditional calls or dynamic costs retain the child $kind');
					if(kind==39) Assert.isTrue(helper.indexOf('= core.ScalarResult.value')<0,'unused secondary result capture disappears while primary call remains');
					if(kind==42) {
						Assert.isTrue(helper.indexOf('= core.ScalarResult.accounting')>=0,'dynamic child charge still captured');
						Assert.equals(plan.accounting.addressBase,-1,'path-dependent charge cannot become constant');
					}
					if(kind==43) Assert.equals(plan.memory.spans.length,3,'dead zero-target child read keeps its complete guard');
					if(kind==45) Assert.equals(guard.split('Memory.spanRead16').length-1,2,'imported signed/unsigned return summaries stay distinct');
					if(kind==48) Assert.equals(guard.split('Memory.spanRead8u').length-1,1,'forwarded byte read retains its source offset and width');
					if(kind==50) Assert.equals(plan.memory.separations.length,1,'both converted return versions exclude the preceding write');
					if([51,52,55,56].contains(kind)) Assert.isTrue(fn.instructionCount()>32,'larger function is admitted by recovered body cost');
					if(kind==51) Assert.isTrue(helper.split('\n').length<8,'many dead guest instructions still yield a small helper');
					if(kind==56) Assert.equals(helper.split('Memory.spanWrite8').length-1,40,'every larger ordered effect remains present');
					if(kind==57) {
						Assert.isTrue(helper.indexOf(cls+'.f_')<0,'large compact child can disappear after its returned-read proof');
						Assert.isTrue(plan.bounds.instructions>100,'removed large child retains its full guest charge');
					}
				}
			}
			guards.add('case $kind:\n');
			if(plan!=null) guards.add(plan.memory.guard('\t')+'\t\treturn true;\n\t} else { return false; }\n');
			else guards.add('return false;\n');
			bounds.add('case $kind: ${plan==null?0:plan.bounds.cycles};\n');
			final blocks = Emitter.blockOrder(fn);
			counts.add('case $kind: ${blocks.length};\n'); entries.add('case $kind: switch(entry) {\n');
			for(i in 0...blocks.length) entries.add('case $i: ${blocks[i]};\n');
			entries.add('default:-1; }\n');
			final functions = [for(a in d.functions.keys()) a]; functions.sort((a,b)->a-b);
			for(a in functions) {
				final f = d.functions.get(a); bodies.add(emitter.emitFunction(f));
				resume.add('case $a: ${f.name}(ctx,entry);\n');
				for(addr in Emitter.blockOrder(f)) {
					final entry = Emitter.blockOrder(f).indexOf(addr);
					dispatch.add('case $addr: ${f.name}(ctx,$entry); return true;\n');
				}
			}
		}
		return 'import core.CpuState;\nimport core.Runtime;\nimport core.Ops;\nimport mem.Memory;\nimport kernel.Kernel;\nimport gte.Gte;\nclass $cls {\n'
			+'public static inline var COUNT=$COUNT;\n'+bodies.toString()
			+'public static function guarded(kind:Int,ctx:CpuState):Bool { switch(kind) {\n'+guards.toString()+'default:return false; } }\n'
			+'public static function bound(kind:Int):Int return switch(kind) {\n'+bounds.toString()+'default:0; };\n'
			+'public static function entryCount(kind:Int):Int return switch(kind) {\n'+counts.toString()+'default:0; };\n'
			+'public static function entryAddress(kind:Int,entry:Int):Int return switch(kind) {\n'+entries.toString()+'default:-1; };\n'
			+'public static function resume(fn:Int,entry:Int,ctx:CpuState):Void { switch(fn) {\n'+resume.toString()+'default: } }\n'
			+'public static function dispatch(addr:Int,ctx:CpuState):Bool { switch(addr) {\n'+dispatch.toString()+'default:return false; } }\n}\n';
	}
	static function generate(check:Bool):Void {
		sys.FileSystem.createDirectory('out/_codegen/fixtures');
		File.saveContent('out/_codegen/fixtures/PointersOptimized.hx',source(true,check));
		File.saveContent('out/_codegen/fixtures/PointersReference.hx',source(false,check));
	}
	public static function main():Void generate(false);
	public static function run():Void { Assert.group('loaded pointer versions, preflight and call translation'); generate(true); }
}
