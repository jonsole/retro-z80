// Clock for tb_zex.v: one rising edge per T-state until $finish.
#include "Vtb_zex.h"
#include "verilated.h"

// Needed by verilated.cpp on MinGW, which has no weak symbols
double sc_time_stamp() { return 0; }

int main(int argc, char **argv)
{
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    Vtb_zex top{&ctx};
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
