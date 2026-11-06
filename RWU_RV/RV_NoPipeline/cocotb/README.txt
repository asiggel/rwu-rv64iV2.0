# Regression: full regression + ISS scoreboard
make

# Smoke test: instr06addi, expected=255
make COCOTB_TEST_MODULES=test_poc


Was bringt Randomization hier konkret? Nicht "mehr Stimuli", sondern das Treffen von Timing-Koinzidenzen, die man von Hand mühsam einzeln konstruieren müsste, hier aber im Code schon als explizite
  Sonderfälle sichtbar sind:

  - Trap-Prioritätskollision: asCPUx.sv:534-543 behandelt Illegal > Misaligned > IRQ explizit als Priorität — ein IRQ, der exakt im selben Zyklus wie eine Illegal-Instruktion ankommt, ist der
  eigentliche Test dieser Priority-Logik. Von Hand: ein Zyklus genau treffen bei mehreren FSM-States. Randomisiert (IRQ-Ankunftszyklus × Instruktionstyp durchwürfeln): fällt automatisch raus.
  - MIE-Toggle-Race: IRQ kommt exakt im Zyklus an, in dem Software gerade mstatus.MIE setzt/löscht oder mret ausführt (csr_mstatus_r-Übergänge, asCPUx.sv:601ff). Klassische reale HW-Bugquelle.
  - Back-to-back IRQ: csr_mip_r[11] <= irq_ext_sync2_s ist ein direktes Wire-Through (asCPUx.sv:564, Kommentar "Direct wire-through") — kein Sticky-Pending-Bit. Was passiert, wenn die IRQ-Quelle
  während der ISR (vor mret) erneut pulst? Interessanter Cross zum Durchwürfeln.
  - Multi-Cycle-Fenster: Instruktionen brauchen mehrere States (FETCH/EXEC/EXECLD); der genaue Zyklus, in dem irq_pending_s gesampled wird, variiert je nach Instruktionstyp.

  Der Haken, den ich den Studierenden ehrlich mitgeben würde: reine Randomisierung ohne Referenzmodell/Checker bringt nichts — ihr braucht ein kleines Prädiktionsmodell ("bei IRQ-Injection in Zyklus
  X während Instruktion Y erwarte ich mepc=Z, mcause=0x8...B"), sonst seht ihr nur, dass nichts abgestürzt ist, nicht ob das Ergebnis korrekt war. Das ist genau der Punkt, den cocotb-coverage mit
  Coverage-Bins (z. B. Cross aus IRQ-Ankunftszyklus × CPU-State × gleichzeitiger Trap-Typ) sichtbar macht: nicht "wir haben 10 000 Zufallszyklen gefahren", sondern "wir haben nachweislich jede der N
  Kollisionskombinationen mindestens einmal getroffen".
# IRQ
# venv (shared with the Makefiles): ~/venvs/cocotb, Python 3.14, cocotb 2.1.0
#   python3 -m venv ~/venvs/cocotb
#   ~/venvs/cocotb/bin/pip install cocotb==2.1.0 cocotb-coverage==2.0 pytest pyyaml
alias python3="$HOME/venvs/cocotb/bin/python"
python3 test_runner_irq01.py 
python3 test_runner_irq02_cov.py 
