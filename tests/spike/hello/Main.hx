package;

function main() {
	trace("recompsx spike: hello from module Main");
	Helper.greet(3);
	trace("sum(10) = " + Helper.sum(10));
	trace("wrap check: " + Helper.wrapCheck());
	trace("shift check: " + Helper.shiftCheck());
}
