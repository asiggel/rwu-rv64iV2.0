# test_csrs.asm
# A simple test for the new Machine-Mode CSRs

.globl _start
_start:
    # 1. Load a test value into a standard register (t0 / x5)
    li t0, 0xDEADBEEF

    # 2. Write the value into the MSCRATCH register (0x340)
    # csrw is a pseudo-instruction for "csrrw x0, mscratch, t0"
    csrw mscratch, t0

    # 3. Read the value from MSCRATCH back into another register (t1 / x6)
    # If successful, t1 should now also contain 0xDEADBEEF
    csrr t1, mscratch

    # 4. Load a new test value for MTVAL (0x343)
    li t0, 0x12345678
    csrw mtval, t0

    # 5. Read the value from MTVAL back into t2 (x7)
    csrr t2, mtval

    # -----------------------------------------------------------------
    # 6. Trigger the Testbench to stop (Success Signal)
    # -----------------------------------------------------------------
    # We need to write the value '6' to the GPIO address so the 
    # testbench (tb_rv64i_test_csrs.sv) executes the $stop command.
    
    li t0, 0x100
    li t1, 6               # The success value expected by the testbench
    sw t1, 0(t0)           # Write 6 to the GPIO

end_loop:
    # Infinite loop as fallback just in case the GPIO write fails
    j end_loop