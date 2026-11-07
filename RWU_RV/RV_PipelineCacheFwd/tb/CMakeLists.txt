cmake_minimum_required(VERSION 3.20)
project(cpupipefwd_cachefault_sim LANGUAGES NONE)

# Standalone white-box testbench for cc_cpupipefwd's AXI4 cache-error trap
# path (mcause=1/5, mtval). Does not go through the chip-level ASM-test
# CMake flow (RWU_RV/RV_PipelineCacheFwd/CMakeLists.txt): no cache/AXI4/
# full-chip is instantiated, see tb_cpupipefwd_cachefault.sv header.
#
# xsim only (this project's primary simulator, see CLAUDE.md): the two
# free-running BFM processes race under Verilator's scheduling model
# (dc_req sampling right at the clock edge is simulator-order-dependent
# for this style of testbench); not worth chasing further for a
# verification-only harness when xsim already passes deterministically.
#
# Usage:
#   cmake -S . -B build
#   cmake --build build --target simulate

set(TB_TOP tb_cpupipefwd_cachefault)
set(TB_DIR ${CMAKE_CURRENT_SOURCE_DIR})
set(NP_ROOT ${TB_DIR}/../../RV_NoPipeline)
set(PC_ROOT ${TB_DIR}/..)
set(IP_ROOT ${TB_DIR}/../../..)

set(SOURCES_SV
    ${NP_ROOT}/src/as_pack.sv
    ${NP_ROOT}/src/asRegFile.sv
    ${NP_ROOT}/src/asAlu.sv
    ${NP_ROOT}/src/asAluBr.sv
    ${NP_ROOT}/src/asInstrDecode.sv
    ${IP_ROOT}/ip_jtag/src/scan_cell.sv
    ${IP_ROOT}/ip_trapcsr/src/cc_trap_csr.sv
    ${PC_ROOT}/src/cc_cpupipefwd.sv
    ${TB_DIR}/${TB_TOP}.sv
)

add_custom_command(
    OUTPUT compile.stamp
    COMMAND xvlog --sv --incr --relax -d LOGIC_SV ${SOURCES_SV}
    COMMAND ${CMAKE_COMMAND} -E touch compile.stamp
    DEPENDS ${SOURCES_SV}
    COMMENT "Compiling SystemVerilog (xvlog)"
)
add_custom_target(compile DEPENDS compile.stamp)

add_custom_command(
    OUTPUT elaborate.stamp
    COMMAND xelab -debug all -top ${TB_TOP} -snapshot ${TB_TOP}_snapshot
    COMMAND ${CMAKE_COMMAND} -E touch elaborate.stamp
    DEPENDS compile.stamp
    COMMENT "Elaborating (xelab)"
)
add_custom_target(elaborate DEPENDS elaborate.stamp)

add_custom_target(simulate
    COMMAND xsim ${TB_TOP}_snapshot -R
    DEPENDS elaborate.stamp
    COMMENT "Simulating (xsim)"
)

add_custom_target(waves
    COMMAND xsim --gui ${TB_TOP}_snapshot
    DEPENDS elaborate.stamp
    COMMENT "Simulating with Vivado Waveform GUI"
)
