module VM;

import std.stdio;
import std.conv;
import core.checkedint;

enum OPERANDS { REG = 1, IDATA = 2, ADDR = 4 };
enum INS { HALT, READC, READB, READH, READW, WRITEC, WRITEB, WRITEH, WRITEW, PUSH, POP, MOV, ADD, SUB, MUL, DIV };
		 //0	 1		2	   3	  4		 5		 6		 7		 8		 9	   10	11	 12	  13   14   15
enum STACK_SIZE = 2^^16;
enum NUM_REGS = 16;
enum EXC { DIV_BY_ZERO };

struct Flags
{
	bool overflow;
	bool zero;
	bool negative;
}

class VM
{
    private:
		int[NUM_REGS] regs;
		int exception_reg;
		ushort code_ptr, data_ptr;
		ushort stack_ptr;
		int[] code_seg;
		int[] data_seg;
		int[STACK_SIZE] stack_seg;
		ushort ins, ins_flags;
		ushort code_size, data_size;
		int addr;
		int *op1;
		int *op2;
		int tmp1, tmp2;
		bool op_switch = true;
		Flags flags;

    public this()
    {
		op1 = &tmp1;
		op2 = &tmp2;		
    }

    /**
	 * Load up the code and data section from the file
	 * Params: input is the binary file to run
	 */
    public void load(File input)
	out
	{
		assert(code_size > 0);
	}
	body
    {
		code_size = input.rawRead(new ushort[1])[0]; //Grab size of the code segment
		data_size = input.rawRead(new ushort[1])[0]; //Grab size of the data segment
		if(code_size) code_seg = input.rawRead(new int[code_size]);
		if(data_size) data_seg = input.rawRead(new int[data_size]);
		debug(load)
		{
			writeln(this.code_size);
			writeln(this.data_size);
			writeln(code_seg.length);
			writeln(data_seg.length);
		}
    }
	
	/**
	 * Runs through the code segment and executes each instruction
	 **/ 
    public void run()
    {
		for(; code_ptr < code_size; ++code_ptr)
		{
		    exec_ins(code_seg[code_ptr]);
		}
    }

    /**
	 * Stops the virtual machine
	 **/
    private void halt()
    {
		writeln("HALTING");
		import core.runtime: Runtime;
		import core.stdc.stdlib: exit;
		Runtime.terminate();
		exit(0);	
    }
	
	/**
	 * Reads length Ts from stdin to dest
	 * Params:
	 *		dest holds a pointer to the beginning of memory to be read to
	 *		length holds the amount of Ts to be read
	 **/
	private void read(T)(int *dest, in ulong length)
	{
		foreach(i; 0..length)
		{
			readf("%s", cast(T *) &dest[i]);
		}
	}

	/**
	 * Writes length Ts from src to stdout
	 * Params:
	 *		src holds a pointer to the beginning of memory to be read from
	 *		length hold the amount of Ts to write
	 **/
	private void write(T)(int *src, in uint length)
	{
		foreach(i; 0..length)
		{
			writef("%s", cast(T) src[i]);
		}
	}

	/**
	 * Pushes a value onto the stack
	 * Params:
	 *		op1 holds value to be pushed
	 **/
	private void push(in int op1)
	{
		if(stack_ptr == STACK_SIZE)
		{
			throw new Error("Hit upper limit of the stack!");
		}
		stack_seg[stack_ptr] = cast(int) op1;
		debug(push)
		{
			writeln("Pushing: ", stack_seg[stack_ptr]);
		}
		++stack_ptr;
	}

	/**
	 * Pops a value off the stack
	 * Params:
	 *		op1 holds the destination address
	 **/
	private void pop(int *op1)
	{
		if(stack_ptr == 0)
		{
			throw new Error("The stack is empty!");
		}
		--stack_ptr;
		debug(pop)
		{
			writeln("Popping: ", stack_seg[stack_ptr]);
		}
		*op1 = stack_seg[stack_ptr];
	}

	/**
	 * Moves the value in op1 to *op2
	 * Params:
	 * 		op1 holds the value to be moved
	 *		*op2 holds where the value is being moved
	 **/
	private void mov(in int op1, int *op2)
	{
		debug (move) { writeln("Moving"); }
		*op2 = op1;
	}

	/**
	 * Adds op1 and *op2
	 * Can set overflow, negative or zero flag
	 * Params:
	 *		op1 is the first value
	 *		*op2 holds the second value and where the result gets stored
	 **/
	private void add(int op1, int *op2)
	{
		debug(add) { writeln("Adding"); }
		*op2 = adds(op1, *op2, flags.overflow);
		flags.negative = *op2 < 0;
		flags.zero = *op2 == 0;
	}

	/**
	 * Subtracts op1 from *op2
	 * Can set overflow, negative or zero flag
	 * Params:
	 *		op1 is the first value
	 *		*op2 holds the second value and where the result gets stored
	 **/
	private void sub(int op1, int *op2)
	{
		debug(sub) { writeln("Subtracting"); }
		*op2 = subs(*op2, op1, flags.overflow);
		flags.negative = *op2 < 0;
		flags.zero = *op2 == 0;
	}

	/**
	 * Multiplies op1 and *op2
	 * Can set overflow, negative or zero flag
	 * Params:
	 *		op1 is the first value
	 *		*op2 is the second value and is where the result gets stored
	 **/
	private void mul(int op1, int *op2)
	{
		debug(mul) { writeln("Multiplying"); }
		*op2 = muls(op1, *op2, flags.overflow);
		flags.zero = *op2 == 0;
		flags.negative = *op2 < 0;
	}

	/**
	 * Divides *op2 by op1
	 * Can set negative or zero flag
	 * Params:
	 *		op1 is the first value
	 *		*op2 is the second value and is where the result gets stored
	 **/
	private void div(int op1, int *op2)
	{
		debug(div) { writeln("Dividing"); }
		if(op1 == 0) 
		{
			stdout.flush();
			exception_reg = EXC.DIV_BY_ZERO;
		}
		else
		{
			*op2 = *op2 / op1;
			flags.zero = *op2 == 0;
			flags.negative = *op2 < 0;
		}
	}

    /**
	 * Executes the given instruction
	 * Format in binary is op2 flags, op1 flags, then instruction itself
	 * Params:
	 *		instr holds the value of the next instruction to execute and its flags
	 **/
    public void exec_ins(in uint instr)
    {
		ins_flags = cast(ushort) (instr & 0xFFFF);
		ins = cast(ushort) ((instr >> 16) & 0xFFFF);

		void get_ops(ref int *op, in ubyte flags)
		in
		{
			assert(ins >= INS.min && ins <= INS.max, "Invalid instruction");
			assert(flags == OPERANDS.REG || flags == OPERANDS.IDATA || flags == OPERANDS.ADDR, "Invalid flags");
		}
		out
		{
			if(data_seg.length > 0)
			{
				assert((op1 >= &regs[0] && op1 <= &regs[15]) || (op1 >= &data_seg[0] && op1 <= &data_seg[data_size - 1]) || (op1 == &tmp1), "Fail on op1");
				assert((op2 >= &regs[0] && op2 <= &regs[15]) || (op2 >= &data_seg[0] && op2 <= &data_seg[data_size - 1]) || (op2 == &tmp2), "Fail on op2");
			}
			else
			{
				assert((op1 >= &regs[0] && op1 <= &regs[15]) || (op1 == &tmp1), "Fail on op1");
				assert((op2 >= &regs[0] && op2 <= &regs[15]) || (op2 == &tmp2), "Fail on op2");
			}
		}
		body
		{
			++code_ptr;
			addr = code_seg[code_ptr];
			
			debug (get_op)
			{
				writeln("Address: ", addr);
				writeln("Flags: ", flags);
			}

			final switch(flags)
			{
				case OPERANDS.REG:
					op = &regs[addr];
					break;
				case OPERANDS.IDATA:
					if(op_switch)
					{
						op1 = &tmp1;
					}
					else
					{
						op2 = &tmp2;
					}
					*op = addr;
					break;
				case OPERANDS.ADDR:
					op = &data_seg[addr];
					break;
			}

			op_switch = !op_switch;

			debug (get_op)
			{
				writeln("Operand: ", *op);
			}
		}

		debug (ins_flag)
		{
			writeln("Instruction: ", ins);
			writeln("Flags: ", ins_flags);
		}

		final switch(ins)
		{
		    case INS.HALT:
				halt();
				break;
			case INS.READC:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				read!char(cast(int *) op1, *op2);
				break;
			case INS.READB:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				read!byte(cast(int *) op1, *op2);
				break;
			case INS.READH:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				read!short(cast(int *) op1, *op2);
				break;
			case INS.READW:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				read!int(cast(int *) op1, *op2);
				break;
			case INS.WRITEC:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				write!char(cast(int *) op1, *op2);
				break;
			case INS.WRITEB:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				write!byte(cast(int *) op1, *op2);
				break;
			case INS.WRITEH:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				write!short(cast(int *) op1, *op2);
				break;
			case INS.WRITEW:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				write!int(cast(int *) op1, *op2);
				break;
			case INS.PUSH:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				push(*op1);
				break;
			case INS.POP:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				pop(op1);
				break;
			case INS.MOV:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				mov(*op1, op2);
				break;
			case INS.ADD:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				add(*op1, op2);
				break;
			case INS.SUB:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				sub(*op1, op2);
				break;
			case INS.MUL:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				mul(*op1, op2);
				break;
			case INS.DIV:
				get_ops(op1, (ins_flags >> 8) & 0xFF);
				get_ops(op2, ins_flags & 0xFF);
				div(*op1, op2);
				break;
		}

		op_switch = true;
    }
}