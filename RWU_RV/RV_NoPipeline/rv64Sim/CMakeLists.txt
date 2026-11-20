cmake_minimum_required(VERSION 3.20)
project(rv64i_asm LANGUAGES ASM)

# -------------------------------------------------
# Tools (absoluter Pfad)
# -------------------------------------------------
set(RISCV_PREFIX /opt/riscv/bin/riscv64-unknown-linux-gnu)
set(AS       ${RISCV_PREFIX}-as)
set(LD       ${RISCV_PREFIX}-ld)
set(OBJCOPY  ${RISCV_PREFIX}-objcopy)

# -------------------------------------------------
# Eingabe: ASM_FILE kann von außen übergeben werden
#   cmake -DASM_FILE=<pfad> -S rv64Sim -B build/asm
# Fallback: rv64i.asm im Source-Verzeichnis
# -------------------------------------------------
if(NOT DEFINED ASM_FILE)
    set(ASM_FILE ${CMAKE_CURRENT_SOURCE_DIR}/rv64i.asm)
endif()

# -------------------------------------------------
# Outputs (immer im Build-Verzeichnis)
# -------------------------------------------------
set(OBJ ${CMAKE_CURRENT_BINARY_DIR}/rv64i.o)
set(ELF ${CMAKE_CURRENT_BINARY_DIR}/rv64i.elf)
set(MEM ${CMAKE_CURRENT_BINARY_DIR}/rv64i.mem)

# -------------------------------------------------
# ASM → OBJ
# -------------------------------------------------
add_custom_command(
    OUTPUT ${OBJ}
    COMMAND ${AS}
            -march=rv64i_zicsr
            -mlittle-endian
            -g
            -o ${OBJ}
            ${ASM_FILE}
    DEPENDS ${ASM_FILE}
    COMMENT "AS-rv64Sim: Assembling ${ASM_FILE}\n : ${AS}\n -march=rv64i_zicsr\n -mlittle-endian\n -g\n -o ${OBJ}\n ${ASM_FILE}"
)

# -------------------------------------------------
# OBJ → ELF
#   Optional linker script:  cmake -DLINKER_SCRIPT=<path>
# -------------------------------------------------
set(LD_EXTRA_ARGS "")
set(ELF_EXTRA_DEPS "")
if(DEFINED LINKER_SCRIPT)
    list(APPEND LD_EXTRA_ARGS -T ${LINKER_SCRIPT})
    list(APPEND ELF_EXTRA_DEPS ${LINKER_SCRIPT})
endif()

add_custom_command(
    OUTPUT ${ELF}
    COMMAND ${LD}
            -b elf64-littleriscv
            ${LD_EXTRA_ARGS}
            -o ${ELF}
            ${OBJ}
    DEPENDS ${OBJ} ${ELF_EXTRA_DEPS}
    COMMENT "AS-rv64Sim: Linking ELF\n : ${LD}\n -b elf64-littleriscv\n ${LD_EXTRA_ARGS}\n -o ${ELF}\n ${OBJ}"
)

# -------------------------------------------------
# ELF → MEM
#   sed: spaces → newlines
#   sed: CR entfernen
#   sed: erste Zeile (Adress-Header) entfernen
# -------------------------------------------------
add_custom_command(
    OUTPUT ${MEM}
    COMMAND ${OBJCOPY}
            -O verilog
            --verilog-data-width 4
            ${ELF}
            ${MEM}
    COMMAND sed -i 's/ /\\n/g' ${MEM}
    COMMAND sed -i 's/\r//g' ${MEM}
    COMMAND sed -i '1d' ${MEM}
    DEPENDS ${ELF}
    COMMENT "AS-rv64Sim: Generating Verilog MEM\n : ${OBJCOPY}\n -O verilog\n --verilog-data-width 4\n ${ELF}\n ${MEM}\n : sed -i 's/ /\\n/g' ${MEM}\n : sed -i 's/\r//g' ${MEM}\n : sed -i '1d' ${MEM}"
)

add_custom_target(mem ALL DEPENDS ${MEM})

set(RV64_MEM ${MEM} CACHE FILEPATH "RV64 memory image")
