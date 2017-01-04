module VM;

import std.stdio;
import std.conv;
import core.checkedint;

enum OPERANDS { REG = 1, IDATA = 2, ADDR = 4 };
enum INS { HALT, RDC, RDB, RDH, RDW, WRC, WRB, WRH, WRW,
         //0     1    2    3    4    5    6    7    8
           PUSH, POP, MOV, ADD, SUB, MUL, DIV, UADD, USUB, UMUL, UDIV, URDW, UWRW,
         //9     10   11   12   13   14   15   16    17    18    19	   20    21
           CMP, UCMP, JMP, JE, JNE, JG, JGE, JL, JLE, JZ, JNZ };
         //22   23    24   25  26   27  28   29  30   31  32
enum STACK_SIZE = 2^^16;
enum NUM_REGS = 16;
enum EXC { DIV_BY_ZERO };

struct Flags
{
    bool overflow;
    bool zero;
    bool negative;
    bool eq;
    bool lt;
    bool gt;
}

class VM
{
private:
    int[NUM_REGS] regs;
    int exception_reg;
    ushort code_ptr, data_ptr;
    ushort stack_ptr;
    int[] code_seg; // The max size of the code and data segment is 65536
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
     * Params: 
     *      input is the binary file to run
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
        import core.runtime: Runtime;
        import core.stdc.stdlib: exit;
        Runtime.terminate();
        exit(0);	
    }
    
    /**
     * Reads length Ts from stdin to dest
     * Params:
     *      dest holds a pointer to the beginning of memory to be read to
     *      length holds the amount of Ts to be read
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
     *      src holds a pointer to the beginning of memory to be read from
     *      length hold the amount of Ts to write
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
     *      op1 holds value to be pushed
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
     *      op1 holds the destination address
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
     * Moves a value from a source to a destination
     * Params:
     *      op1 holds the value to be moved
     *      *op2 holds where the value is being moved
     **/
    private void mov(in int op1, int *op2)
    {
        debug (move) { writeln("Moving"); }
        *op2 = op1;
    }

    /**
     * Adds two signed values
     * Can set overflow, negative or zero flag
     * Params:
     *      op1 is the first value
     *      *op2 holds the second value and where the result gets stored
     **/
    private void add(int op1, int *op2)
    {
        debug(add) { writeln("Adding"); }
        *op2 = adds(op1, *op2, flags.overflow);
        flags.negative = *op2 < 0;
        flags.zero = *op2 == 0;
    }

    /**
     * Subtracts two signed values
     * Can set overflow, negative or zero flag
     * Params:
     *      op1 is the first value
     *      *op2 holds the second value and where the result gets stored
     **/
    private void sub(int op1, int *op2)
    {
        debug(sub) { writeln("Subtracting"); }
        *op2 = subs(*op2, op1, flags.overflow);
        flags.negative = *op2 < 0;
        flags.zero = *op2 == 0;
    }

    /**
     * Multiplies two signed values
     * Can set overflow, negative or zero flag
     * Params:
     *      op1 is the first value
     *      *op2 is the second value and is where the result gets stored
     **/
    private void mul(int op1, int *op2)
    {
        debug(mul) { writeln("Multiplying"); }
        *op2 = muls(op1, *op2, flags.overflow);
        flags.zero = *op2 == 0;
        flags.negative = *op2 < 0;
    }

    /**
     * Performs integer division two values
     * Can set negative or zero flag
     * Params:
     *      *op1 is the first value and where the remainder gets stored
     *      *op2 is the second value and is where the result gets stored
     **/
    private void div(int *op1, int *op2)
    {
        debug(div) { writeln("Dividing"); }
        if(*op1 == 0) 
        {
            stdout.flush();
            exception_reg = EXC.DIV_BY_ZERO;
        }
        else
        {
            int tmp = *op2 / *op1;
            *op1 = *op2 % *op1;
            *op2 = tmp;
            flags.zero = *op2 == 0;
            flags.negative = *op2 < 0;
        }
    }

    /**
     * Adds two unsigned values
     * Can set overflow or zero flag
     * Params:
     *      op1 is the first value
     *      *op2 is the second value and where the result gets stored
     **/
    private void uadd(uint op1, uint *op2)
    {
        debug(uadd) { writeln("Unsigned add"); }
        *op2 = addu(op1, *op2, flags.overflow);
        // Set negative flag to false?
        flags.zero = *op2 == 0;
    }

    /**
     * Subtracts two unsigned values
     * Can set overflow or zero flag
     * Params:
     *      op1 is the value to subtract
     *      *op2 is the value to be subtracted from and where the result gets stored
     **/
    private void usub(uint op1, uint *op2)
    {
        debug(usub) { writeln("Unsigned subtraction"); }
        *op2 = subu(*op2, op1, flags.overflow);
        // Set negative flag to false?
        flags.zero = *op2 == 0;
    }

    /**
     * Multiplies two unsigned values
     * Can set overflow or zero flag
     * Params:
     *      op1 is the first value
     *      *op2 is the second value and is where the result gets stored
     **/
    private void umul(uint op1, uint *op2)
    {
        debug(umul) { writeln("Unsigned multiplication"); }
        *op2 = mulu(op1, *op2, flags.overflow);
        // Set negative flag to false?
        flags.zero = *op2 == 0;
    }

    /**
     * Performs integer division on two unsigned values
     * Can set zero flag
     * Params:
     *      *op1 is the first value and where the remainder gets stored
     *      *op2 is the second value and is where the result gets stored
     **/
    private void udiv(uint *op1, uint *op2)
    {
        debug(udiv) { writeln("Unsigned division"); }
        if(*op1 == 0) 
        {
            stdout.flush();
            exception_reg = EXC.DIV_BY_ZERO;
        }
        else
        {
            uint tmp = *op2 / *op1;
            *op1 = *op2 % *op1;
            *op2 = tmp;
            flags.zero = *op2 == 0;
            // Set negative flag to false?
        }
    }

    /**
     * Compares two operators, can either be signed or unsigned
     * eq, lt and gt flags will be cleared before the comparisons
     * Sets one of eq, lt or gt flags
     * Params:
     *      op1 is the first value, and is compared to op2
     *      op2 is the second value
     **/
    private void cmp(T)(in T op1, in T op2)
    {
        with(flags)
        {
            eq = lt = gt = false;
            if(op1 == op2)
            {
                eq = true;
            }
            else if(op1 < op2)
            {
                lt = true;
            }
            else
            {
                gt = true;
            }
        }
    }

    /**
     * Jumps to a given address
     * Params:
     *      op1 holds the address to jump to
     **/
    private void jmp(in int op1)
    in
    {
        assert(op1 >= 0 && op1 <= short.max);
    }
    body
    {
        code_ptr = cast(ushort) (op1 - 1);
    }

    /**
     * Executes the given instruction
     * Format of an instruction within a binary is op2 flags, then op1 flags, then instruction itself
     * Params:
     *      instr holds the value of the next instruction to execute and its flags
     **/
    public void exec_ins(in uint instr)
    {
        ins_flags = cast(ushort) (instr & 0xFFFF);
        ins = cast(ushort) ((instr >> 16) & 0xFFFF);

        /**
         * Once the next instruction is found, its operand(s) are grabbed one at a time
         * using this function
         * Params:
         *      *op is set to point to the memory address of the operand, which can be
         *      from the regs array, the data array or an immediate operand, in which case
         *      it is set to hold the address of either tmp1 or tmp2 so that it doesn't accidently clobber
         *      a value at another memory address it was previously holding
         *      flags indicates whether we are grabbing a register, an area of memory or
         *      immediate data
         **/
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
            case INS.RDC:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                read!char(op1, *op2);
                break;
            case INS.RDB:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                read!byte(op1, *op2);
                break;
            case INS.RDH:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                read!short(op1, *op2);
                break;
            case INS.RDW:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                read!int(op1, *op2);
                break;
            case INS.WRC:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                write!char(op1, *op2);
                break;
            case INS.WRB:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                write!byte(op1, *op2);
                break;
            case INS.WRH:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                write!short(op1, *op2);
                break;
            case INS.WRW:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                write!int(op1, *op2);
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
                div(op1, op2);
                break;
            case INS.UADD:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                uadd(cast(uint) *op1, cast(uint *) op2);
                break;
            case INS.USUB:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                usub(cast(uint) *op1, cast(uint *) op2);
                break;
            case INS.UMUL:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                umul(cast(uint) *op1, cast(uint *) op2);
                break;
            case INS.UDIV:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                udiv(cast(uint *) op1, cast(uint *) op2);
                break;
            case INS.URDW:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                read!uint(op1, *op2);
                break;
            case INS.UWRW:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                write!uint(op1, *op2);
                break;
            case INS.CMP:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                cmp!int(*op1, *op2);
                break;
            case INS.UCMP:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                cmp!uint(cast(uint) *op1, cast(uint) *op2);
                break;
            case INS.JMP:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                jmp(*op1);
                break;
            case INS.JE:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.eq && jmp(*op1);
                break;
            case INS.JNE:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.eq && jmp(*op1);
                break;
            case INS.JG:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.gt && jmp(*op1);
                break;
            case INS.JGE:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.lt && jmp(*op1);
                break;
            case INS.JL:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.lt && jmp(*op1);
                break;
            case INS.JLE:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.gt && jmp(*op1);
                break;
            case INS.JZ:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.zero && jmp(*op1);
                break;
            case INS.JNZ:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.zero && jmp(*op1);
                break;
        }

        op_switch = true;
    }
}