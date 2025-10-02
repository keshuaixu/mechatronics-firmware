#include <verilated.h>
#include "Vtb_fpga_to_espm_direct.h"

int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    Vtb_fpga_to_espm_direct top{&context};

    while (!context.gotFinish()) {
        top.eval_step();
        context.timeInc(1);
    }

    top.final();
    return 0;
}
