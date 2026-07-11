================================================================================
 HowTo: Cadence Design Flow fuer X-FAB (Simulation -> Synthese -> GDSII)
================================================================================

Stand:        06.07.2026 (Mitschrift), ueberarbeitet 11.07.2026
Autor:        Prof. Dr.-Ing. Andreas Siggelkow
Testvehikel:  Dummy-Adder (ha_e/ha_a/ha_tb) fuer die Werkzeugkette
Zieldesign:   RV_NoPipeline (RISC-V CPU, SystemVerilog)
Ziel:         Von der RTL-Simulation bis zum Tape-Out (GDSII) bei X-FAB


--------------------------------------------------------------------------------
1. Zugang / Environment
--------------------------------------------------------------------------------

Login:      edauser
Projekt:    risc5cadence

Umgebung laden:

    source ./start_it.sh


--------------------------------------------------------------------------------
2. Simulation (xrun)
--------------------------------------------------------------------------------

Beispielaufruf mit dem Dummy-Adder (Entity/Architecture + Testbench):

    xrun -gui ./src/01_ha_e.vhd ./src/01_ha_a.vhd ./tb/01_ha_tb.vhd \
         -top ha_tb_e -access +rwc

Hinweise:
  - "-gui" oeffnet die SimVision-Oberflaeche.
  - "-access +rwc" gibt vollen Signal-Zugriff (read/write/connectivity) fuer
    Waveform-Debugging.
  - "-top" legt die Testbench-Entity als Top-Level fest.


--------------------------------------------------------------------------------
3. Synthese (Genus)
--------------------------------------------------------------------------------

Genus starten und Skript laden:

    genus -> source ./scripts/source.tcl

Alternativ direkt mit GUI:

    genus -files ./scripts/source.tcl -execute "gui_show"


--------------------------------------------------------------------------------
4. X-FAB spezifische Punkte
--------------------------------------------------------------------------------

4.1 Prozess-Auswahl
    "Look for best technology" auf dem X-FAB-Portal nutzen, um den passenden
    Prozess fuer das Design zu finden.

4.2 EDA-Files / Design Kit
    1. XENV: Design Kit Packages -> Environment -> xenv-cadence
    2. PDK-Kernel:
       - xh035-D_CELLS-liberty_MOS  -> liefert die .lib-Files (Timing/Power)

4.3 Memory Compiler
    Frage:  Wie laedt man einen Memory Compiler herunter?
    Antwort: Front-End-Memory-Compiler stehen NICHT als Download bereit.
             Sie muessen ueber das "my X-FAB"-Portal direkt gestartet werden
             (Play-Icon des gewuenschten Compilers anklicken).
             Pfad im Portal: Design -> Compilers & Webtools


--------------------------------------------------------------------------------
5. Gesamter Design-Flow (Core-Design, ohne Pads)
--------------------------------------------------------------------------------

  1. Download RV_NoPipeline (SystemVerilog, GitHub)
       - RTL verstehen
       - Architektur dokumentieren

  2. Compile & RTL-Simulation
       - Testbench verstehen
       - Funktionalitaet verifizieren

  3. SRAM-Integration
       - Welche SRAMs werden benoetigt?
       - RTL an SRAM-Instanzen anpassen
       - Behavioral Models der SRAMs einbinden
       - RTL-Simulation (mit SRAM-Modellen) wiederholen

  4. Logic Synthesis
       - SRAMs sind Black Boxes / Makros
       - Netlist-Generierung
       - Area-/Timing-Check

  5. Gate-Level-Simulation
       - Synthese-Netlist simulieren
       - Funktionalitaet ok?

  6. DFT (Design for Test)
       - Scan-Chain-Insertion
       - SRAM-BIST-Insertion
       - DFT-Rule-Check

  7. Gate-Level-Simulation mit DFT
       - Funktionaler Modus
       - Scan-/BIST-Modus-Check

  8. Static Timing Analysis (STA)
       - Timing-Analyse
       - Timing-Probleme beseitigen
       - ggf. Re-Synthese

  9. Physical Design
       - Floorplanning
       - Power Grid
       - Placement
       - Clock Tree Synthesis (CTS)
       - Routing
       - Post-Route Timing Closure

 10. Physical Verification
       - DRC (Design Rule Check)
       - LVS (Layout vs. Schematic)
       - Antenna Checks
       - ERC (Electrical Rule Check)
       - Signoff STA

 11. Tape-out


--------------------------------------------------------------------------------
6. Bemerkungen
--------------------------------------------------------------------------------

  - SRAMs gehoeren unbedingt VOR die Synthese. Die Synthese muss die Makros
    bereits kennen. Nachtraeglich SRAMs einzubauen fuehrt fast immer zu
    unnoetiger Mehrarbeit.

  - STA findet mehrfach statt: eine erste STA direkt nach der Synthese, und
    eine wesentlich wichtigere spaeter nach Place & Route.

  - "To Layout" ist kein einzelner Schritt, sondern der gesamte
    Physical-Design-Flow (Floorplan -> Placement -> CTS -> Routing ->
    Timing Closure).

  - Bei Nutzung von OpenROAD oder Cadence Innovus: die einzelnen Schritte
    des Physical Designs im Detail kennenlernen.

Kurzfassung des Flows:

    RTL verstehen -> RTL simulieren -> SRAMs integrieren -> Synthese ->
    Gate-Level-Simulation -> Scan & SRAM-BIST ->
    Gate-Level-Simulation mit DFT -> STA -> Floorplan & Place-and-Route ->
    DRC/LVS/ERC -> Tape-out-Vorbereitung

Das entspricht im Wesentlichen dem Ablauf eines industriellen ASIC-Projekts,
z. B. bei X-FAB, TSMC oder GlobalFoundries.


--------------------------------------------------------------------------------
7. Mit Pads: Core-Level vs. Chip-Level
--------------------------------------------------------------------------------

In einem echten ASIC-Projekt gibt es typischerweise zwei Top-Level:

  Core Top-Level (RTL)
    - CPU
    - SRAMs
    - Peripherie
    - Busse
    - Clock-/Reset-Logik

  Chip Top-Level (ASIC)
    - Core-Instanz
    - Pad-Ring
    - Power Pads
    - ESD-Strukturen
    - PLL (falls vorhanden)
    - Bondpads
    - IO-Zellen
    - ggf. JTAG-Controller
    - Power Switches / Level Shifter (je nach Technologie)

Fuer einen X-FAB-Chip sieht der erweiterte Ablauf so aus:

   1. RTL Design (Core)
   2. RTL Simulation
   3. SRAM Integration
   4. Synthesis
   5. Gate-Level Simulation
   6. Scan & SRAM-BIST
   7. Gate-Level Simulation (mit DFT)
   8. Chip Top-Level erstellen:
        - Core instanziieren
        - Pads
        - Power Pads
        - Clock Pads
        - Reset Pad
        - JTAG-/Scan-Pins
        - IO Assignment
   9. Floorplanning:
        - Die Size bestimmen
        - SRAMs platzieren
        - Pad-Ring
        - Power-Ring
  10. Place & Route
  11. CTS
  12. Routing
  13. STA & Timing Closure
  14. DRC / LVS / ERC
  15. Tape-out

Warum kommen die Pads erst NACH der Synthese?

  Die Synthese interessiert sich im Wesentlichen nur fuer den Core. Die
  Pad-Zellen sind Standardzellen der Foundry und werden erst auf dem
  Chip-Level eingefuegt. Auch die Stromversorgung wird erst im Physical
  Design vollstaendig aufgebaut.

  In der Industrie trennt man deshalb haeufig:

      Core Design -> Core Netlist -> Chip Integration -> Physical Design


--------------------------------------------------------------------------------
8. Empfohlene Phaseneinteilung fuer X-FAB
--------------------------------------------------------------------------------

Phase 1 - Core:
    - RTL
    - Simulation
    - SRAM
    - Synthese
    - Scan/BIST
    - STA

Phase 2 - Chip:
    - Chip Top-Level
    - Pad Ring
    - Power Planning
    - Floorplan
    - Placement
    - CTS
    - Routing
    - Signoff (STA, DRC, LVS)
    - Tape-out


================================================================================
 Kontakt
================================================================================

Prof. Dr. Andreas Siggelkow
Professor EI, EM, EEM
ASIC-Design and Computer Architectures

Gebaeude / Building H, H218
+49 751 501-9633
andreas.siggelkow@rwu.de

Hochschule Ravensburg-Weingarten
University of Applied Sciences
Doggenriedstrasse, 88250 Weingarten, Germany

www.rwu.de
