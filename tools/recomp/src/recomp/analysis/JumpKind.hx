package recomp.analysis;

/**
	What a computed jump turned out to be.

	`jr` through a register is the one instruction whose meaning is genuinely ambiguous without
	analysis: it dispatches a switch, calls the BIOS, or tail-calls through a function pointer.
	Distinguishing them matters — a switch becomes control flow inside the function, a kernel call
	becomes a call to the HLE, and only what remains needs a runtime address lookup.
**/
enum JumpKind {
	/** A dense switch: the register was loaded from a table indexed by a bounded value. */
	Table(table:JumpTable);

	/**
		A constant target. Overwhelmingly this is a BIOS call, which the Psy-Q convention writes as

		```
		addiu $t2, $zero, 0xB0    ; the vector
		jr    $t2
		 addiu $t1, $zero, 0x19   ; the function number, in the delay slot
		```

		`vector` is 0xA0, 0xB0 or 0xC0 for a kernel call, and `fnNumber` the value in $t1 when it
		could be determined (-1 otherwise). Any other constant is an ordinary direct jump that the
		compiler happened to route through a register.
	**/
	Constant(target:Int, fnNumber:Int);

	/** Nothing conclusive. The runtime will dispatch it by address, which is always correct. */
	Unresolved;
}
