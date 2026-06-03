cmake_minimum_required(VERSION 3.20)
project(rv64i_cache_regression LANGUAGES NONE)

# -------------------------------------------------
# Roots
# -------------------------------------------------
set(PROJECT_ROOT ${CMAKE_SOURCE_DIR})
set(IP_ROOT ${PROJECT_ROOT}/../../ CACHE PATH "Root of shared IPs")
set(NP_ROOT ${PROJECT_ROOT}/../RV_NoPipeline CACHE PATH "RV_NoPipeline shared sources")

# -------------------------------------------------
# Simulator
#   cmake -B build -DSIMULATOR=xsim        (Default)
#   cmake -B build -DSIMULATOR=verilator
# -------------------------------------------------
set(SIMULATOR "xsim" CACHE STRING "Simulator: xsim | verilator")
set_property(CACHE SIMULATOR PROPERTY STRINGS xsim verilator)

option(WAVES "Open waveform viewer (single test only, not for regression)" OFF)

if(WAVES)
    set(SIM_TARGET "waves")
    message(STATUS "WAVES=ON: waveform GUI active")
else()
    set(SIM_TARGET "simulate")
endif()

message(STATUS "SIMULATOR  = ${SIMULATOR}")
message(STATUS "SIM_TARGET = ${SIM_TARGET}")

# -------------------------------------------------
# Test list
# JTAG-scan tests excluded — no I-Mem scan chain in cache version.
# Special tests keep their own testbenches; all instruction tests use the
# unified tb_rv64i_instr.sv (same as RV_NoPipeline).
# -------------------------------------------------
set(ASM_TESTS
    readgpioid
    # ---- Table B.1 loads ----
    instr01loadbyte
    instr02loadhalf
    instr03loadword
    instr04loadbyteu
    instr05loadhalfu
    # ---- I-type ALU ----
    instr06addi
    instr07slli
    instr08slti
    instr09sltiu
    instr10xori
    instr11srli
    instr12srai
    instr13ori
    instr14andi
    # ---- PC-relative ----
    instr15auipc
    # ---- Stores ----
    instr16sb
    instr17sh
    instr18sw
    # ---- R-type ALU ----
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
    # ---- U-type ----
    instr29lui
    # ---- Branches ----
    instr30beq
    instr31bne
    instr32blt
    instr33bge
    instr34bltu
    instr35bgeu
    # ---- Jumps ----
    instr36jalr
    instr37jal
    # ---- RV64I extra loads ----
    instr38ld
    instr39lwu
    # ---- RV64I W-suffix I-type ----
    instr40addiw
    instr41slliw
    instr42srliw
    instr43sraiw
    # ---- RV64I double store ----
    instr44sd
    # ---- RV64I W-suffix R-type ----
    instr45addw
    instr46subw
    instr47sllw
    instr48srlw
    instr49sraw
    # ---- System / Zicsr ----
    instr51csrrw
    instr52csrrs
    instr53csrrc
    instr54csrrwi
    instr55csrrsi
    instr56csrrci
    instr57mret
    # ---- Fence ----
    instr58fence
    # ---- Cache-specific tests (own testbenches) ----
    scratchpad_intensive
    dcache_test
    memory_sections
)

# -------------------------------------------------
# Unified instruction testbench configuration
# Format: TEST_ID  DISPLAY_NAME  EXPECTED_GPIO
# All listed tests use tb/tb_rv64i_instr.sv with plusargs.
# Tests NOT listed here use tb/tb_rv64i_<name>.sv.
# -------------------------------------------------
set(INSTR_TB_CONFIG
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
    "instr51csrrw"     "csrrw"       "29"
    "instr52csrrs"     "csrrs"       "52"
    "instr53csrrc"     "csrrc"       "53"
    "instr54csrrwi"    "csrrwi"      "22"
    "instr55csrrsi"    "csrrsi"      "25"
    "instr56csrrci"    "csrrci"      "20"
    "instr57mret"      "mret"        "57"
    "instr58fence"     "fence"       "58"
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

# Per-test linker scripts
set(memory_sections_LDSCRIPT ${NP_ROOT}/rv64Sim/memory_sections.ld)

add_custom_target(regression)

foreach(TEST ${ASM_TESTS})

    set(TEST_BUILD_DIR ${CMAKE_BINARY_DIR}/${TEST})

    # Testbench selection: unified TB or test-specific TB
    if(DEFINED INSTR_TB_NAME_${TEST})
        set(_TB_FILE    ${PROJECT_ROOT}/tb/tb_rv64i_instr.sv)
        set(_EXTRA_ARGS
            "-DTB_TEST_NAME=${INSTR_TB_NAME_${TEST}}"
            "-DTB_EXPECTED=${INSTR_TB_EXPECTED_${TEST}}")
    else()
        set(_TB_FILE    ${PROJECT_ROOT}/tb/tb_rv64i_${TEST}.sv)
        set(_EXTRA_ARGS "")
    endif()

    # Optional linker script
    set(LDSCRIPT_CMAKE_ARGS "")
    set(LDSCRIPT_DEPS "")
    if(DEFINED ${TEST}_LDSCRIPT)
        list(APPEND LDSCRIPT_CMAKE_ARGS -DLINKER_SCRIPT=${${TEST}_LDSCRIPT})
        list(APPEND LDSCRIPT_DEPS ${${TEST}_LDSCRIPT})
    endif()

    # ---------------- ASM ----------------
    add_custom_command(
        OUTPUT ${TEST_BUILD_DIR}/asm/rv64i.mem
        COMMAND ${CMAKE_COMMAND} -E make_directory ${TEST_BUILD_DIR}/asm
        COMMAND ${CMAKE_COMMAND}
                -DASM_FILE=${NP_ROOT}/rv64Sim/${TEST}.asm
                ${LDSCRIPT_CMAKE_ARGS}
                -S ${NP_ROOT}/rv64Sim
                -B ${TEST_BUILD_DIR}/asm
        COMMAND ${CMAKE_COMMAND}
                --build ${TEST_BUILD_DIR}/asm --target mem
        DEPENDS ${NP_ROOT}/rv64Sim/${TEST}.asm ${LDSCRIPT_DEPS}
        COMMENT "Assembling ${TEST}"
    )

    # ---------------- SIM ----------------
    add_custom_target(sim_${TEST}
        COMMAND ${CMAKE_COMMAND}
                -DPROJECT_ROOT=${PROJECT_ROOT}
                -DIP_ROOT=${IP_ROOT}
                -DNP_ROOT=${NP_ROOT}
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
# Error collection
# -------------------------------------------------
list(JOIN ASM_TESTS "," TESTS_CSV)
add_custom_target(collect_errors
    COMMAND ${CMAKE_COMMAND}
        -DPROJECT_ROOT=${PROJECT_ROOT}
        -DBUILD_ROOT=${CMAKE_BINARY_DIR}
        -DTESTS=${TESTS_CSV}
        -P ${NP_ROOT}/collect_errors.cmake
    COMMENT "Collecting regression error files"
)
add_dependencies(collect_errors regression)
