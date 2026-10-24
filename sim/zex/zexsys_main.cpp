// Clock for tb_zexsys.v: the 100 MHz system clock until $finish.
#include "Vtb_zexsys.h"
#include "verilated.h"

// Needed by verilated.cpp on MinGW, which has no weak symbols
double sc_time_stamp() { return 0; }

int main(int argc, char **argv)
{
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    Vtb_zexsys top{&ctx};
    while (!ctx.gotFinish()) {
        top.clk = 0;
        top.eval();
        ctx.timeInc(5);
        top.clk = 1;
        top.eval();
        ctx.timeInc(5);
    }
    top.final();
    return 0;
}
