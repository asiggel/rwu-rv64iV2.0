================================================================================
 HowTo: Cadence Design Flow fuer X-FAB (Simulation -> Synthese -> GDSII)
================================================================================

Stand:        06.07.2026 (Mitschrift), ueberarbeitet 11.07.2026, 26.11.2026,
              27.11.2026
Autor:        Prof. Dr.-Ing. Andreas Siggelkow
Testvehikel:  Dummy-Adder (ha_e/ha_a/ha_tb) fuer die Werkzeugkette
Zieldesign:   RV_NoPipeline (RISC-V CPU, SystemVerilog), Chip-Top cc_chip_top
Technologie:  X-FAB XH018 (4 Metall-Lagen, LPMOS)
Ziel:         Von der RTL-Simulation bis zum Tape-Out (GDSII) bei X-FAB


--------------------------------------------------------------------------------
1. Zugang / Environment
--------------------------------------------------------------------------------

Login:      edauser
Projekt:    risc5cadence

Rechner:    chip-design01
Werkzeuge:  Cadence-Release 2026/27 (Genus 26.1, Innovus, Xcelium/xrun);
            die Version 2023/24 ist im Labor geloescht

Umgebung laden:

    source ./start_it.sh

X-FAB-Pfaddatei (NDA, liegt NICHT im Repository) bekannt machen:

    export XFAB_PATHS=/pfad/zu/X-FAB/xh018_paths.tcl     (bash)
    setenv XFAB_PATHS /pfad/zu/X-FAB/xh018_paths.tcl     (csh)

Vorlage dafuer: RWU_RV/RV_NoPipeline/scripts/xh018_paths_template.tcl
(Liberty pro Corner, LEF, capTbl/QRC, SPRAM-Makro- und Pad-Zellnamen).


--------------------------------------------------------------------------------
1a. Labor-Checkliste: am Labor-PC nachzuziehen (Stand 27.11.2026)
--------------------------------------------------------------------------------

Zu Hause (ohne X-FAB-Daten) vorbereitet und nur in RTL getestet; im Labor
fehlen noch die X-FAB-Namen in der lokalen $XFAB_PATHS-Datei und die ersten
echten Laeufe. Reihenfolge einhalten, jeder Schritt braucht den vorigen.

Schritt 1: $XFAB_PATHS ergaenzen (Datei liegt NICHT im Repository)
  Vergleich mit der Vorlage zeigt, was fehlt:

      grep -o '^set [A-Z_0-9]*' RWU_RV/RV_NoPipeline/scripts/xh018_paths_template.tcl \
        | sort > /tmp/soll.txt
      grep -o '^set [A-Z_0-9]*' $XFAB_PATHS | sort > /tmp/ist.txt
      comm -23 /tmp/soll.txt /tmp/ist.txt       (= noch einzutragen)

  Neu seit dem letzten Laborbesuch:
    CLKMUX, CLKMUX_I0/_I1/_S/_Q   Takt-Multiplexer 2:1 aus D_CELLS_HD und
                                  seine Pins (cc_clk_mux2: Scan-Takt,
                                  I-Mem-Takt). Gibt es keine eigene
                                  Clock-Mux-Zelle, geht ein normaler MUX2
                                  (die Instanz ist preserve, Genus aendert
                                  sie nicht).
    ICG, ICG_CK/_E/_TE/_Q         Integrated Clock Gate (Latch + AND, mit
                                  Test-Enable) und seine Pins (cc_clk_gate)
    CORE_SITE                     Site-Name der HD-Standardzellreihen
    PAD_CORNER, PAD_FILLERS       IO-Eckzelle, IO-Filler (breiteste zuerst)
    VLOG_MODELS                   Verilog-Simulationsmodelle: D_CELLS_HD,
                                  IO_CELLS_3V, I-Mem-Makro, D-Mem-Makro
    VLOG_DEFINES                  Defines, die die Zellmodelle brauchen
                                  (z. B. funktionales Modell), sonst leer
  Neu fuer Power-Grid, Filler und GDS (Innovus, 02a/02c):
    CORE_FILLERS                  Filler der D_CELLS_HD (breiteste zuerst)
    PG_PINS_VDD/_GND              Supply-Pin-Namen ALLER Zellen am Core-
                                  Netz: Standardzellen, Kernseite der
                                  IO-Zellen, SPRAM-Makros
    PG_PINS_VDDO/_GNDO            Supply-Pins der IO-Seite der IO-Zellen
    PG_LAYER_H, PG_LAYER_V        Metall fuer die waagrechten Ringseiten
                                  (z. B. 3. Metall) und Top-Metall
                                  (senkrechte Ringseiten + Stripes)
    WELLTAP_CELL/_INTERVAL,       nur wenn die Bibliothek Well-Taps/
    ENDCAP_CELL                   Endcaps verlangt (Databook), sonst ""
    STREAM_MAP                    Innovus-Stream-Layer-Map aus dem PDK
    GDS_FILES                     GDS der D_CELLS_HD, IO_CELLS_3V und der
                                  beiden SPRAM-Makros
    GDS_UNIT                      Datenbankeinheiten pro um (meist 1000)

  Wo man die Namen findet (Pfade aus LIBS_TYP / LEF_FILES der Datei):
    ICG       Liberty: Zelle mit  clock_gating_integrated_cell : "latch_posedge..."
                grep -n 'clock_gating_integrated_cell' <std_typ.lib>
              Pins im selben cell()-Block: clock_gate_clock_pin,
              clock_gate_enable_pin, clock_gate_test_pin, clock_gate_out_pin
    CLKMUX    Liberty/Databook: MUX2-Zelle der Clock-Familie (falls vorhanden),
              Pins aus den pin()-Zeilen; I0 = bei S=0 durchgeschaltet
                grep -n 'cell *(.*MU' <std_typ.lib>
    CORE_SITE LEF der Standardzellen:  grep -n '^ *SITE ' <std_cells.lef>
    PAD_*     LEF der IO-Zellen: CLASS PAD SPACER (Filler), Eckzelle (CORNER)
                grep -n -B2 'CLASS PAD\|CLASS ENDCAP\|CORNER' <io_cells.lef>
    VLOG_*    im PDK-Baum der Zellbibliotheken, meist .../verilog/*.v;
              die SPRAM-Modelle liegen im Memory-Compiler-Paket
    PG_PINS_* LEF: Pins mit USE POWER / USE GROUND
                grep -n -B3 'USE POWER\|USE GROUND' <std_cells.lef> <io_cells.lef> <imem.lef>
    PG_LAYER_* Technologie-LEF: LAYER ... TYPE ROUTING, Reihenfolge
    CORE_FILLERS  LEF der Standardzellen: CLASS CORE SPACER
    STREAM_MAP, GDS_FILES  PDK-Baum: .../gds/*.gds, Stream-Map im
              Innovus-/Encounter-Techfile-Verzeichnis (*.map, *streamOut*)
    DRC/LVS   welche Runsets liegen im PDK (Pegasus/PVS, Calibre,
              Assura)? -> PV_TOOL; Deck-Dateien -> DRC_RULES (Haupt-DRC,
              Antenna) und LVS_RULES; Schalter im Kopf der Decks
              (#DEFINE / #IFDEF: Metallstapel, Optionen) -> PV_SWITCHES
    CDL_FILES CDL-Netzlisten der Zellbibliotheken (.../cdl/, .../lvs/),
              SPRAM-CDL aus dem Memory-Compiler-Paket
    LABEL_LAYER  Layer fuer die Pad-Labels: der Text-Layer des Top-
              Metalls, den das LVS-Deck fuer Ports erwartet

Schritt 2: Synthese mit Scan-Insertion (DFT-01, Boundary Scan DFT-02)

      cd RWU_RV/RV_NoPipeline
      ./scripts/genus/genus_syn.sh -b -c

  Pruefen (02_DokuGENUS, Folien mit VERIFY-LAB):
    - build_genus/syn.log ohne "Error   :"; check_design ohne unresolved
    - cc_chip_top_dft_rules.rpt / _dft_rules_final.rpt: keine Violations,
      die das Scannen verhindern (define_test_mode/define_shift_enable auf
      internen Pins core/as_jtag/... -- erster Lauf mit echtem Genus!)
    - cc_chip_top_scan_chains.rpt: Kette sc01, Laenge notieren
      (= +SCAN_LENGTH der Gate-Level-Simulation)
    - core/bscan und core/as_jtag NICHT in der Kette (dft_dont_scan)
    - Warnung "clock used as data" am Boundary-Scan-Eingang clk_i ist
      erwartet (Observe-only-Zelle, CLAUDE.md Regel 8, Ausnahme)
    - Timing-Reports pro View: Worst Slack >= 0

Schritt 3: Place & Route mit Power-Grid, Core-Fillern und GDS

      ./scripts/innovus/innovus_pnr.sh -b -s fp -c   (erst nur Floorplan)
      ./scripts/innovus/innovus_pnr.sh -o fp         (ansehen)
      ./scripts/innovus/innovus_pnr.sh -b -c         (alles bis GDS)

  Pruefen:
    - run.log: "AS-pnr: die bbox" = 0 0 2600 2600 (der zusaetzliche
      Rand von 35 um fuer den Power-Ring darf den Die nicht vergroessern),
      Lage der SPRAM-Makros ("AS-pnr: I-Mem ... at")
    - GUI (-o fp): Core-Ring, Stripes, Rails; Makros mit Halo; die
      Supply-Pads mit dem Ring verbunden
    - cc_chip_top_pg_connectivity.rpt: keine Opens auf VDD/GND
    - DRC-/Antenna-Zahl gegen den Smoke-Test (2630/159) vergleichen
    - cc_chip_top_gds.rpt: "missing: 0" (sonst fehlt eine GDS-Datei)
  Danach Schritte 5-8 (Quantus, Tempus, GLS, LEC) auf dem neuen Layout.
  Offen dabei: Scan-Ketten-Umordnung mit cc_chip_top_syn.scandef (DFT-01),
  Post-Route-Optimierung.

Schritt 4: Gate-Level-Simulation (Abschnitt 3b, 04_DocuGateSim)

      ./scripts/gatesim/gatesim.sh -b --rtl instr06addi   (Referenz, RTL)
      ./scripts/gatesim/gatesim.sh -b instr06addi         (Netzliste)
      ./scripts/gatesim/gatesim.sh -b scan                (Scan-Kette)
      ./scripts/gatesim/gatesim.sh -b instr99bscan        (Boundary Scan)
      ./scripts/gatesim/gatesim.sh -r                     (alle, ~62 Tests)
      ./scripts/gatesim/gatesim.sh -r -s                  (alle, mit SDF)

Schritt 5: RC-Extraktion (Quantus, Abschnitt 3c, 05_DokuSTA)
  $XFAB_PATHS: QRC_MAX/_TYP/_MIN muessen auf die qrcTechFile-Dateien
  zeigen (stehen schon drin, Genus/Innovus nutzen sie). Neu und optional:
    QRC_LAYERMAP   Paare "LEF-Layer" "QRC-Layer", nur falls die Layer-
                   namen im Technologie-LEF und im qrcTechFile verschieden
                   sind (Quantus meldet dann unbekannte Layer); sonst leer
  Innovus vor dem 27.11.2026 gelaufen: Netzliste und DEF fehlen noch, das
  Skript schreibt sie selbst aus cc_chip_top_routed.db (kein neuer P&R-Lauf).

      ./scripts/quantus/quantus_rcx.sh            (Quantus standalone)
      ./scripts/quantus/quantus_rcx.sh -i         (Alternative: Quantus-
                                                   Engine in Innovus)
  Pruefen: drei SPEF-Dateien cc_chip_top_rc_{max,typ,min}.spef, Netzzahl
  plausibel (alle drei gleich), keine ERROR im Log. Schlaegt der
  Standalone-Lauf fehl (CCL-Syntax, Layer-Mapping -- VERIFY-LAB), mit -i
  weitermachen und den Fehler notieren.

Schritt 6: Sign-off-STA (Tempus)

      ./scripts/sta/sta.sh -b       (batch: Worst Slack pro View)
      ./scripts/sta/sta.sh          (Tempus-Shell bleibt offen)
  Pruefen: build_sta/sta_check_timing.rpt (keine unbeschraenkten
  Endpunkte ausser den bekannten: Reset, asynchrone Pins), Hold in allen
  Views >= 0 (Pflicht, vor allem av_scan_fast = Scan-Shift), Setup in
  av_slow/av_jtag_slow >= 0. Setup in av_scan_slow < 0 begrenzt nur den
  TCK im SCANTEST (Capture langsamer takten), kein Fehler am Chip.
  sta_violators.rpt: max_transition/max_capacitance (DRV) ansehen.

Schritt 7: Post-Route-Gate-Level-Simulation mit Tempus-SDF

      ./scripts/gatesim/gatesim.sh -r -p -s       (Slow-Corner, Setup)
      ./scripts/gatesim/gatesim.sh -r -p -s -m    (Fast-Corner, Hold)

Schritt 8: Formale Aequivalenz (Conformal LEC, Abschnitt 3d, 06_DokuLEC)
  Keine neuen $XFAB_PATHS-Eintraege. Genus liest die RTL-Dateiliste und
  die Defines jetzt aus rv64_rtl_setup.tcl (gleicher Inhalt wie vorher in
  00_rv64_elab.tcl) -- beim naechsten Genus-Lauf pruefen, dass er wie
  bisher durchlaeuft.

      ./scripts/lec/lec.sh                  (rtl2syn, dann syn2pnr)
      ./scripts/lec/lec.sh -m rtl2syn -g    (Gegenprobe: Genus-Dofile)
      ./scripts/lec/lec.sh -m rtl2syn -i    (GUI zum Debuggen)
  Pruefen: 0 non-equivalent, 0 abort; build_lec/lec_<mode>_design.rpt
  (keine unerwarteten Black Boxes ausser den SPRAM-Makros),
  _unmapped.rpt (not-mapped ansehen). Alle Scan-FFs non-equivalent ->
  Constraint auf core/as_jtag/sc01_shift_o greift nicht (Pin-Name).

Schritt 9: DRC, LVS, ERC (Abschnitt 3e, 07_DokuPV)
  Braucht den Innovus-Lauf bis zur Stufe gds (Schritt 3).

      ./scripts/pv/pv.sh -m drc        (erst DRC, Decks aus DRC_RULES)
      ./scripts/pv/pv.sh -m lvs        (LVS mit ERC)
      ./scripts/pv/pv.sh -t calibre    (falls nur Calibre-Decks)
  Pruefen: build_pv/drc_<n>.summary (Zahl pro Regel), lvs.report
  (CORRECT), erc.summary. Erster Lauf: viele DRC-Ergebnisse sind
  normal (Metal-Fill und Antenna-Fixing fehlen noch). Beim LVS zuerst
  Ports/Supplies: fehlen die Pad-Labels oder liegen sie auf dem falschen
  Layer (cc_chip_top_labels.txt, LABEL_LAYER)?

Mit Claude im Labor
  Claude kann die Schritte ausfuehren und die Logs/Reports auswerten. Dazu
  Claude auf diesen Abschnitt hinweisen ("README_XFAB.txt, Abschnitt 1a").
  Regeln (X-FAB-NDA): Claude liest PDK-, Liberty- und LEF-Dateien nur am
  Ort, kopiert nichts davon ins Repository und traegt X-FAB-Zell-, Pin-
  und Dateinamen ausschliesslich in die lokale $XFAB_PATHS-Datei ein;
  Auszuege hoechstens in ein temporaeres Verzeichnis ausserhalb des
  Repositorys. Vor einem Commit "git status" pruefen: build_genus/,
  build_innovus/, build_quantus/, build_sta/, build_lec/, build_pv/,
  build_gatesim/ und build_xcelium/ sind gesperrt (.gitignore), Netzliste, SPEF und SDF
  enthalten X-FAB-Zellnamen.


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

RV_NoPipeline (aus RWU_RV/RV_NoPipeline):

    ./scripts/xcelium/xrun_single.sh instr06addi        (mit SimVision-GUI)
    ./scripts/xcelium/xrun_single.sh -b instr06addi     (batch)
    ./scripts/xcelium/xrun_single.sh -l                 (Testliste)
    ./scripts/xcelium/xrun_regression.sh                (alle Tests, batch)

  - RTL-Dateiliste und Testtabelle kommen aus sim/CMakeLists.txt, die
    Skripte muessen bei neuen Dateien/Tests nicht angepasst werden.
  - Ergebnisse in build_xcelium/<test>/, Zusammenfassung in
    build_xcelium/regression.txt.
  - Der RWU-Lizenzserver hat nur 2 Xcelium-Lizenzen fuer ALLE Nutzer;
    -licqueue wartet auf eine freie Lizenz. Eine offene SimVision-GUI
    haelt ihre Lizenz, bis sie geschlossen wird.
  - Ausfuehrliche Anleitung: 01_DokuXCELIUM/DokuXCELIUM.pdf


--------------------------------------------------------------------------------
3. Synthese (Genus)
--------------------------------------------------------------------------------

Genus starten und Skript laden:

    genus -> source ./scripts/source.tcl

Alternativ direkt mit GUI:

    genus -files ./scripts/source.tcl -execute "gui_show"

RV_NoPipeline (Run-Verzeichnis z. B. RWU_RV/RV_NoPipeline/syn/genus,
$XFAB_PATHS gesetzt, beide Skripte im selben Verzeichnis):

    genus -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/00_rv64_elab.tcl
    genus -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/01b_rv64_syn.tcl

  00_rv64_elab.tcl  MMMC (xh018_mmmc.tcl: slow/typ/fast), LEF, RTL lesen
                    (Dateiliste + Defines: rv64_rtl_setup.tcl, auch fuer LEC),
                    cc_chip_top elaborieren -> cc_chip_top_elab.db
                    Defines XFAB_SPRAM / XFAB_PADS waehlen die echten
                    SPRAM-Makros und IO_CELLS_3V-Zellen statt der
                    Verhaltensmodelle; alle Zellnamen kommen aus $XFAB_PATHS.
  01b_rv64_syn.tcl  syn_generic/map/opt, Reports pro View (av_slow, av_typ,
                    av_jtag_slow), Netzliste cc_chip_top_syn.v, SDC (func
                    und jtag_load), SDF, innovus/cc_chip_top.db
                    (write_db -common, Uebergabe an Innovus)

  Einfacher (aus RWU_RV/RV_NoPipeline, Ergebnisse in build_genus/):

    ./scripts/genus/genus_syn.sh          (Synthese, danach Genus-GUI)
    ./scripts/genus/genus_syn.sh -e       (GUI mit elaboriertem Design)
    ./scripts/genus/genus_syn.sh -b       (batch, mit Zusammenfassung)

  Ausfuehrliche Anleitung: 02_DokuGENUS/DokuGENUS.pdf

  Constraints: as_top_mem.sdc, as_top_mem_func.sdc, as_top_mem_jtag.sdc
  (clk_i 100 MHz, clk_core = clk_i/80 aus der CGU, tck_i asynchron).

  Uebergabe an Innovus mit write_db -common (write_design -innovus ist
  veraltet). Genus 26.1 loest Hierarchien wie core/cgu auf und benennt
  dabei Pins um, auf die die SDC verweist -> 01b_rv64_syn.tcl setzt
  ungroup_ok false fuer core, core/cgu, core/cgu/CGUCore, core/as_jtag.


--------------------------------------------------------------------------------
3a. Place & Route (Innovus)
--------------------------------------------------------------------------------

Im selben Run-Verzeichnis wie Genus:

    innovus -batch -files <asgithub>/RWU_RV/RV_NoPipeline/scripts/02_rv64_floorplan_pnr.tcl

  Einfacher (aus RWU_RV/RV_NoPipeline, Ergebnisse in build_innovus/):

    ./scripts/innovus/innovus_pnr.sh            (ganzer Flow in der GUI)
    ./scripts/innovus/innovus_pnr.sh -s place   (Stopp nach fp/place/cts/route)
    ./scripts/innovus/innovus_pnr.sh -o route   (Checkpoint nur ansehen)
    ./scripts/innovus/innovus_pnr.sh -b         (batch, mit DRC/Antenna)

  Ausfuehrliche Anleitung: 03_DokuINNOVUS/DokuINNOVUS.pdf

  Ablauf: read_db innovus/cc_chip_top.db -> Floorplan (Die 2600x2600 um,
  Core 2016x2016 um, 35 um Rand fuer den Power-Ring, IO-Ring 257 um) ->
  Pad-Ring (26 Pads, Eckzellen, IO-Filler) -> SPRAM-Makros fest platziert
  -> Power-Grid (02a_rv64_power.tcl: Global Connect, Core-Ring, Stripes,
  route_special) -> place_design -> ccopt_design -> routeDesign ->
  Core-Filler -> Netzlisten/DEF (02b) -> GDS mit Merge (02c).
  Checkpoints: cc_chip_top_fp.db, _placed.db, _cts.db, _routed.db
  Uebergabe: _routed.v, _routed.def, _lvs.v (mit Supply-Ports und
  Physical-only-Zellen), cc_chip_top.gds

  Erster Durchlauf (24.11.2026, reiner Smoke-Test, damals noch mit
  Innovus 23.33 -- mit Release 2026/27 zu wiederholen): 0 Connectivity-
  Violations, Setup erfuellt, Routing ohne Fails; ca. 2630 DRC- und
  159 Antenna-Violations -- erwartet, da Pad-Zuordnung (TECH-06) und
  Power-Ring/-Stripes noch fehlen.


--------------------------------------------------------------------------------
3b. Gate-Level-Simulation (Xcelium)
--------------------------------------------------------------------------------

Aus RWU_RV/RV_NoPipeline, nach der Synthese (build_genus/), Ergebnisse in
build_gatesim/<test>/:

    ./scripts/gatesim/gatesim.sh instr06addi         (Netzliste, SimVision-GUI)
    ./scripts/gatesim/gatesim.sh -b instr06addi      (batch)
    ./scripts/gatesim/gatesim.sh -b -s instr06addi   (mit SDF, Slow-Corner)
    ./scripts/gatesim/gatesim.sh -b --rtl scan       (Referenz auf RTL)
    ./scripts/gatesim/gatesim.sh -r [-s]             (alle Tests, batch)
    ./scripts/gatesim/gatesim.sh -l                  (Testliste)

  - DUT ist cc_chip_top: Netzliste cc_chip_top_syn.v + Verilog-Modelle der
    X-FAB-Zellen (VLOG_MODELS aus $XFAB_PATHS). --rtl nimmt stattdessen das
    RTL mit Verhaltens-Pads (gleiche Testbench, Referenz ohne X-FAB-Daten).
  - Testbench tb/gls/tb_gls_chip.sv: nur Pins, keine hierarchischen
    Zugriffe ins DUT; laedt das Programm ueber JTAG (I_MEM), weil das
    SPRAM-Modell kein $readmemh hat -- wie spaeter auf dem Chip.
  - Tests: die 60 Instruktionstests, instr99bscan (SAMPLE/PRELOAD, EXTEST
    an den Pins), scan (Muster durch die Scan-Kette, Laenge aus
    build_genus/cc_chip_top_scan_chains.rpt oder -L <n>).
  - Ohne -s: funktional (-nospecify), mit -s: SDF aus Genus (vor dem
    Layout, Slow-Corner) und Timing-Checks. Bei Races an den Taktzellen
    ohne SDF: -u (Unit Delay).
  - Ausfuehrliche Anleitung: 04_DocuGateSim/DocuGateSim.pdf


--------------------------------------------------------------------------------
3c. Sign-off-Timing: RC-Extraktion (Quantus) und STA (Tempus)
--------------------------------------------------------------------------------

Aus RWU_RV/RV_NoPipeline, nach Place & Route (build_innovus/):

    ./scripts/quantus/quantus_rcx.sh [-i]    -> build_quantus/*.spef
    ./scripts/sta/sta.sh [-b] [--no-si]      -> build_sta/sta_*.rpt, *.sdf
    ./scripts/gatesim/gatesim.sh -r -p -s [-m]   (Post-Route-GLS)

  Ausfuehrliche Anleitung: 05_DokuSTA/DokuSTA.pdf

  - Reihenfolge: erst Extraktion, dann STA. Tempus rechnet die Leitungs-
    verzoegerungen nicht selbst, es liest die RC-Werte aus der SPEF.
  - Innovus schreibt am Ende cc_chip_top_routed.v (Netzliste mit Clock-
    Tree, ohne Filler) und cc_chip_top_routed.def (02b_rv64_export.tcl).
  - Quantus: 03a_rv64_quantus.tcl erzeugt im Build-Verzeichnis die CCL-
    Datei, lib.defs und qrc/rc_{max,typ,min}/ (Links auf die X-FAB-
    qrcTechFiles); die Corner heissen damit wie die RC-Corner in
    xh018_mmmc.tcl. -i: 03a_rv64_rcx_innovus.tcl, Quantus-Engine in
    Innovus (effort signoff), gleiche SPEF-Namen.
  - Tempus: 03b_rv64_sta.tcl mit xh018_mmmc_sta.tcl = xh018_mmmc.tcl plus
    Constraint-Modus scan (as_top_mem_scan.sdc, nur fuer die STA, Genus
    optimiert nicht darauf). OCV + CPPR, SI (Crosstalk) an.
    Setup: av_slow av_typ av_jtag_slow av_scan_slow
    Hold:  av_fast av_jtag_fast av_scan_fast
  - SDF fuer die GLS: cc_chip_top_sta_func.sdf und _sta_scan.sdf
    (min = Fast-, max = Slow-Corner).
  - Noch nie mit echtem Quantus/Tempus gelaufen: VERIFY-LAB-Punkte in den
    Skripten und in 05_DokuSTA.


--------------------------------------------------------------------------------
3d. Formale Aequivalenz (Conformal LEC)
--------------------------------------------------------------------------------

Aus RWU_RV/RV_NoPipeline, nach Synthese (und fuer syn2pnr nach P&R):

    ./scripts/lec/lec.sh [-m rtl2syn|syn2pnr|all] [-g] [-i]
                                        -> build_lec/lec_<mode>*.rpt

  Ausfuehrliche Anleitung: 06_DokuLEC/DokuLEC.pdf

  - rtl2syn: RTL (golden) gegen build_genus/cc_chip_top_syn.v
    syn2pnr: Genus-Netzliste gegen build_innovus/cc_chip_top_routed.v
  - 04_rv64_lec.tcl (Conformal Tcl-Modus) liest das RTL mit derselben
    Dateiliste und denselben Defines wie Genus (rv64_rtl_setup.tcl).
  - DFT: Scan-Enable core/as_jtag/sc01_shift_o geschnitten und auf 0
    gehalten, Kettenende core/as_jtag/sc01_tdo_i in beiden Designs
    geschnitten -> verglichen wird der Funktionsmodus, vollstaendig.
  - SPRAM-Makros: Black Boxes (Liberty ohne Funktion), Pins verglichen.
  - -g: Dofile, das Genus mit write_do_lec schreibt (01b_rv64_syn.tcl;
    fehlt es, erzeugt lec.sh es aus cc_chip_top_syn.db).
  - Noch nie mit echtem Conformal gelaufen: VERIFY-LAB in 06_DokuLEC.


--------------------------------------------------------------------------------
3e. Physikalische Verifikation: DRC, LVS, ERC (Pegasus oder Calibre)
--------------------------------------------------------------------------------

Aus RWU_RV/RV_NoPipeline, nach Innovus bis zur Stufe gds:

    ./scripts/pv/pv.sh [-m drc|lvs|all] [-t pegasus|calibre] [-j N]
                                        -> build_pv/

  Ausfuehrliche Anleitung: 07_DokuPV/DokuPV.pdf

  - Eingaben: build_innovus/cc_chip_top.gds (gemergt, mit Pad-Labels
    fuer Ports und Supplies), cc_chip_top_lvs.v (mit Supply-Ports und
    Physical-only-Zellen), CDL der Zellen (CDL_FILES).
  - 05_rv64_pv.tcl schreibt Steuerdateien (drc_<n>.ctl, lvs.ctl): Ein-
    gaben, Reports, #DEFINE-Schalter, dann include des X-FAB-Decks. Die
    Decks selbst werden nie veraendert.
  - Pegasus liest die Verilog-Netzliste direkt; fuer Calibre wandelt
    v2lvs sie vorher in SPICE (cc_chip_top_lvs.sp).
  - Noch nie gelaufen: VERIFY-LAB in 07_DokuPV.


--------------------------------------------------------------------------------
4. X-FAB spezifische Punkte
--------------------------------------------------------------------------------

4.1 Prozess-Auswahl
    "Look for best technology" auf dem X-FAB-Portal nutzen, um den passenden
    Prozess fuer das Design zu finden.

4.2 EDA-Files / Design Kit
    1. XENV: Design Kit Packages -> Environment -> xenv-cadence
    2. PDK-Kernel:
       - (urspruenglich xh035-D_CELLS-liberty_MOS; Variante A ist inzwischen
         auf XH018 umgestellt)
       - XH018: D_CELLS_HD (Standardzellen), IO_CELLS_3V (Pads),
         SPRAM-Makros fuer I-Mem und D-Mem -- jeweils .lib, LEF,
         capTbl/QRC fuer die RC-Corner
       - Prozessvariante: 4 Metall-Lagen, Modul LPMOS (muss zu den
         SPRAM-Makros passen)
       - Corner: slow 1,62 V/125 C (Setup), typ 1,80 V/25 C,
         fast 1,98 V/-40 C (Hold)
    3. NDA: X-FAB-PDK und Memory-Compiler-Dateien niemals ins Repository
       (in .gitignore gesperrt); Pfade nur in der lokalen $XFAB_PATHS-Datei.

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

  Das Funktionsmodell hat einen konkreten Modulnamen und Pinout (Name
  haengt vom generierten Makro ab und steht wegen NDA nur in $XFAB_PATHS).
  Konkret heisst das (umgesetzt mit TECH-01, 20.11.2026):

  1. ip_dmem/src/asDMemCore.sv (D-Mem 1024x64, Bit-Write-Mask) und
     RWU_RV/RV_NoPipeline/src/asIMem.sv (I-Mem 8192x32) instanziieren
     mit `define XFAB_SPRAM das SRAM-Makro, ohne Define das bisherige
     Verhaltensmodell (xsim/FPGA). Der Makroname kommt per Define
     (XFAB_IMEM_MACRO / XFAB_DMEM_MACRO) aus 00_rv64_elab.tcl.
  2. Da X-FAB-SRAMs synchron lesen UND schreiben (Adresse Takt N -> Daten
     Takt N+1), muss das an der Schnittstelle zur CPU abgefangen werden --
     deckt sich mit dem, was schon im Read.me steht ("jeder Cache-Hit
     kostet effektiv 1 Takt").
  3. Fuer 01a_rv64_sim.tcl: das Verilog-Funktionsmodell kommt zusaetzlich
     in die RTL_FILES-Liste (als Ersatz fuer die bisherige
     Verhaltensbeschreibung).
  4. Fuer Genus: die .lib kommt ueber xh018_mmmc.tcl dazu, das
     Makro wird beim Lesen als Black Box behandelt (Genus erkennt das
     automatisch, wenn kein RTL fuer das Modul gelesen wird, sondern nur
     die Liberty).
  5. Fuer Physical Design (spaeter): das LEF muss zusaetzlich eingebunden
     werden -- VOR dem Floorplanning, sonst kennt Innovus die Flaeche
     nicht. (Erledigt: LEF_FILES in 00_rv64_elab.tcl, gelangt ueber
     write_db -common nach Innovus.)

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


--------------------------------------------------------------------------------
10. Stand RV_NoPipeline / Variante A (27.11.2026)
--------------------------------------------------------------------------------

Erledigt:
  TECH-01  SPRAM-Wrapper fuer I-Mem und D-Mem (XH018)
  TECH-02  Genus-Skripte auf XH018 (D_CELLS_HD, IO_CELLS_3V, MMMC, SDC)
  TECH-04  Pad-Ring in cc_chip_top (GPIO- und TDO-Tristate in den Pads)
  TECH-05  Constraint-Modi func und jtag_load
  CLK-02   CGU-Registerinterface auf clk_div_s
  Synthese auf chip-design01 gelaufen (Zellflaeche ca. 3,04 mm^2),
  Innovus-Smoke-Test bis routeDesign gelaufen
  CLK-03   CGU-Takte direkt aus Flipflops
  DFT-01   Scan-Insertion in Genus ueber JTAG SCANTEST (RTL + Skript,
           Genus-Lauf im Labor offen, Abschnitt 1a)
  DFT-02   Boundary Scan cc_bscan (29 Zellen) + BSDL (RTL)
  JTAG     TDO-Enable einen Takt zu spaet (erstes Bit jedes Scans am Pin
           verloren) -- korrigiert 27.11.2026, gefunden mit der Pin-
           Testbench der Gate-Level-Simulation
  Gate-Level-Simulation (scripts/gatesim, 04_DocuGateSim), im Labor mit
  der Netzliste gelaufen
  Sign-off-Timing vorbereitet: Quantus + Tempus (scripts/quantus,
  scripts/sta, 05_DokuSTA), Constraint-Modus scan; im Labor offen
  Formale Aequivalenz vorbereitet: Conformal LEC (scripts/lec,
  06_DokuLEC), RTL->Genus und Genus->Innovus; im Labor offen
  Power-Grid, Core-Filler, GDS-Merge mit Pad-Labels (Innovus) und
  DRC/LVS/ERC (scripts/pv, Pegasus oder Calibre, 07_DokuPV) vorbereitet;
  im Labor offen

Offen:
  TECH-03  I-Mem-Groesse festlegen (32 KiB oder 16 KiB; 16 KiB spart
           ca. 0,8 mm^2)
  TECH-06  Supply-Pads (Rolle, Anzahl, Platzierung, ESD, SSO) und
           IO-Zuordnung gegen das IO_CELLS_3V-Databook pruefen
  Power-Grid/Filler/GDS im Labor laufen lassen (Abschnitt 1a, Schritt 3),
  DRC/Antenna bereinigen, Post-Route-Optimierung, Scan-Reorder in Innovus,
  ATPG, SRAM-BIST, STA-Lauf (Abschnitt 1a, Schritte 5-7),
  LEC-Lauf (Schritt 8), DRC/LVS/ERC-Lauf (Schritt 9), Metal-Fill

AS:
RTL Simulation ist gemacht (xrun), Synthese mit scanpath insertion ist gemacht (genus), place&route ist genacht (innovus), gatelevel simulation ist gemacht (xrun).
ihenfolge und Tools

┌───────────────────┬────────────────────────────────┬─────────────────────────────────────────┬─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│      Schritt      │          Cadence-Tool          │                 Eingabe                 │                                                  Zweck                                                  │
├───────────────────┼────────────────────────────────┼─────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. RC-Extraktion  │ Quantus                        │ DEF aus Innovus und die                 │ Erzeugt die SPEF mit den echten Leitungs-RCs.                                                           │
│                   │                                │ Technologiedatei aus dem PDK            │                                                                                                         │
├───────────────────┼────────────────────────────────┼─────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 2. STA            │ Tempus                         │ Netzliste, SPEF, Liberty aller Corner   │ Signoff für Setup und Hold. Laufen müssen der Funktionsmodus und der Scanmodus (SCANTEST, TCK) sowie    │
│                   │                                │ (ss/tt/ff) und die SDC                  │ der JTAG-Takt. Danach gibt Tempus die Signoff-SDF für die Gate-Level-Simulation aus.                    │
├───────────────────┼────────────────────────────────┼─────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 3. Formale        │ Conformal LEC                  │ RTL, die Genus-Netzliste und die        │ Siehe unten.                                                                                            │
│ Äquivalenz        │                                │ Innovus-Netzliste                       │                                                                                                         │
├───────────────────┼────────────────────────────────┼─────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 4. GDS-Merge      │ Innovus streamOut oder         │ Die GDS der Standardzellen, der         │ Fügt alles zum Chip-GDS zusammen.                                                                       │
│                   │ Virtuoso                       │ IO-Zellen und der SPRAM-Makros          │                                                                                                         │
├───────────────────┼────────────────────────────────┼─────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 5. DRC, LVS, ERC  │ Pegasus, alternativ Calibre    │ Die Regeldateien (Runsets) aus dem      │ Das ERC steckt meist mit im LVS-Runset. Für das LVS braucht man eine Netzliste mit Power-Pins und       │
│                   │ (Siemens) oder Assura          │ X-FAB-PDK                               │ physischen Zellen (Innovus saveNetlist mit Power-Pins und Physical Cells).                              │
├───────────────────┼────────────────────────────────┼─────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ optional          │ Voltus                         │                                         │ IR-Drop, Elektromigration, Leistung                                                                     │
└───────────────────┴────────────────────────────────┴─────────────────────────────────────────┴─────────────────────────────────────────────────────────────────────────────────────────────────────────┘

Welches Tool du für DRC und LVS nimmst, entscheidet das PDK, nicht die Cadence-Lizenz. X-FAB liefert die Regeldateien nicht für jedes Tool. Prüf im Labor zuerst, welche Runsets im PDK-Verzeichnis liegen (Pegasus, PVS, Assura oder Calibre), und dann mit which quantus tempus lec pegasus voltus, welche Tools installiert sind. Das Europractice-Paket enthält diese Tools in der Regel. Für das LVS musst du die SPRAM-Makros als Black Box behandeln oder deren CDL vom SRAM-Compiler einbinden.

Formale Verifikation ohne Jasper

1. Äquivalenzprüfung mit Conformal LEC (Empfehlung)

Conformal LEC ist ein eigenes Cadence-Tool und hat mit Jasper nichts zu tun. Das ist die formale Prüfung, die im Signoff wirklich gebraucht wird.
- Geprüft wird RTL gegen die Genus-Netzliste und die Genus-Netzliste gegen die Innovus-Netzliste. Damit ist bewiesen, dass Synthese, Scan-Insertion, CTS und Optimierung die Funktion nicht verändert haben.
- Genus schreibt dir mit write_do_lec das passende Dofile.
- Wegen der Scan-Insertion muss im Funktionsvergleich der Scanmodus abgeschaltet sein: SCANTEST aus und das Scan-Enable auf 0 per Pin-Constraint. Sonst meldet LEC Unterschiede an den Scan-Flipflops.

2. Eigenschaftsprüfung (Model Checking) mit Open Source

Das ersetzt Jasper für Ausbildungszwecke recht gut:
- SymbiYosys (Yosys mit SMT-Solvern wie Boolector oder Yices) prüft SVA-Properties (assert, assume, cover) per Bounded Model Checking oder vollständigem Beweis. Für SystemVerilog brauchst du das Plugin yosys-slang oder vorher sv2v, weil der eingebaute Yosys-Parser nur einen Teil von SV versteht.
- Gut geeignet sind kleine Blöcke: das TAP-FSM gegen IEEE 1149.1, der Speicher-Arbiter (keine zwei Grants gleichzeitig), FIFO, UART und CGU.
- riscv-formal (YosysHQ) prüft den ganzen RV64I-Kern formal gegen die ISA. Dafür muss der Kern die RVFI-Schnittstelle bekommen, einen Trace-Port nur für die Verifikation. Das ist mehr Aufwand, aber für einen eigenen RISC-V-Kern der eigentliche Gewinn. Gerade die Pipeline-Variante B mit Forwarding und Hazards hat genau die Fehler, die Simulation leicht übersieht.

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
