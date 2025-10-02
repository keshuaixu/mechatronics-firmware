#include <verilated.h>
#include "Vtb_espm_to_fpga_direct.h"

int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    Vtb_espm_to_fpga_direct top{&context};

    while (!context.gotFinish()) {
        top.eval_step();
        context.timeInc(1);
    }

    top.final();
    return 0;
}
