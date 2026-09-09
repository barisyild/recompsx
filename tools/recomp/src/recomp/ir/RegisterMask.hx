package recomp.ir;

/** GPR data flow on a primitive Int. $zero never becomes a dependency or a destination. */
abstract RegisterMask(Int) from Int to Int {
	public inline function withRegister(register:Int):RegisterMask
		return register == 0 ? this : this | (1 << register);

	public inline function has(register:Int):Bool return (this & (1 << register)) != 0;
}
