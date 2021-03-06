module VM;

import std.stdio;
import std.conv;
import core.checkedint;

enum OPERANDS { REG = 1, IDATA = 2, ADDR = 4 };
enum INS { HLT, RDC, RDB, RDH, RDW, WRC, WRB, WRH, WRW,
         //0     1    2    3    4    5    6    7    8
           PUSH, POP, MOV, ADD, SUB, MUL, DIV, UADD, USUB, UMUL, UDIV, URDW, UWRW,
         //9     10   11   12   13   14   15   16    17    18    19	   20    21
           CMP, UCMP, JMP, JE, JNE, JG, JGE, JL, JLE, JZ, JNZ, JN, JNN, JO, JNO,
         //22   23    24   25  26   27  28   29  30   31  32   33  34   35  36
           JR, JNR, JP, JNP, INC, DEC, AND, OR, XOR, NOT, NEG, SHL, SHR, USHR,
         //37  38   39  40   41   42   43   44  45   46   47   48   49   50
           ROR, ROL, RCR, RCL
         //51   52   53   54
};
enum STACK_SIZE = 2^^16;
enum NUM_REGS = 16;
enum EXC { DIV_BY_ZERO, SEG_FAULT, STACK_FAULT };

struct Flags
{
    bool overflow;
    bool zero;
    bool negative;
    bool parity;
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
    bool rotate; // Almost threw this in the Flag struct, but I figured it's not technically a flag
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

    private void set_parity(uint num)
    {
        int tmp;
        while(num > 0)
        {
            tmp += num & 1;
            num >>>= 1;
        }
        flags.parity = !(tmp & 1);
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
     * Reads a certain number of Ts from stdin to a destination
     * Can throw a segmentation fault exception of data being read
     * flows out of the data segment
     * Params:
     *      op1 holds a pointer to the beginning of memory to be read to
     *      op2 holds the amount of Ts to be read
     **/
    private void read(T)(int *op1, in uint op2)
    {
        if(data_size != 0 && (op1 + op2 >= &data_seg[data_size - 1] || op1 + op2 < &data_seg[0])) // Data flowing out of data_seg?
        {
            exception_reg = EXC.SEG_FAULT;
        }
        else
        {
            foreach(i; 0..op2)
            {
                readf("%s", cast(T *) &op1[i]);
            }
        }
    }

    /**
     * Writes a certain number of Ts from a source to stdout
     * Can throw a segmentation fault exception if it attempts
     * to write data outside of the data segment
     * Params:
     *      op1 holds a pointer to the beginning of memory to be read from
     *      op2 hold the amount of Ts to write
     **/
    private void write(T)(int *op1, in uint op2)
    {
        if(data_size != 0 && (op1 + op2 >= &data_seg[data_size - 1] || op1 + op2 < &data_seg[0]))
        {
            exception_reg = EXC.SEG_FAULT;
        }

        foreach(i; 0..op2)
        {
            writef("%s", cast(T) op1[i]);
        }
    }

    /**
     * Pushes a value onto the stack
     * Throws a stack fault if stack is full
     * Params:
     *      op1 holds value to be pushed
     **/
    private void push(in int op1)
    {
        if(stack_ptr == STACK_SIZE)
        {
            exception_reg = EXC.STACK_FAULT;
        }
        
        stack_seg[stack_ptr] = op1;

        debug(push)
        {
            writeln("Pushing: ", stack_seg[stack_ptr]);
        }

        ++stack_ptr;
    }

    /**
     * Pops a value off the stack
     * Throws a stack fault if stack is empty
     * Params:
     *      op1 holds the destination address
     **/
    private void pop(int *op1)
    {
        if(stack_ptr == 0)
        {
            exception_reg = EXC.STACK_FAULT;
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
     * Can set overflow, negative, parity or zero flag
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
        set_parity(cast(uint) *op2);
    }

    /**
     * Subtracts two signed values
     * Can set overflow, negative, parity or zero flag
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
        set_parity(cast(uint) *op2);
    }

    /**
     * Multiplies two signed values
     * Can set overflow, negative, parity or zero flag
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
        set_parity(cast(uint) *op2);
    }

    /**
     * Performs integer division two values
     * Can set negative, parity or zero flag
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
            set_parity(cast(uint) *op2);
        }
    }

    /**
     * Adds two unsigned values
     * Can set overflow, parity or zero flag
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
        set_parity(*op2);
    }

    /**
     * Subtracts two unsigned values
     * Can set overflow, parity or zero flag
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
        set_parity(*op2);
    }

    /**
     * Multiplies two unsigned values
     * Can set overflow, parity or zero flag
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
        set_parity(*op2);
    }

    /**
     * Performs integer division on two unsigned values
     * Can set parity or zero flag
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
            set_parity(*op2);
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
        assert(op1 >= 0 && op1 <= ushort.max);
    }
    body
    {
        code_ptr = cast(ushort) (op1 - 1);
    }

    /**
     * Bitwise and two values
     * Can set zero, parity or negative flag
     * Params:
     *      op1 holds the first value
     *      *op2 holds the second value and is where the result is stored
     **/
    private void and(in int op1, int *op2)
    {
        *op2 = op1 & *op2;
        flags.zero = *op2 == 0;
        set_parity(cast(uint) *op2);
        flags.negative = *op2 < 0;
    }

    /**
     * Bitwise or two values
     * Can set zero, parity or negative flag
     * Params:
     *      op1 holds the first value
     *      *op2 holds the second value and is where the result is stored
     **/
    private void or(in int op1, int *op2)
    {
        *op2 = op1 | *op2;
        flags.zero = *op2 == 0;
        set_parity(cast(uint) *op2);
        flags.negative = *op2 < 0;
    }

    /**
     * Bitwise xor two values
     * Can set zero, parity or negative flag
     * Params:
     *      op1 holds the first value
     *      *op2 holds the second value and is where the result is stored
     **/
    private void xor(in int op1, int *op2)
    {
        *op2 = op1 ^ *op2;
        flags.zero = *op2 == 0;
        set_parity(cast(uint) *op2);
        flags.negative = *op2 < 0;
    }

    /**
     * Perform one's complement on a value
     * Can set zero, parity or negative flag
     * Params:
     *      op1 holds the value and is where the result is stored
     **/
    private void not(int *op1)
    {
        *op1 = ~*op1;
        flags.zero = *op1 == 0;
        set_parity(cast(uint) *op1);
        flags.negative = *op1 < 0;
    }

    /**
     * Perform two's complement on a value
     * Can set zero, parity or negative flag
     * Params:
     *      op1 holds the value and is where the result is stored
     **/
    private void neg(int *op1)
    {
        *op1 = -*op1;
        flags.zero = *op1 == 0;
        set_parity(cast(uint) *op1);
        flags.negative = *op1 < 0;
    }

    /**
     * Shifts a value left or right or right unsigned (depending on op) by any number 1-32
     * Can set zero, parity or negative flag (negative flag only if a signed shift)
     * If op2 is zero, than absolutely nothing happens
     * Params:
     *      *op1 holds value to be shifted and is where the result is stored
     *      op2 holds the amount *op1 gets shifted
     **/
    private void sh(string op)(int *op1, int op2)
    {
        if(op2 >= 32 && op2 % 32 == 0)
        {
            *op1 = 0; // D doesn't shift by more than or the same as the number of bits in a type
                      // So this has to get set to zero if we try to shift by 32 or a multiple of 32
        }
        else if(op2 != 0)
        {
            op2 %= 32;
            mixin("*op1 " ~ op ~ " (op2 - 1);");
            static if(op == "<<")
            {
                rotate = cast(bool) (*op1 & 0x80000000); // MSB is shifted into rotate, similar behavior to Intel CPUs
            }
            else
            {
                rotate = cast(bool) (*op1 & 1); // LSB is shifted into rotate, similar behavior to Intel CPUs
            }
            mixin("*op1 " ~ op ~ " 1;");
            flags.zero = *op1 == 0;
            static if(op == "<<=" || op == ">>=") { flags.negative = *op1 < 0; }
            set_parity(cast(uint) *op1);
        }
    }

    /**
     * Rotates the bits in a value left or right depending on ins
     * Can set zero, negative or parity flag
     * Params:
     *      *op1 is the value to be rotated and where the result is stored
     *      op2 is the amount to be rotated by
     **/
    private void rot(string ins)(int *op1, int op2)
    {
        mixin("
        asm
        {
            mov RAX, op1;
            mov ECX, op2[EBP];" ~
            ins ~ " [RAX], CL;
        }
        ");
        flags.zero = *op1 == 0;
        flags.negative = *op1 < 0;
        set_parity(cast(uint) *op1);       
    }

    /**
     * Rotates the bits in a value left or right depending on ins
     * When a bit is shifted off the end, it is moved into the rotate flag
     * The value in the rotate flag is shifted back into the value
     * Can set zero, negative or parity flag
     * Params:
     *      *op1 is the value to be rotated and where the result is stored
     *      op2 is the amount to be rotated by
     **/
    private void rotc(string ins)(int *op1, int op2)
    {
        mixin("
        asm
        {
            mov RBX, this;
            lahf; // Next three lines set the actual carry flag to the value of rotate
            or AH, rotate[RBX];
            sahf;
            mov RDX, op1;
            mov ECX, op2[EBP];" ~
            ins ~ " [EDX], CL;
            lahf; // Set rotate to CF
            and AH, 1;
            mov rotate[RBX], AH;
        }
        ");
        flags.zero = *op1 == 0;
        flags.negative = *op1 < 0;
        set_parity(cast(uint) *op1);
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
            case INS.HLT:
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
            case INS.JN:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.negative && jmp(*op1);
                break;
            case INS.JNN:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.negative && jmp(*op1);
                break;
            case INS.JO:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.overflow && jmp(*op1);
                break;
            case INS.JNO:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.overflow && jmp(*op1);
                break;
            case INS.JR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                rotate && jmp(*op1);
                break;
            case INS.JNR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !rotate && jmp(*op1);
                break;
            case INS.JP:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                flags.parity && jmp(*op1);
                break;
            case INS.JNP:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                !flags.parity && jmp(*op1);
                break;
            case INS.INC:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                ++*op1;
                break;
            case INS.DEC:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                --*op1;
                break;
            case INS.AND:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                and(*op1, op2);
                break;
            case INS.OR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                or(*op1, op2);
                break;
            case INS.XOR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                xor(*op1, op2);
                break;
            case INS.NOT:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                not(op1);
                break;
            case INS.NEG:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                neg(op1);
                break;
            case INS.SHL:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                sh!"<<="(op1, *op2);
                break;
            case INS.SHR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                sh!">>="(op1, *op2);
                break;
            case INS.USHR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                sh!">>>="(op1, *op2);
                break;
            case INS.ROR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                rot!"ror"(op1, *op2);
                break;
            case INS.ROL:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                rot!"rol"(op1, *op2);
                break;
            case INS.RCR:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                rotc!"rcr"(op1, *op2);
                break;
            case INS.RCL:
                get_ops(op1, (ins_flags >> 8) & 0xFF);
                get_ops(op2, ins_flags & 0xFF);
                rotc!"rcl"(op1, *op2);
                break;
        }

        op_switch = true;
    }
}
