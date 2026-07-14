================================================================================
ip_icu -- Interrupt Control Unit (ICU) -- REQUIREMENTS
================================================================================
Status:  approved, implemented
Origin:  requested by A. Siggelkow (project lead), 2026-07-14, as a reference
         solution for the RWU-RV64I "build your own ICU" student assignment
         (see ip_icu/DUMMY_ICU/asInterruptController.sv for the graded
         submission this reference contrasts with).
Scope:   RV_NoPipeline and RV_PipelineCacheFwd (both RWU-RV64I chip variants)

This file lists every requirement the ICU was built against: the ones stated
directly by the requester, the ones settled through clarifying questions
during the session, and the ones added because they were gaps in the
original request but necessary for a complete, spec-writable peripheral.
Each requirement carries a source tag so later readers can tell which is
which:

  [USER]    - stated directly by the requester
  [ASKED]   - the requester was asked and picked one of several options
  [ADDED]   - identified as a gap and added; not explicitly requested

--------------------------------------------------------------------------------
1. FUNCTIONAL REQUIREMENTS
--------------------------------------------------------------------------------

REQ-1  [USER] One ICU design must work for BOTH chip variants (RV_NoPipeline
       and RV_PipelineCacheFwd), not two separate implementations.
       Rationale: the two CPUs (as_cpux, cc_cpupipefwd) already share the
       same CSR/trap semantics and consume the same single external
       interrupt bit (irq_ext_i[7]); the ICU should be equally shared.

REQ-2  [USER] Deliverable location: RTL under ip_icu/src/, testbench under
       ip_icu/tb/, matching the on-disk convention already used by every
       other IP block (ip_gpio, ip_uart_v2, ip_qspi, ...).

REQ-3  [USER] The ICU must reserve input slots for peripherals that do not
       exist yet. At least 2 extra ("currently unused") inputs were
       explicitly requested.

REQ-4  [USER] Priority resolution across simultaneously pending sources is
       required ("Priorität ist wichtig").

REQ-5  [USER] Per-source interrupt masking is required ("Masking ist
       wichtig").

REQ-6  [USER] The ICU must be controllable through memory-mapped registers;
       an address range for it must be defined as part of this work
       ("Controlle über memory mapped Register (Adressbereich festlegen)").

REQ-7  [USER] The ICU is a Wishbone peripheral (same Wishbone Classic
       slave-BPI convention as every other peripheral in this SoC:
       as_slave_bpi / wbdAddr_i, wbdDat_i/o, wbdWe_i, wbdSel_i, wbdStb_i,
       wbdAck_o, wbdCyc_i).

REQ-8  [USER] Inputs: one IRQ line per existing peripheral, plus the 2 spare
       lines from REQ-3.

REQ-9  [USER] Output: exactly one aggregated IRQ line to the CPU core.

REQ-10 [USER] Any requirement gap found while implementing this must be
       either asked about, or -- if reasonably decided without the user --
       added to this file so it is visible after the fact
       ("Wenn ich etwas vergessen habe, bitte nachfragen" / "auch die
       Punkte die ich vergessen habe und die du hinzufügst").

REQ-11 [USER] Deliverables: this file (README_REQ.txt) and a companion
       README_IMPL.txt, both detailed enough that the formal LaTeX spec
       chapter for this peripheral can be written from them afterward,
       without re-deriving the design from the RTL.

--------------------------------------------------------------------------------
2. REQUIREMENTS SETTLED BY CLARIFYING QUESTIONS (asked before implementation)
--------------------------------------------------------------------------------

REQ-12 [ASKED] Scope: integrate the ICU into BOTH chips' top-level RTL now
       (asTopMem.sv for RV_NoPipeline and RV_PipelineCacheFwd, plus the
       shared address decoder and package), not just deliver a standalone,
       unintegrated IP block.
       Options offered: (a) standalone IP + testbench only, address range
       documented but not wired in; (b) full integration now, replacing the
       RV_PipelineCacheFwd "dummy ICU" OR-combine placeholder and
       RV_NoPipeline's direct GPIO/UART-to-irq_ext_i wiring.
       Chosen: (b), full integration.

REQ-13 [ASKED] Pending-bit semantics: a source's sticky RIS bit is
       edge-triggered (latches the source line's 0->1 transition, like
       GPIO0's IRQSS / UART0's RIS), not a level pass-through of the raw
       source line.
       Options offered: (a) edge-triggered + sticky, matching the existing
       GPIO0/UART0 convention, race-free by construction (see REQ-19);
       (b) level pass-through with a clear register, closer to (and
       inheriting the race condition of) the graded student submission.
       Chosen: (a), edge-triggered + sticky.

REQ-14 [ASKED] Register-map capacity: the register file provisions 8
       interrupt-source slots (one full byte per bitmap register), not just
       the minimum of 5 (3 currently wired peripherals + the 2 spares from
       REQ-3).
       Options offered: (a) 8 slots, so both chips get an identical
       register map (unused slots tied to 0) and 3 slots remain free for
       peripherals beyond the 2 explicitly requested spares; (b) exactly 5
       slots, minimal but requires widening the register map again at the
       next new peripheral.
       Chosen: (a), 8 slots.

--------------------------------------------------------------------------------
3. REQUIREMENTS ADDED DURING IMPLEMENTATION (gaps in the original request)
--------------------------------------------------------------------------------

REQ-15 [ADDED] Cause identification: the ICU must expose a register telling
       firmware WHICH source is the current highest-priority pending and
       unmasked interrupt (IRQID: valid bit + 3-bit source id), so the ISR
       does not have to poll every peripheral's own MIS register to find
       the cause. This is the single biggest practical benefit of a real
       ICU over the previous OR-combine placeholder, but was not named
       explicitly in the original request.
       Cross-reference: RWU_RV/RV_NoPipeline/spec/02_prod/02_product_text14.tex,
       "Open items" paragraph, describes exactly this missing capability.

REQ-16 [ADDED] Global interrupt enable: a CTRL register bit (GIE) gates the
       single output line to the CPU independent of per-source masking, for
       a cheap "disable everything, no bitmask needed" critical-section
       primitive. Per-source IMSC (REQ-5) alone cannot do this atomically
       for an arbitrary/changing set of enabled sources.

REQ-17 [ADDED] Peripheral ID register at offset 0, read-only, matching every
       other peripheral in this SoC (GPIO0, QSPI0, UART0, CGU all expose an
       ID register), for firmware auto-detection / consistency.

REQ-18 [ADDED] Deterministic tie-break rule: when two or more pending,
       unmasked sources carry the same priority value, the lowest source
       index wins. Not specified by the requester; left undefined this
       would be simulator/synthesis-dependent (a real correctness bug
       class).

REQ-19 [ADDED] The pending/clear mechanism must not lose a real interrupt
       occurrence that lands in the same clock cycle as a software clear of
       that same source's PREVIOUS occurrence (a documented race condition
       found in the graded student submission, ip_icu/DUMMY_ICU/
       asInterruptController.sv, where a same-cycle set+clear on the same
       bit is resolved implicitly and undocumented, in the clear's favour).
       Resolution: hardware SET (edge or SW-forced ISR write) takes
       priority over a software CLEAR (ICR write) landing in the same
       cycle. Verified directly by testbench case T6 (see README_IMPL).

REQ-20 [ADDED] IRQID must not use source index 0 as a double meaning of
       "GPIO0" and "no interrupt pending" -- it needs an explicit VALID bit
       separate from the id field. (The same ambiguity class as REQ-19:
       using a real value as an implicit "empty" sentinel.)

REQ-21 [ADDED] Fixed, chip-independent source-index assignment (0=GPIO0,
       1=UART0, 2=QSPI0, 3/4=the 2 spares from REQ-3, 5-7=further reserved)
       so a single firmware driver works unmodified on both chip variants,
       per REQ-1. RV_NoPipeline has no QSPI0, so source 2 is permanently
       tied to 0 there; RV_NoPipeline also gains a previously-nonexistent
       working UART0 interrupt path as a side effect (see README_IMPL,
       "Behavioural change on RV_NoPipeline").

REQ-22 [ADDED] Register width/alignment: all ICU registers are 64-bit wide
       and 8-byte aligned, per the existing project-wide convention (see
       RWU_RV/RV_NoPipeline/spec/00_rwurv64i_all.tex, System Memory Map
       section: "All peripheral registers are 64-bit wide and 8-byte
       aligned").

REQ-23 [ADDED] No cross-clock-domain synchronization inside the ICU: all
       interrupt sources (GPIO0, QSPI0, UART0), the ICU itself, and the CPU
       run on the same clk_div_s domain in both chips. This is an explicit,
       documented assumption, not a silent one -- if a future peripheral
       source is added on a different clock domain, it must be synchronized
       into clk_div_s BEFORE reaching irq_src_i; the ICU itself provides no
       synchronizer.

REQ-24 [ADDED] Reset defaults must keep the system interrupt-functional
       without any firmware setup, matching the fact that interrupts
       already worked (via the old OR-combine / direct wiring) before this
       ICU existed: IMSC resets to all-enabled, CTRL.GIE resets to 1.
       Firmware that never touches the ICU's registers sees the same
       "interrupts just work" behaviour as before.

REQ-25 [ADDED] Address range: base 0x0000_0001_0000_0800, size 512 B,
       AW=8, chip-select cs[5] -- the first free slot after UART0
       (0x...0600-0x...07FF), following the same 0x200-spacing, AW=8
       convention already used for QSPI0/UART0. See README_IMPL for the
       full register map at this base.

REQ-26 [ADDED] The ICU must be verified standalone (self-checking
       testbench, ip_icu/tb/) BEFORE chip integration, and the existing
       chip-level regression suites (xsim + cocotb, both variants) must
       still pass afterward with zero regressions. Verification depth was
       the single largest gap in the graded student submission being
       contrasted here (zero tests, not wired into the design at all); this
       requirement exists specifically so that gap is not repeated.

================================================================================
End of requirements. See ip_icu/README_IMPL.txt for the implementation that
satisfies them, including the register map, source-index table, and
verification results.
================================================================================
