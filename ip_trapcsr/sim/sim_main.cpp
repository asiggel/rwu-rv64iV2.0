#include <memory>
#include "verilated.h"
#include "verilated_fst_c.h"
#include "Vcc_trap_csr_tb.h"

int main(int argc, char** argv) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    contextp->traceEverOn(true);
    const std::unique_ptr<Vcc_trap_csr_tb> top{new Vcc_trap_csr_tb{contextp.get()}};
    VerilatedFstC* tfp = new VerilatedFstC;
    top->trace(tfp, 99);
    tfp->open("dump_trap_csr.fst");
    while (!contextp->gotFinish()) {
        contextp->timeInc(1);
        top->eval();
        tfp->dump(contextp->time());
    }
    tfp->close();
    delete tfp;
    top->final();
    return 0;
}
