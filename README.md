RV64I CPU — 5-stage pipelined implementation.

- I-Mem and D-Mem with synchronous write and synchronous read
- 5-stage pipeline: IF → ID → EX → MEM → WB
- Forwarding unit (EX-MEM and MEM-WB bypassing)
- Hazard detection unit (load-use stall, CSR stall, branch/jump flush)
- CSR support: mstatus, mie, mip, mepc, mtvec, mcause
- Trap and IRQ handling: illegal instruction, misaligned access, external IRQ
- GPIO peripheral
- JTAG scan chain (DFT)
- CGU (Clock Generation Unit)

CPU variants in src/:
- asCPUx_pipeline.sv : active CPU (5-stage pipeline, instantiated by asTopMem.sv)
- asCPUx.sv          : reference single-cycle CPU (4-state FSM, not connected)

RWU_RV/RV_NoPipeline/CMakeLists.txt : start the simulation
RWU_RV/RV_NoPipeline/src            : SystemVerilog sources
RWU_RV/RV_NoPipeline/tb             : SystemVerilog test benches
RWU_RV/RV_NoPipeline/rv64Sim        : Assembler files for generating the .mem files for Verilog (Vivado) simulations

Assembler:
- adapt PATH in ...RWU_RV/RV_NoPipeline/rv64Sim/CMakeLists.txt
-   ... set(RISCV_PREFIX /usr/bin/riscv64-linux-gnu) to your needs

Simulation:
- cd RWU_RV/RV_NoPipeline
- open a terminal
- cmake -S . -B build                                 # generate source and build directory
- cmake --build build --target sim_readgpioid         # executes a single test
- cmake --build build --target collect_errors         # executes all simulations as regression and collects the errors
- rm -rf build                                        # removes the simulation builds
