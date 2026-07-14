================================================================================
ip_icu -- Interrupt Control Unit (ICU) -- IMPLEMENTATION
================================================================================
Author:   Claude Sonnet 5 (AI-generated, cc_ prefix per project convention)
Date:     2026-07-14
Requirements: see ip_icu/README_REQ.txt (REQ-1..REQ-26)
Status:   implemented, standalone-verified, integrated into both chip
          variants; see section 9 for the final regression results.

This file is written to be spec-source material: register map, bit fields,
timing, and rationale are documented in enough detail that
RWU_RV/RV_NoPipeline/spec/00_rwurv64i_all.tex can gain an "ICU" section
(chapter "Peripherals", alongside GPIO/I-Mem/QSPI/UART) directly from this
text, the same way those sections were written from the corresponding RTL.

--------------------------------------------------------------------------------
1. OVERVIEW
--------------------------------------------------------------------------------

The ICU is a Wishbone-slave peripheral that aggregates up to 8 peripheral
interrupt lines into the single external interrupt bit both CPU
implementations consume (irq_ext_i[7] on as_cpux and cc_cpupipefwd -- see
RWU_RV/RV_NoPipeline/spec/02_prod/02_product_text14.tex, "Peripheral-to-CPU
path"). It replaces:

  - RV_PipelineCacheFwd: the "dummy ICU" OR-combine placeholder in
    asTopMem.sv (irq_combined_s = irq_gpiox_s | qspi_irq_s | irq_uart_s;
    no priority, no masking, no per-source enable, no cause identification).
  - RV_NoPipeline: the direct wiring of irq_external_s[7]=irq_gpiox_s and
    irq_external_s[6]=irq_uart_s. Bit 6 was dead: only bit 7 is consumed by
    as_cpux, so UART0 interrupts never reached the CPU on this variant (see
    section 8, "Behavioural change on RV_NoPipeline").

Two-module split (mirrors ip_gpio's as_gpio.sv / as_gpio_top.sv kernel/BPI
split):

  ip_icu/src/cc_icu.sv      kernel: per-source edge detection + priority
                             arbitration. Pure signal processing, no
                             BPI-addressable state.
  ip_icu/src/cc_icu_top.sv  Wishbone wrapper: owns all registers, instantiates
                             as_slave_bpi (the existing generic Wishbone
                             Classic slave translator, RWU_RV/RV_NoPipeline/
                             src/asSBpi.sv) and cc_icu.

--------------------------------------------------------------------------------
2. SOURCE INDEX ASSIGNMENT (as_pack.sv: icu_src_*_c, fixed on both chips)
--------------------------------------------------------------------------------

  Index  Name     RV_NoPipeline          RV_PipelineCacheFwd
  -----  -------  ---------------------  ---------------------
  0      GPIO0    wired (irq_gpiox_s)    wired (irq_gpiox_s)
  1      UART0    wired (irq_uart_s)     wired (irq_uart_s)
  2      QSPI0    tied to 1'b0 (n/a)     wired (qspi_irq_s)
  3      SPARE0   tied to 1'b0           tied to 1'b0
  4      SPARE1   tied to 1'b0           tied to 1'b0
  5      reserved tied to 1'b0           tied to 1'b0
  6      reserved tied to 1'b0           tied to 1'b0
  7      reserved tied to 1'b0           tied to 1'b0

Both variants use the identical register map; a single firmware ICU driver
works unmodified on either chip (REQ-21). A tied-off source's RIS bit can
still be forced via ISR for software testing but will never set from real
hardware.

--------------------------------------------------------------------------------
3. ADDRESS MAP PLACEMENT
--------------------------------------------------------------------------------

  Base address : 0x0000_0001_0000_0800
  End address  : 0x0000_0001_0000_09FF
  Size         : 512 B
  AW           : 8   (as_decode.sv range is 512 B; the register file below
                       only actually uses the first 72 B of it, same
                       generous-headroom pattern as UART0/QSPI0)
  Chip-select  : cs[5]  (chipsel widened from 5 to 6 in as_pack.sv)

This is the first free slot immediately after UART0
(0x0000_0001_0000_0600-0x...07FF), following the existing 0x200-spacing /
AW=8 convention already used for QSPI0 and UART0. See
RWU_RV/RV_NoPipeline/src/as_decode.sv and as_pack.sv (chipsel, icu0_start/
end_address_c) for the RTL source of truth.

--------------------------------------------------------------------------------
4. REGISTER MAP (base + offset, all 64-bit, 8-byte aligned)
--------------------------------------------------------------------------------

  Offset  Name    Mode  Reset          Description
  ------  ------  ----  -------------  --------------------------------------
  0x00    ID      ro    0x40           Peripheral ID (constant)
  0x08    RIS     ro    0x00           Raw Interrupt Status: bit[i] = source i
                                        sticky pending (edge-triggered, see
                                        section 5)
  0x10    IMSC    rw    0xFF           Interrupt Mask Control: bit[i] = 1
                                        enables source i into MIS
  0x18    MIS     ro    0x00           Masked Interrupt Status = RIS & IMSC
                                        (registered, 1-cycle-delayed readback
                                        copy -- see section 6)
  0x20    ICR     wo    --             Interrupt Clear: write bit[i]=1 clears
                                        RIS[i]. Reads as 0.
  0x28    ISR     wo    --             Interrupt Set (SW test/force): write
                                        bit[i]=1 sets RIS[i] without a real
                                        source edge. Reads as 0.
  0x30    PRIO    rw    0x567          Priority: 8 x 4-bit nibbles packed in
                                        bits[31:0], source i in bits[4i+3:4i].
                                        0=lowest .. 15=highest. Reset:
                                        source0(GPIO0)=7, source1(UART0)=6,
                                        source2(QSPI0)=5, sources 3-7=0.
  0x38    IRQID   ro    0x00           bit[3]=VALID (|MIS), bits[2:0]=id of
                                        the highest-priority source with
                                        MIS[id]=1 (ties: lowest id wins).
                                        Independent of CTRL.GIE -- see
                                        section 5.
  0x40    CTRL    rw    0x01           bit[0]=GIE, global interrupt enable.
                                        Gates icu_irq_o only, not MIS/IRQID.

Bits above the documented width of each register (e.g. RIS[63:8],
PRIO[63:32]) read back as 0 and are ignored on write.

--------------------------------------------------------------------------------
5. PENDING / ARBITRATION SEMANTICS
--------------------------------------------------------------------------------

RIS is edge-triggered and sticky (REQ-13), not a level pass-through of
irq_src_i. This mirrors GPIO0's IRQSS and UART0's RIS exactly: the raw
source line is a level (it stays high until the peripheral's OWN cause is
cleared, e.g. GPIO0's IRQSC or UART0's ICR); the ICU only latches the source
line's 0->1 transition into a sticky bit via a 2-stage shift register +
rising-edge compare (cc_icu.sv). Firmware then clears that sticky bit
explicitly via the ICU's own ICR, independent of when/whether the
underlying peripheral's own cause is cleared.

Why not a level pass-through: a level-based pending bit (RIS[i] := irq_src_i
[i]) has a race where a software clear issued in the same cycle a fresh
interrupt re-arrives on the same source loses the new occurrence -- this is
the exact, undocumented bug found in the graded student submission this ICU
was built to replace (ip_icu/DUMMY_ICU/asInterruptController.sv: a
same-cycle set+clear on the same bit is resolved implicitly, in the clear's
favour, because the clear's if-branch is textually later in the same
always_ff).

The edge/sticky design still has one same-cycle coincidence to resolve: a
hardware edge (or a software-forced ISR write) landing in the same cycle as
an ICR write clearing that same bit. Resolution (cc_icu_top.sv, the g_ris
generate block): SET wins over CLEAR --

    if (rst_i)                                  RIS[b] <= reset value
    else if (edge_pulse[b] || (ISR write & data[b]))
                                                  RIS[b] <= 1        (SET)
    else if (ICR write & data[b])
                                                  RIS[b] <= 0        (CLEAR)

A real interrupt is therefore never silently dropped. Verified directly by
testbench case T6 (section 9): a real hardware edge is timed to land in the
exact same clock edge as a coincident ICR write to the same bit, and RIS is
confirmed to end up SET, not CLEARed.

Priority arbitration (cc_icu.sv, combinational): among all sources with
MIS[i]=1, the one with the numerically highest PRIO nibble wins; a strict
'>' comparison (not '>=') in the scan means an already-found candidate is
only displaced by a STRICTLY higher priority, which is how "lowest index
wins ties" (REQ-18) is implemented without a separate tie-break step.

IRQID (irq_valid_o / irq_id_o in the kernel) is derived from MIS and PRIO
only, independent of CTRL.GIE. icu_irq_o (the one line reaching the CPU) is
`GIE & irq_valid_o`. This split is deliberate: IRQID stays a useful
diagnostic/debug register even while interrupts are globally disabled,
while the actual CPU-facing wire is what GIE gates (REQ-16).

--------------------------------------------------------------------------------
6. TIMING
--------------------------------------------------------------------------------

  - Wishbone access: zero-wait-state, combinational ACK (as_slave_bpi is
    purely combinational), identical to every other peripheral in this SoC.
  - Edge-to-RIS latency: 2 clock edges from a source's 0->1 transition to
    the corresponding RIS bit being readable (2-stage shift register, same
    latency as GPIO0's own pin-change detector).
  - MIS combinational vs registered: mis_comb_s (RIS & IMSC, no extra
    latency) feeds the priority arbiter/IRQID directly; the MIS register
    readback (offset 0x18) is a registered copy of mis_comb_s and therefore
    lags it by 1 cycle. This is the same split GPIO0 uses (irq_mis_s comb
    vs mis_reg_s registered) -- the CPU-facing path is never delayed by a
    register access latency, only the software-visible MIS snapshot is.
  - No cross-clock-domain synchronization inside the ICU (REQ-23): all
    sources, the ICU, and the CPU share clk_div_s in both chips.

--------------------------------------------------------------------------------
7. TOP-LEVEL INTEGRATION (both variants, asTopMem.sv)
--------------------------------------------------------------------------------

  cc_icu_top #(.NUM_SOURCES(icu_num_sources)) icu0 (
    .rst_i(rst_i), .clk_i(clk_div_s),
    .wbdAddr_i(...[ICU0_AW-1:0]), .wbdDat_i(...), .wbdDat_o(dBusDataRdIcu_s),
    .wbdWe_i(...), .wbdSel_i(...), .wbdStb_i(wbdstbIcu_s), .wbdAck_o(...),
    .wbdCyc_i(...),
    .irq_src_i({5'b0, qspi_irq_s_or_tied0, irq_uart_s, irq_gpiox_s}),
    .icu_irq_o(icu_irq_s)
  );

RV_NoPipeline: irq_external_s[7] = icu_irq_s (was irq_gpiox_s directly);
irq_external_s[6] now unused/tied 0 (was irq_uart_s, dead anyway -- see
section 8). wbdstbIcu_s = wbdstb1_s & wbdcycarb_s & csx_s[5]; read-mux and
wdbAckAll_s gain a csx_s[5]/wdbAckIcu_s branch, same pattern as every other
peripheral in this file.

RV_PipelineCacheFwd: irq_combined_s removed; irq_ext_i({icu_irq_s,
{7{1'b0}}}) replaces irq_ext_i({irq_combined_s, {7{1'b0}}}). wbdstbIcu_s =
is_periph_req_s & csx_s[5]; periph_rdata_s mux gains a csx_s[5] branch.

--------------------------------------------------------------------------------
8. BEHAVIOURAL CHANGE ON RV_NoPipeline
--------------------------------------------------------------------------------

Before this change, RV_NoPipeline wired UART0's interrupt output to
irq_external_s[6], a bit as_cpux never reads (only bit 7 is synchronized and
consumed) -- so a UART0 interrupt had literally no effect on program flow,
by design gap, not by choice (see
RWU_RV/RV_NoPipeline/spec/02_prod/02_product_text14.tex, "a UART interrupt
currently has no effect on program flow -- firmware must poll UART0's
status registers instead"). Since the ICU now ORs UART0's IRQ into the same
aggregated bit-7 path as GPIO0, RV_NoPipeline firmware that unmasks
UART0 (source 1) in the ICU's IMSC will, for the first time, actually see a
UART0-caused trap. This is intentional and is a genuine capability gain, not
a side effect to guard against -- but any existing RV_NoPipeline test that
implicitly assumed "UART IRQs are inert" (there should be none, since
nothing could previously depend on behaviour that never happened) should be
re-checked if it starts asserting UART0 while GPIO0's own interrupt path is
also being exercised in the same test. See section 9 for the regression
result confirming no existing test broke.

--------------------------------------------------------------------------------
9. VERIFICATION
--------------------------------------------------------------------------------

9.1 Standalone (ip_icu/tb/cc_icu_tb.sv)

Self-checking SystemVerilog testbench (chk64/chk1 scorecard tasks,
PASS/FAIL summary, watchdog -- same style as ip_qspi/tb/asQspiTop_tb.sv).
Run both ways:

  - Verilator 5.049 (ip_icu/CMakeLists.txt, target `simulate`):
      31 PASSED, 0 FAILED. Zero lint warnings (Wall).
  - Vivado xsim 2024.2 (xvlog --sv --relax -d LOGIC_SV ...; xelab; xsim -R):
      31 PASSED, 0 FAILED. Zero VRFC warnings (incl. VRFC 10-3380, the
      declaration-order warning CLAUDE.md rule 1 exists to avoid).

Test list (T1-T11, see file header of cc_icu_tb.sv for the full mapping):
reset defaults; edge-triggered sticky pending; MIS = RIS & IMSC masking;
ICR clear; ISR software force; the T6 same-cycle SET-over-CLEAR race
(REQ-19); priority arbitration across 3 simultaneously pending sources;
tie-break on equal priority (REQ-18); masking removing a source from
arbitration; CTRL.GIE gating icu_irq_o independent of IRQID (REQ-16);
all-idle sanity.

9.2 Chip-level regression (after integration, both variants)

Both as_top_mem tops elaborate cleanly (xvlog --sv --relax + xelab, zero
warnings, zero VRFC 10-3380) with the ICU wired in. Full existing
regression suites were then run end-to-end and compared against the exact
pass counts recorded in the commits that last touched each suite
(829cae1 "RV_NoPipeline: implement ECALL/EBREAK exceptions": 64/64 xsim,
59/59 cocotb; 530f137 "RV_PipelineCacheFwd: implement ECALL/EBREAK...":
70/70 xsim, 59/59 cocotb):

  RV_NoPipeline    xsim (CMake target `regression`, 64 ASM tests): 64/64
                   PASS (0 FAIL, 0 mismatch in the full log). Includes
                   uart_tx/uart_rx/readgpioid/instr59ecall/instr60ebreak/
                   instr99scantest/instr99loadimem.
                   cocotb (ISS scoreboard, test_regression.py): 59/59 PASS.

  RV_PipelineCacheFwd  xsim (CMake target `regression`, 87 ASM tests,
                   70 of which build a `sim_*` target): 70/70 PASS
                   (0 FAIL, 0 mismatch), incl. the cache-specific
                   dcache_test/memory_sections/scratchpad_intensive tests
                   and the hazard-statistics tests (hazard_waw_war,
                   hazard_ctrl_branch, ...).
                   cocotb (ISS scoreboard, test_regression.py, via
                   tb_flash_wrap.sv): 59/59 PASS.

Zero regressions relative to the pre-ICU baseline on either variant or
either verification method (REQ-26).

--------------------------------------------------------------------------------
10. FILE MANIFEST
--------------------------------------------------------------------------------

  ip_icu/README_REQ.txt        requirements (this file's companion)
  ip_icu/README_IMPL.txt       this file
  ip_icu/src/cc_icu.sv          kernel: edge detection + priority arbiter
  ip_icu/src/cc_icu_top.sv      Wishbone register file + BPI + kernel instance
  ip_icu/tb/cc_icu_tb.sv        standalone self-checking testbench
  ip_icu/sim/sim_main.cpp       Verilator C++ harness
  ip_icu/CMakeLists.txt         standalone Verilator build (targets: verilate,
                                 simulate, waves) -- mirrors ip_qspi's flow

  Modified (shared / integration):
  RWU_RV/RV_NoPipeline/src/as_pack.sv     chipsel 5->6; icu_* localparams
  RWU_RV/RV_NoPipeline/src/asDecode.sv    cs[5] address range for ICU0
  RWU_RV/RV_NoPipeline/src/asTopMem.sv        ICU integration (RV_NoPipeline)
  RWU_RV/RV_PipelineCacheFwd/src/asTopMem.sv  ICU integration (RV_PipelineCacheFwd)
  RWU_RV/RV_NoPipeline/sim/CMakeLists.txt         + cc_icu*.sv
  RWU_RV/RV_PipelineCacheFwd/sim/CMakeLists.txt   + cc_icu*.sv
  RWU_RV/RV_NoPipeline/cocotb/Makefile            + cc_icu*.sv
  RWU_RV/RV_PipelineCacheFwd/cocotb/Makefile      + cc_icu*.sv
  RWU_RV/RV_NoPipeline/scripts/00_rv64_elab.tcl   + cc_icu*.sv (Genus filelist)
  RWU_RV/RV_NoPipeline/spec/00_rwurv64i_all.tex   sysmap table: ICU0 row

--------------------------------------------------------------------------------
11. DELIBERATE DESIGN DEVIATIONS (from the nearest existing precedent)
--------------------------------------------------------------------------------

  - ID register is truly read-only (a continuous `assign` to a reset
    constant, no write branch), unlike GPIO0's ID register, which is
    nominally rw in RTL (asGpioTop.sv has a write-enable branch for
    id_reg_s) despite being documented ro in the spec. Not replicated here;
    flagged as an existing minor inconsistency worth fixing in GPIO0
    separately.
  - RIS/IMSC/MIS/PRIO are declared exactly NUM_SOURCES (or
    4*NUM_SOURCES) bits wide internally and zero-extended only at the read
    mux, rather than being stored as full 64-bit registers with mostly-
    constant upper bits (GPIO0's pattern). Avoids driving the same vector
    from two different statement kinds (procedural + continuous) across
    disjoint bit ranges, and is one line shorter per register.
  - CLAUDE.md rule 1 (declaration order: all signals, then assign, then
    always_comb, then always_ff, then generate, then instantiations) is
    followed strictly in both cc_icu.sv and cc_icu_top.sv; several existing
    peripherals in this codebase (predating that rule) interleave register
    blocks with instantiations by conceptual section instead.

--------------------------------------------------------------------------------
12. KNOWN LIMITATIONS / OPEN ITEMS (not requested, listed for completeness)
--------------------------------------------------------------------------------

  - Only 3 of 8 source slots are wired to real hardware on either chip
    (GPIO0, UART0, and -- RV_PipelineCacheFwd only -- QSPI0); slots 3-7 are
    tied to 0 until a future peripheral is connected (this is REQ-3/REQ-14
    working as intended, not a gap).
  - The CPU side still supports Direct trap mode only (single mtvec, no
    per-cause vector table) -- the ICU's IRQID register lets firmware
    branch on cause in software from the one shared handler; it does not
    and cannot add hardware-vectored dispatch, since that would require CPU
    changes outside this peripheral's scope.
  - No nested-interrupt / priority-preemption support: taking a lower-
    priority interrupt does not get preempted by a higher-priority one that
    arrives mid-ISR; RISC-V M-mode with mstatus.MIE cleared during a trap
    (see 02_product_text14.tex) already precludes that at the CPU level for
    both variants, independent of the ICU.
================================================================================
