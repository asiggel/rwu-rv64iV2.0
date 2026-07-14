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


--------------------------------------------------------------------------------
9. zu Memory Compiler
--------------------------------------------------------------------------------

Was macht ein Memory Compiler eigentlich?

  Ein Memory Compiler ist kein Tool, das dir "eine SRAM-Zelle" gibt, sondern
  ein Generator: du gibst eine Konfiguration ein (Wortbreite, Anzahl Worte,
  Single-/Dual-Port, evtl. Anzahl Baenke), und er generiert daraus ein
  fertiges, layoutetes Hard-Macro -- exakt zugeschnitten auf deine Groesse.
  Bei X-FAB laeuft das ueber das "my X-FAB"-Portal (Design -> Compilers &
  Webtools), du waehlst die Konfiguration, klickst Play, und bekommst ein
  Paket zurueck (typischerweise ein ZIP mit mehreren "Views").

Was kommt heraus -- die Views

  Ein SRAM-Makro ist wie ein IP-Block: dieselbe physische Zelle wird in
  mehreren Repraesentationen ausgeliefert, weil jedes Tool in der Kette
  eine andere Sicht braucht:

    View                   Format              Wofuer / in welchem Schritt
    ----------------------------------------------------------------------
    Layout                 GDSII               Physical Design, Tape-out
                                                (finaler GDS-Merge)
    Abstract/Physical      LEF                 Floorplanning & Place&Route
                                                (Innovus) -- Pins, Blockage,
                                                Groesse, aber kein Innenleben
    Timing/Power           Liberty (.lib),     Synthese (Genus) und STA --
                           meist mehrere        genau das, was in den
                           Corner (tt/ss/ff,    "library"-Zeilen in
                           versch. VDD/Temp)    01b_rv64_syn.tcl landet
    Funktionsmodell        Verilog (manchmal   Das ist das "Simulations-
                           VHDL)               Makro": RTL- und
                                                Gate-Level-Simulation
    Schaltplan/Netzliste   CDL/SPICE           LVS (Layout vs. Schematic)
    Test/BIST-Info         meist separates     Grundlage fuer die spaetere
                           Datenblatt +        SRAM-BIST-Insertion
                           Testmodus-          (DFT-Tool, nicht der
                           Beschreibung        Compiler selbst)
    Datenblatt             PDF                 Pinbelegung, Timing-
                                                Diagramme, Area-/Power-
                                                Zahlen, Wahrheitstabelle

  Zur Timing-Sim: viele Memory Compiler liefern KEIN SDF fuer die Zelle
  selbst -- das Timing steckt in der .lib, das Funktionsmodell ist meist
  rein funktional (kombiniert mit $setup/$hold-Checks ueber specify-
  Bloecke, nicht mit voller Verzoegerung). Fuer Gate-Level-Sim reicht das
  i. d. R.

Die Form konkret

  Es ist ein Hard-Macro -- kein synthetisierbares RTL, sondern eine
  fertige, feste Zelle mit definiertem Footprint. Fuer Genus ist es exakt
  das, was in Abschnitt 6 (Bemerkungen) steht: "SRAMs sind Black
  Boxes/Makros" -- die Synthese sieht nur Pins + Timing (.lib), nicht das
  Innenleben.

Wie das ins RTL kommt

  Das Funktionsmodell hat einen konkreten Modulnamen und Pinout (z. B.
  sowas wie XH035_SRAM_1024X32 -- Name haengt vom generierten Makro ab).
  Konkret heisst das:

  1. as_dmem_core.sv / as_imem.sv (aktuell reines Verhaltens-RTL mit
     Register-Array) werden umgebaut: statt "logic [..] mem [..]"
     instanziiert man das SRAM-Makro direkt, mit passendem
     Adress-/Daten-/CS-/WE-/Takt-Mapping.
  2. Da X-FAB-SRAMs synchron lesen UND schreiben (Adresse Takt N -> Daten
     Takt N+1), muss das an der Schnittstelle zur CPU abgefangen werden --
     deckt sich mit dem, was schon im Read.me steht ("jeder Cache-Hit
     kostet effektiv 1 Takt").
  3. Fuer 01a_rv64_sim.tcl: das Verilog-Funktionsmodell kommt zusaetzlich
     in die RTL_FILES-Liste (als Ersatz fuer die bisherige
     Verhaltensbeschreibung).
  4. Fuer 01b_rv64_syn.tcl: die .lib kommt in die library-Liste dazu, das
     Makro wird beim Lesen als Black Box behandelt (Genus erkennt das
     automatisch, wenn kein RTL fuer das Modul gelesen wird, sondern nur
     die Liberty).
  5. Fuer Physical Design (spaeter): das LEF muss zusaetzlich eingebunden
     werden -- VOR dem Floorplanning, sonst kennt Innovus die Flaeche
     nicht.

Sonst noch wichtig

  - Eine Konfiguration = ein Makro. Braucht man unterschiedliche Groessen
    fuer I-Mem und D-Mem, generiert man zwei separate SRAM-Instanzen im
    Portal, nicht eine parametrisierbare IP.
  - SRAM-BIST ist NICHT Teil des Compiler-Outputs. Das Datenblatt/
    Testmodus-Info ist die Grundlage, aber die eigentliche
    BIST-Collar-Logik wird spaeter vom DFT-Tool eingefuegt (eigener
    Flow-Schritt, siehe Abschnitt 5, Punkt 6).
  - Da Front-End-Compiler nur ueber das Portal laufen (nicht downloadbar,
    siehe 4.3), kommt das Paket vermutlich per Download-Link nach dem
    "Play"-Klick -- am besten gleich mit Versionsnummer/Konfigurations-
    namen ablegen, da jede Groessenaenderung ein neues Makro mit neuem
    Namen erzeugt.


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
