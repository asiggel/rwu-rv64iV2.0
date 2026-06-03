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
    instr07slli
    instr08slti
    instr09sltiu
    instr10xori
    instr11srli
    instr12srai
    instr13ori
    instr14andi
    instr15auipc
    instr16sb
    instr17sh
    instr18sw
    instr19add
    instr20sub
    instr21sll
    instr22slt
    instr23sltu
    instr24xor
    instr25srl
    instr26sra
    instr27or
    instr28and
    instr29lui
    instr30beq
    instr31bne
    instr32blt
    instr33bge
    instr34bltu
    instr35bgeu
    instr36jalr
    instr37jal
    instr38ld
    instr39lwu
    instr40addiw
    instr41slliw
    instr42srliw
    instr43sraiw
    instr44sd
    instr45addw
    instr46subw
    instr47sllw
    instr48srlw
    instr49sraw
    instr51csrrw
    instr52csrrs
    instr53csrrc
    instr54csrrwi
    instr55csrrsi
    instr56csrrci
    instr57mret
)

# -------------------------------------------------
# Konfiguration der einheitlichen Instruktions-Testbench
# Format pro Eintrag: TEST_ID NAME EXPECTED_GPIO
# Alle hier gelisteten Tests verwenden tb_rv64i_instr.sv.
# Alle anderen Tests behalten ihre eigene Testbench.
# -------------------------------------------------
set(INSTR_TB_CONFIG
  # Table B.1 (RV32I)
  "instr01loadbyte"  "load_byte"   "128"
  "instr02loadhalf"  "load_half"   "7"
  "instr03loadword"  "load_word"   "5"
  "instr04loadbyteu" "load_byteu"  "128"
  "instr05loadhalfu" "load_halfu"  "7"
  "instr06addi"      "addi"        "255"
  "instr07slli"      "slli"        "1"
  "instr08slti"      "slti"        "8"
  "instr09sltiu"     "sltiu"       "9"
  "instr10xori"      "xori"        "10"
  "instr11srli"      "srli"        "11"
  "instr12srai"      "srai"        "12"
  "instr13ori"       "ori"         "13"
  "instr14andi"      "andi"        "14"
  "instr15auipc"     "auipc"       "15"
  "instr16sb"        "sb"          "16"
  "instr17sh"        "sh"          "17"
  "instr18sw"        "sw"          "18"
  "instr19add"       "add"         "254"
  "instr20sub"       "sub"         "20"
  "instr21sll"       "sll"         "21"
  "instr22slt"       "slt"         "22"
  "instr23sltu"      "sltu"        "23"
  "instr24xor"       "xor"         "24"
  "instr25srl"       "srl"         "25"
  "instr26sra"       "sra"         "26"
  "instr27or"        "or"          "27"
  "instr28and"       "and"         "28"
  "instr29lui"       "lui"         "29"
  "instr30beq"       "beq"         "30"
  "instr31bne"       "bne"         "31"
  "instr32blt"       "blt"         "32"
  "instr33bge"       "bge"         "33"
  "instr34bltu"      "bltu"        "34"
  "instr35bgeu"      "bgeu"        "35"
  "instr36jalr"      "jalr"        "36"
  "instr37jal"       "jal"         "37"
  # Table B.2 (RV64I extras)
  "instr38ld"        "ld"          "38"
  "instr39lwu"       "lwu"         "39"
  "instr40addiw"     "addiw"       "40"
  "instr41slliw"     "slliw"       "32"
  "instr42srliw"     "srliw"       "42"
  "instr43sraiw"     "sraiw"       "43"
  "instr44sd"        "sd"          "44"
  "instr45addw"      "addw"        "45"
  "instr46subw"      "subw"        "46"
  "instr47sllw"      "sllw"        "47"
  "instr48srlw"      "srlw"        "48"
  "instr49sraw"      "sraw"        "49"
  # System (rows 51-57)
  "instr51csrrw"     "csrrw"       "29"
  "instr52csrrs"     "csrrs"       "52"
  "instr53csrrc"     "csrrc"       "53"
  "instr54csrrwi"    "csrrwi"      "22"
  "instr55csrrsi"    "csrrsi"      "25"
  "instr56csrrci"    "csrrci"      "20"
  "instr57mret"      "mret"        "57"
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
