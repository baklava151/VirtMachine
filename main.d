import std.stdio;
import std.string;
import std.file;
import std.exception;
import std.path;
import VM;

void main(string[] args)
{
	if(args.length != 2)
	{
		throw new Error(format("\nUsage: %s inputfile", args[0].baseName()));
	}
	string file = args[1]; // File should be passed as first argument
    enforce(exists(file), "File \"" ~ file ~ "\" does not exist");

    writeln("File found, loading");
    File input = File(file, "r");

    VM vm = new VM();
    vm.load(input);
    vm.run();
}