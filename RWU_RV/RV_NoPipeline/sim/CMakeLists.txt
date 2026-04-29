cmake_minimum_required(VERSION 3.20)
project(rv64i_sim LANGUAGES NONE)

# -------------------------------------------------
# Roots (MUSS gesetzt sein)
# -------------------------------------------------
foreach(var PROJECT_ROOT IP_ROOT RV64_MEM)
    if(NOT DEFINED ${var})
        message(FATAL_ERROR "${var} not set")
    endif()
endforeach()

if(NOT EXISTS ${RV64_MEM})
    message(FATAL_ERROR "RV64_MEM does not exist: ${RV64_MEM}")
endif()

set(TB_TOP tb_rv64i)

# -------------------------------------------------
# SystemVerilog Sources
# -------------------------------------------------
set(SOURCES_SV
    ${PROJECT_ROOT}/src/as_pack.sv
    ${PROJECT_ROOT}/src/asRegFile.sv
    #${PROJECT_ROOT}/src/asAdd.sv

    ${IP_ROOT}/ip_dmem/src/asDMemBack.sv
    ${IP_ROOT}/ip_dmem/src/asDMemFront.sv
    ${IP_ROOT}/ip_dmem/src/asDMemCore.sv
    ${IP_ROOT}/ip_dmem/src/asDMem.sv
    ${IP_ROOT}/ip_dmem/src/asDMemTop.sv

    ${PROJECT_ROOT}/src/asIMem.sv
    #${PROJECT_ROOT}/src/asImmGen.sv
    #${PROJECT_ROOT}/src/asMux2.sv
    #${PROJECT_ROOT}/src/asMux3.sv
    #${PROJECT_ROOT}/src/asPC.sv
    #${PROJECT_ROOT}/src/asAluRV.sv
    ${PROJECT_ROOT}/src/asAlu.sv
    ${PROJECT_ROOT}/src/asAluBr.sv
    ${PROJECT_ROOT}/src/asControlAll.sv
    ${PROJECT_ROOT}/src/asInstrDecode.sv
    
    ${IP_ROOT}/ip_jtag/src/tap_fsm.sv
    ${IP_ROOT}/ip_jtag/src/ir_cell.sv
    ${IP_ROOT}/ip_jtag/src/dr_cell.sv
    ${IP_ROOT}/ip_jtag/src/scan_cell.sv
    ${IP_ROOT}/ip_jtag/src/by_cell.sv
    ${IP_ROOT}/ip_jtag/src/ir_reg.sv
    ${IP_ROOT}/ip_jtag/src/dr_reg.sv
    ${IP_ROOT}/ip_jtag/src/ir_decode.sv
    ${IP_ROOT}/ip_jtag/src/jtag.sv

    ${PROJECT_ROOT}/src/asMBpi.sv
    ${PROJECT_ROOT}/src/asSBpi.sv

    ${IP_ROOT}/ip_gpio/src/asGpio.sv
    ${IP_ROOT}/ip_gpio/src/asGpioTop.sv

    #${PROJECT_ROOT}/src/asCPU.sv
    ${PROJECT_ROOT}/src/asCPUx.sv
    ${PROJECT_ROOT}/src/asDecode.sv

    ${IP_ROOT}/ip_cgu/src/asCguCore.sv
    ${IP_ROOT}/ip_cgu/src/asCguTop.sv

    ${PROJECT_ROOT}/src/asTopMem.sv
    ${PROJECT_ROOT}/tb/tb_rv64i.sv
)

# -------------------------------------------------
# Compile
# -------------------------------------------------
add_custom_command(
    OUTPUT compile.stamp
    COMMAND xvlog --sv --incr --relax -d LOGIC_SV ${SOURCES_SV}
    COMMAND ${CMAKE_COMMAND} -E copy ${RV64_MEM} riscvtest.mem
    COMMAND touch compile.stamp
    DEPENDS ${RV64_MEM}
    COMMENT "Compiling SystemVerilog"
)

add_custom_target(compile DEPENDS compile.stamp)

# -------------------------------------------------
# Elaborate
# -------------------------------------------------
add_custom_command(
    OUTPUT elaborate.stamp
    COMMAND xelab -debug all -top ${TB_TOP} -snapshot ${TB_TOP}_snapshot
    DEPENDS compile.stamp
)

add_custom_target(elaborate DEPENDS elaborate.stamp)

# -------------------------------------------------
# Simulate
# -------------------------------------------------
add_custom_target(simulate
    COMMAND xsim ${TB_TOP}_snapshot --tclbatch ${PROJECT_ROOT}/sim/xsim_cfg.tcl
    DEPENDS elaborate.stamp
)

# -------------------------------------------------
# Waves
# -------------------------------------------------
add_custom_target(waves
    COMMAND xsim --gui ${TB_TOP}_snapshot --tclbatch ${PROJECT_ROOT}/sim/xsim_cfg2.tcl
    DEPENDS elaborate.stamp
)
