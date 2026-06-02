cmake_minimum_required(VERSION 3.20)
project(rv64i_regression LANGUAGES NONE)

# -------------------------------------------------
# Globale Roots
# -------------------------------------------------
set(PROJECT_ROOT ${CMAKE_SOURCE_DIR})
set(IP_ROOT ${PROJECT_ROOT}/../../ CACHE PATH "Root directory for shared IPs")

# -------------------------------------------------
# Simulator-Auswahl
#   cmake -B build -DSIMULATOR=xsim       (Default)
#   cmake -B build -DSIMULATOR=verilator
# -------------------------------------------------
set(SIMULATOR "xsim" CACHE STRING "Simulator-Backend: xsim | verilator")
set_property(CACHE SIMULATOR PROPERTY STRINGS xsim verilator)

# -------------------------------------------------
# Waveform-GUI  (nur Einzeltest sinnvoll!)
#   cmake -B build -DWAVES=ON
#   cmake --build build --target sim_<test>
#
#   NICHT für --target regression verwenden!
# -------------------------------------------------
option(WAVES "Waveform-Viewer öffnen (nur Einzeltest, nicht für Regression)" OFF)

if(WAVES)
    set(SIM_TARGET "waves")
    message(STATUS "WAVES=ON: Waveform GUI aktiv — nicht mit 'regression' kombinieren!")
else()
    set(SIM_TARGET "simulate")
endif()

message(STATUS "SIMULATOR = ${SIMULATOR}")
message(STATUS "SIM_TARGET = ${SIM_TARGET}")

# -------------------------------------------------
# Test-Liste
# -------------------------------------------------
set(ASM_TESTS
    instr99scantest
    instr99loadimem
    readgpioid
    instr01loadbyte
    instr02loadhalf
    instr03loadword
    instr04loadbyteu
    instr05loadhalfu
    instr06addi
    instr19add
    instr07slli
    instr29lui
)

# -------------------------------------------------
# Konfiguration der einheitlichen Instruktions-Testbench
# Format pro Eintrag: TEST_ID NAME EXPECTED_GPIO
# Alle hier gelisteten Tests verwenden tb_rv64i_instr.sv.
# Alle anderen Tests behalten ihre eigene Testbench.
# -------------------------------------------------
set(INSTR_TB_CONFIG
  "instr01loadbyte"  "load_byte"   "128"
  "instr02loadhalf"  "load_half"   "7"
  "instr03loadword"  "load_word"   "5"
  "instr04loadbyteu" "load_byteu"  "128"
  "instr05loadhalfu" "load_halfu"  "7"
  "instr06addi"      "addi"        "6"
  "instr19add"       "add"         "254"
  "instr07slli"      "slli"        "1"
  "instr29lui"       "lui"         "29"
)

list(LENGTH INSTR_TB_CONFIG _cfg_len)
set(_i 0)
while(_i LESS _cfg_len)
    list(GET INSTR_TB_CONFIG ${_i}             _tid)
    math(EXPR _ni "${_i} + 1")
    math(EXPR _ei "${_i} + 2")
    list(GET INSTR_TB_CONFIG ${_ni}            _tname)
    list(GET INSTR_TB_CONFIG ${_ei}            _texp)
    set(INSTR_TB_NAME_${_tid}     "${_tname}")
    set(INSTR_TB_EXPECTED_${_tid} "${_texp}")
    math(EXPR _i "${_i} + 3")
endwhile()

add_custom_target(regression)

foreach(TEST ${ASM_TESTS})

    set(TEST_BUILD_DIR ${CMAKE_BINARY_DIR}/${TEST})

    # Testbench-Auswahl: einheitliche TB oder test-spezifische TB
    if(DEFINED INSTR_TB_NAME_${TEST})
        set(_TB_FILE    ${PROJECT_ROOT}/tb/tb_rv64i_instr.sv)
        set(_EXTRA_ARGS
            "-DTB_TEST_NAME=${INSTR_TB_NAME_${TEST}}"
            "-DTB_EXPECTED=${INSTR_TB_EXPECTED_${TEST}}")
    else()
        set(_TB_FILE    ${PROJECT_ROOT}/tb/tb_rv64i_${TEST}.sv)
        set(_EXTRA_ARGS "")
    endif()

    # ---------------- ASM ----------------
    add_custom_command(
        OUTPUT ${TEST_BUILD_DIR}/asm/rv64i.mem
        COMMAND ${CMAKE_COMMAND} -E make_directory ${TEST_BUILD_DIR}/asm
        COMMAND ${CMAKE_COMMAND}
                -DASM_FILE=${PROJECT_ROOT}/rv64Sim/${TEST}.asm
                -S ${PROJECT_ROOT}/rv64Sim
                -B ${TEST_BUILD_DIR}/asm
        COMMAND ${CMAKE_COMMAND}
                --build ${TEST_BUILD_DIR}/asm --target mem
        DEPENDS ${PROJECT_ROOT}/rv64Sim/${TEST}.asm
        COMMENT "Assembling ${TEST}"
    )

    # ---------------- SIM ----------------
    add_custom_target(sim_${TEST}
        COMMAND ${CMAKE_COMMAND}
                -DPROJECT_ROOT=${PROJECT_ROOT}
                -DIP_ROOT=${IP_ROOT}
                -DRV64_MEM=${TEST_BUILD_DIR}/asm/rv64i.mem
                -DTB_FILE=${_TB_FILE}
                -DSIMULATOR=${SIMULATOR}
                ${_EXTRA_ARGS}
                -S ${PROJECT_ROOT}/sim
                -B ${TEST_BUILD_DIR}/sim
        COMMAND ${CMAKE_COMMAND} --build ${TEST_BUILD_DIR}/sim --target ${SIM_TARGET}
        DEPENDS ${TEST_BUILD_DIR}/asm/rv64i.mem
        COMMENT "Simulating ${TEST} [${SIMULATOR}]"
    )

    add_dependencies(regression sim_${TEST})

endforeach()

# -------------------------------------------------
# Regression-Fehler sammeln
# Semicolons in CMake lists werden von der Shell als Befehlstrenner
# interpretiert → kommagetrennte Liste verwenden
# -------------------------------------------------
list(JOIN ASM_TESTS "," TESTS_CSV)
add_custom_target(collect_errors
    COMMAND ${CMAKE_COMMAND}
        -DPROJECT_ROOT=${PROJECT_ROOT}
        -DBUILD_ROOT=${CMAKE_BINARY_DIR}
        -DTESTS=${TESTS_CSV}
        -P ${PROJECT_ROOT}/collect_errors.cmake
    COMMENT "Collecting regression error files"
)

add_dependencies(collect_errors regression)
