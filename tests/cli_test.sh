#!/usr/bin/env bash
# End-to-end tests of the spicy binary from the command line: config check,
# netlists for every simulator dialect, and real ngspice and Xyce runs (skipped
# when the simulator is not installed). Uses a throw-away config folder.
#
#   tests/cli_test.sh [path/to/spicy]
set -u
bin=${1:-./spicy}
case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)

work=$(mktemp -d)
# Git Bash on Windows: use the folder's Windows name (C:/...), which both bash and the
# Windows binary understand, so no path has to be converted between the two
if command -v cygpath >/dev/null 2>&1; then work=$(cygpath -m "$work"); fi
trap 'rm -rf "$work"' EXIT
export SPICY_CONFIG_DIR="$work/cfg"
cp "$root"/examples/*.edn "$work/"

fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { # name, command…, then the text the output must contain (last argument)
	local name=$1; shift
	local want=${!#}
	local out
	out=$("${@:1:$#-1}" 2>&1)
	if grep -qF -- "$want" <<<"$out"; then pass "$name"; else
		fail "$name (wanted \"$want\")"
		sed 's/^/     /' <<<"$out" | head -20
	fi
}

check "version"              "$bin" --version "spicy"
check "config check"         "$bin" --check-config "no problems"
check "ngspice netlist"      "$bin" --netlist "$work/rc_lowpass.edn" "R1 out N001 1k"
check "ngspice model card"   "$bin" --netlist "$work/rc_lowpass.edn" ".model 1N4148 D"
check "xyce netlist"         "$bin" --netlist "$work/rc_lowpass.edn" --sim xyce ".tran"
# the netlist shown and exported is the one that runs: its .print line, for the device currents
check "xyce netlist .print"  "$bin" --netlist "$work/rc_lowpass.edn" --sim xyce ".print tran format=raw V(*) I(*)"
check "vacask netlist"       "$bin" --netlist "$work/rc_lowpass.edn" --sim vacask "analysis tran1 tran"
check "vacask diode name"    "$bin" --netlist "$work/rc_lowpass.edn" --sim vacask "m_1n4148"
check "opamp subcircuit"     "$bin" --netlist "$work/opamp_inverting.edn" ".subckt spicy_opamp"
check "switch netlist"       "$bin" --netlist "$work/switch.edn" "S1 out 0 ctl 0 SW"
check "xyce switch model"    "$bin" --netlist "$work/switch.edn" --sim xyce "VSWITCH(RON=1 ROFF=1Meg VON="
check "xyce switch steps"    "$bin" --netlist "$work/switch.edn" --sim xyce ".options timeint erroption=1"
check "transformer netlist" "$bin" --netlist "$work/transformer.edn" "KT1 LT1_P LT1_S 0.999"
check "vacask transformer"  "$bin" --netlist "$work/transformer.edn" --sim vacask "kt1 () mutual k=0.999 ind1=\"lt1_p\" ind2=\"lt1_s\""
check "vacask switch"        "$bin" --netlist "$work/switch.edn" --sim vacask "embed \"spicy_vsw.va\""
# LTspice's SINE(… Ncycles): VACASK's sine, the same while the .tran ends when its cycles do
# (1 cycle of 100 kHz is 10 us; the .tran runs 20 us)
sed 's/:value "PULSE(0 1 0 1n 1n 5u 10u) AC 1"/:value "SINE(0 1 100k 0 0 0 1)"/' "$work/rc_lowpass.edn" >"$work/sine.edn"
# a stop time from a .param: a step for SPICE; for VACASK also a control block variable (its
# analyses do not see the circuit's parameters)
sed 's/:text ".tran 20u"/:text ".tran {ts}\\n.param ts=20u"/' "$work/rc_lowpass.edn" >"$work/tsp.edn"
check "tran stop from a param" "$bin" --netlist "$work/tsp.edn" ".tran {(ts)/1000} {ts}"
check "vacask tran from a param" "$bin" --netlist "$work/tsp.edn" --sim vacask "analysis tran1 tran step=(ts)/1000 stop=ts"
check "vacask param as var"  "$bin" --netlist "$work/tsp.edn" --sim vacask "  var ts=20u"
check "vacask SINE"          "$bin" --netlist "$work/sine.edn" --sim vacask 'type="sine" sinedc=0 ampl=1 freq=100000 delay=0 theta=0 tdphase=0'
check "vacask SINE cycles"   "$bin" --netlist "$work/sine.edn" --sim vacask "does not stop after Ncycles=1 (at 1e-05 s)"
sed 's/100k 0 0 0 1)/100k 0 0 0 2)/' "$work/sine.edn" >"$work/sine2.edn"
if "$bin" --netlist "$work/sine2.edn" --sim vacask 2>&1 | grep -q "does not stop"; then fail "vacask SINE cycles to the end"; else pass "vacask SINE cycles to the end"; fi

# LTspice import
cat >"$work/imp.asc" <<'EOF'
Version 4
SHEET 1 880 680
WIRE 128 96 32 96
WIRE 32 160 32 96
FLAG 32 240 0
FLAG 128 96 out
SYMBOL voltage 32 144 R0
SYMATTR InstName V1
SYMATTR Value 5
SYMBOL res 112 80 R0
SYMATTR InstName R1
SYMATTR Value 10k
TEXT 0 300 Left 2 !.op
EOF
check "asc import"           "$bin" --import-asc "$work/imp.asc" "$work/imp.edn" ""
check "asc import result"    cat "$work/imp.edn" ":symbol \"res\""

# a simulator's program set like Simulate › Simulators… does: only that path changes
mkdir -p "$work/pcfg"
# Git Bash would turn /opt/... into C:/Program Files/Git/opt/... for the Windows binary
noconv=(MSYS_NO_PATHCONV=1 "MSYS2_ARG_CONV_EXCL=*")
echo '{:schematic {:grid-style :lines}} ; mine' >"$work/pcfg/settings.edn"
check "set program"          env "${noconv[@]}" SPICY_CONFIG_DIR="$work/pcfg" "$bin" --set-program vacask /opt/x/vacask "vacask runs /opt/x/vacask"
check "set program kept"     cat "$work/pcfg/settings.edn" "; mine"
check "set program config"   env SPICY_CONFIG_DIR="$work/pcfg" "$bin" --check-config "no problems"
env "${noconv[@]}" SPICY_CONFIG_DIR="$work/pcfg" "$bin" --set-program vacask /opt/y/vacask >/dev/null
check "set program again"    cat "$work/pcfg/settings.edn" '["/opt/y/vacask" "-qp" "{netlist}"]'
mkdir -p "$work/bcfg"
echo '{:ui {:layout :waves-sideways}}' >"$work/bcfg/settings.edn"
check "config bad keyword"   env SPICY_CONFIG_DIR="$work/bcfg" "$bin" --check-config ":ui :layout :waves-sideways is not one of :waves-top"

# SPICE netlist opened as a schematic
cat >"$work/buck.cir" <<'EOF'
* buck
V1 in 0 12
S1 in sw g 0 SWM
Vg g 0 PULSE(0 1 0 1n 1n 2.2u 5u)
D1 0 sw DM
L1 sw out 18u ic=0
C1 out 0 150u ic=0
R1 out 0 8.33
.model SWM SW(Ron=0.01 Roff=1e6 Vt=0.5 Vh=0)
.model DM D(Is=1e-9 Rs=0.01)
.tran 25n 200u 0 25n uic
.end
EOF
check "netlist as schematic" "$bin" --netlist "$work/buck.cir" "S1 in sw g 0 SWM"
check "netlist directives"   "$bin" --netlist "$work/buck.cir" ".model DM D(Is=1e-9 Rs=0.01)"
check "netlist not a model"  "$bin" --import-model "$work/buck.cir" "is a circuit"
# VACASK's devices have no ic=: capacitor ICs go into the transient analysis instead
if "$bin" --netlist "$work/buck.cir" --sim vacask 2>&1 | grep -v "^ *analysis" | grep -q "ic="; then fail "vacask device ic= dropped"; else pass "vacask device ic= dropped"; fi
check "vacask cap ic on tran" "$bin" --netlist "$work/buck.cir" --sim vacask 'icmode="uic" ic={"c1_a", 0}'
check "vacask switch option" "$bin" --netlist "$work/buck.cir" --sim vacask "nr_residualcheck=0"
check "vacask switching defaults" "$bin" --netlist "$work/buck.cir" --sim vacask 'tran_method="gear" tran_itl=50 tran_redofactor=10'
sed 's/^\.end$/.options method=trap itl4=80 savecurrents\n.end/' "$work/buck.cir" >"$work/buck_opts.cir"
check "vacask .options translated" "$bin" --netlist "$work/buck_opts.cir" --sim vacask 'tran_method="trap" tran_itl=80'
check "vacask .options unknown"    "$bin" --netlist "$work/buck_opts.cir" --sim vacask "no option like savecurrents"

# SPICE models: a subcircuit imported (symbol made) and used by a part, and a .model directive
cat >"$work/fet.lib" <<'EOF'
* test MOSFET
.SUBCKT TFET 10 20 30
* TERMINALS : D G S
M1 1 20 3 3 NM L=1u W=10u
RD 10 1 0.01
RS 30 3 0.01
DSD 3 10 DB
.MODEL NM NMOS(LEVEL=1 VTO=1 KP=50u)
.MODEL DB D(IS=1n)
.ENDS
EOF
cat >"$work/fet.edn" <<'EOF'
{:spicy-schematic 1
 :components [{:symbol "voltage" :ref "V1" :value "5" :at [0 0]}
              {:symbol "res" :ref "R1" :value "1k" :at [400 0]}
              {:symbol "TFET" :ref "M1" :value "TFET" :at [352 96]}
              {:symbol "res" :ref "R2" :value "1k" :at [600 0]}
              {:symbol "diode" :ref "D1" :value "MYD" :at [600 96]}]
 :flags [{:name "in" :at [0 16]} {:name "0" :at [0 96]} {:name "in" :at [416 16]} {:name "dd" :at [416 96]}
         {:name "dd" :at [400 96]} {:name "in" :at [352 176]} {:name "0" :at [400 192]}
         {:name "in" :at [616 16]} {:name "a" :at [616 96]} {:name "0" :at [616 160]}]
 :texts [{:at [0 320] :text ".op" :directive true} {:at [0 352] :text ".model MYD D(IS=1n N=2)" :directive true}]}
EOF
# the data folder is cfg/data on Linux, the config folder itself on macOS and Windows
check "import model"         "$bin" --import-model "$work/fet.lib" "symbol   TFET"
imported="$work/cfg/data/symbols/imported.edn"
[ -f "$imported" ] || imported="$work/cfg/symbols/imported.edn"
check "imported symbol"      cat "$imported" ':like "nmos"'
check "config after import"  "$bin" --check-config "no problems"
# a MOSFET with more terminals than D G S (a thermal node): a box with all its pins, not the 3-pin symbol
cat >"$work/fet4.lib" <<'EOF'
.SUBCKT TFET4 10 20 30 40
* TERMINALS : D G S TJ
M1 10 20 30 30 NM4
R1 40 0 1
.MODEL NM4 NMOS(LEVEL=1 VTO=1 KP=50u)
.ENDS
EOF
check "import 4-pin MOSFET"  "$bin" --import-model "$work/fet4.lib" "symbol   TFET4"
check "4-pin MOSFET symbol"  cat "$imported" '{:name "tj"'
if grep -q '"TFET4" :like' "$imported"; then fail "no 3-pin symbol for 4 ports"; else pass "no 3-pin symbol for 4 ports"; fi
# vendor pin comments: "Pin order: Drain=10, Gate=50, Source=30" and "TERMINALS D G S" without a colon
cat >"$work/pinord.lib" <<'EOF'
**Pin order:  Drain=10, Gate=50, Source=30
.SUBCKT TFETPO 10 50 30
M1 10 50 30 30 NMPO
.MODEL NMPO NMOS(LEVEL=1 VTO=1 KP=50u)
.ENDS
.SUBCKT TFETNC 10 20 30
*     TERMINALS  D  G  S
M1 10 20 30 30 NMNC
.MODEL NMNC NMOS(LEVEL=1 VTO=1 KP=50u)
.ENDS
EOF
"$bin" --import-model "$work/pinord.lib" >/dev/null 2>&1
check "pin order comment"    cat "$imported" '{:name "TFETPO" :like "nmos"'
check "terminals, no colon"  cat "$imported" '{:name "TFETNC" :like "nmos"'
# transistor pins: a bare "*  C B E" comment, a Darlington with numbered ports and its model
# outside it (roles from the circuit), "*PIN_ORDER" over lines of "* 1=E1  6=C1", a dual with
# no pin comment (each port named by the transistor terminal it meets)
cat >"$work/bjts.lib" <<'EOF'
.MODEL QT1 NPN(IS=1e-14 BF=100)
.MODEL QT2 PNP(IS=1e-14 BF=100)
.SUBCKT TQBARE 1 2 3
*              C B E
Q1 1 2 3 QT1
.ENDS
.SUBCKT TQDARL 1 2 3
Q1 1 2 4 QT1
Q2 1 4 3 QT1 2
.ENDS
*PIN_ORDER
* 1=E1    6=C1
* 2=B1    5=B2
* 3=C2    4=E2
.SUBCKT TQPO 1 2 3 4 5 6
Q1 6 2 1 QT1
Q2 3 5 4 QT2
.ENDS
.SUBCKT TQDUAL 1 2 3 4 5 6
Q1 6 2 1 QT1
R1 3 7 0.01
Q2 7 5 4 QT2
.ENDS
EOF
"$bin" --import-model "$work/bjts.lib" >/dev/null 2>&1
check "bare C B E comment"   cat "$imported" '{:name "TQBARE" :like "npn"'
check "Darlington roles"     cat "$imported" '{:name "TQDARL" :like "npn"'
check "PIN_ORDER lines"      grep -A1 '{:name "TQPO"' "$imported" '{:name "e1" :at [-32 32]} {:name "b1" :at [-32 64]} {:name "c2"'
check "dual from circuit"    grep -A1 '{:name "TQDUAL"' "$imported" '{:name "e1" :at [-32 32]} {:name "b1" :at [-32 64]} {:name "c2"'
# a faulty vendor library: reported, imported only with --repair or --as-is, the file unchanged
cat >"$work/faulty.lib" <<'EOF'
*SRC=QF1;QF1;BJTs NPN; Si; 40V
.MODEL QF1 NPN (IS=1e-14 BF=100 NE 1.5 TR=1u
+ CJE=1p  +NR=1.1 TR=2n
; a comment line
+ VAF=50; old value 60
Inc. BJTs
.MODEL QF1 NPN (IS=1e-14 BF=100 NE 1.5 TR=1u
+ CJE=1p  +NR=1.1 TR=2n
; a comment line
+ VAF=50; old value 60
*SRC=QF2;QF2;BJTs PNP; Si; 40V
.MODEL QF2 NPN(IS=1e-14 BF=80)
.MODEL 5401 PNP(IS=1e-14)
.MODEL DZF D(IS=1n N=1.8 BV=100 CJO=74)
.ends
.SUBCKT XF 1 2 3
Q1 1 2 3 5401
D1 3 1 DMISSING
.MODEL QXX NPN(IS=1e-15)
EOF
cp "$work/faulty.lib" "$work/faulty.orig"
check "check-model repairs"  "$bin" --check-model "$work/faulty.lib" 'Repairs spicy can make'
out=$("$bin" --check-model "$work/faulty.lib" 2>&1)
for want in 'parameters without "="' '"+" in the middle of a line' 'parameters given twice' 'model cards with an unclosed "("' \
	'comment lines between a card' '";" comments inside model cards' 'text outside .model and .subckt' 'subcircuits with no .ENDS' \
	'.ENDS outside a subcircuit' 'model names that are numbers' 'cards given twice, unchanged' 'diodes with BV but no NBV' \
	'an NPN card; its description says PNP' 'D1 uses DMISSING' 'CJO=74'; do
	if grep -qF -- "$want" <<<"$out"; then pass "check-model: $want"; else fail "check-model: $want"; fi
done
"$bin" --check-model "$work/faulty.lib" >/dev/null 2>&1; [ $? = 1 ] && pass "check-model exit 1 on faults" || fail "check-model exit 1 on faults"
check "check-model clean"    "$bin" --check-model "$work/fet.lib" "no problems found"
"$bin" --import-model "$work/faulty.lib" >/dev/null 2>&1; [ $? = 1 ] && pass "import stops on faults" || fail "import stops on faults"
check "import says how"      "$bin" --import-model "$work/faulty.lib" "import it again with --repair"
check "import --repair"      "$bin" --import-model "$work/faulty.lib" --repair "repaired"
models_dir=$(dirname "$(dirname "$imported")")/models
check "repaired copy header" cat "$models_dir/faulty.lib" "* Repaired by spicy when imported from faulty.lib"
check "repaired: = added"    cat "$models_dir/faulty.lib" "NE=1.5"
check "repaired: last TR"    grep -c "TR=1u" "$models_dir/faulty.lib" "0"
check "repaired: renamed"    cat "$models_dir/faulty.lib" "Q1 1 2 3 M5401"
check "repaired: NBV"        cat "$models_dir/faulty.lib" "NBV=1"
check "repaired: .ENDS"      grep -A1 "^D1 3 1 DMISSING" "$models_dir/faulty.lib" ".ENDS"
if cmp -s "$work/faulty.lib" "$work/faulty.orig"; then pass "original unchanged"; else fail "original unchanged"; fi
check "import --as-is"       "$bin" --import-model "$work/faulty.lib" --as-is "copied to"
check "as-is copy unchanged" cat "$models_dir/faulty.lib" "NE 1.5"
"$bin" --import-model "$work/faulty.lib" --repair --as-is >/dev/null 2>&1; [ $? = 2 ] && pass "repair and as-is: usage" || fail "repair and as-is: usage"
# a card with blank and comment lines between its "+" lines is read whole
printf '%s\n' '.MODEL QBL NPN' '+ IS=1e-14' '' '* note' '+ BF=321' >"$work/blank.lib"
"$bin" --import-model "$work/blank.lib" --as-is >/dev/null 2>&1
printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "npn" :ref "Q1" :value "QBL" :at [0 0]}]' \
	' :texts [{:at [0 200] :text ".op" :directive true}]}' >"$work/qbl.edn"
check "card read past blank lines" "$bin" --netlist "$work/qbl.edn" "BF=321"
# a diode parameter VACASK's diode does not have (ngspice's IBVL, a vendor's typo): left out
printf '%s\n' '.MODEL DPX D(IS=1n N=1.02 BV=63 IBV=0.2m IBVL=1u NBVL=3 VCJO=3p TRS1=4m)' >"$work/dpx.lib"
"$bin" --import-model "$work/dpx.lib" --as-is >/dev/null 2>&1
printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "diode" :ref "D1" :value "DPX" :at [0 0]}]' \
	' :flags [{:name "a" :at [16 0]} {:name "0" :at [16 64]}]' \
	' :texts [{:at [0 200] :text ".op" :directive true}]}' >"$work/dpx.edn"
check "vacask: diode params left out" "$bin" --netlist "$work/dpx.edn" --sim vacask "DPX: ibvl, nbvl, vcjo left out"
check "vacask: alias kept"   "$bin" --netlist "$work/dpx.edn" --sim vacask "trs1=0.004"
# diode libraries (Diodes Inc's Zener, TVS and switching tables): a label line that reads as an
# element still leaves a library; ".SUBCKET", "µ", a non-breaking space, ").ENDS", a model after
# its .ENDS under a shared name, a copy's name, a misspelt model name
printf '%s\n' '*SRC=DZA;DI_DZA;Diodes;Zener; 5.10V  0.300W' \
	".SUBCKT DI_DZA $(printf '\xc2\xa0')1 2" '*  Terminals A C' 'D1 1 2 DF' 'DZ 3 1 DR' 'VZ 2 3 4.2' \
	'.MODEL DF D ( IS=4n RS=30 N=1.1 CJO=20p )' '.MODEL DR D ( IS=1f RS=60 N=3 ).ENDS' \
	'*SRC=DZAT;DI_DZAT;Diodes;Zener; 5.10V  0.300W' '.SUBCKT DI_DZA 1 2' 'D1 1 2 DF' 'DZ 3 1 DR' 'VZ 2 3 4.3' \
	'.MODEL DF D ( IS=4n RS=30 N=1.1 CJO=20p )' '.MODEL DR D ( IS=1f RS=60 N=3 )' '.ENDS' \
	'.SUBCKT TVA 1 2' 'D1 1 2 ZDiode' '.ENDS TVA' '.MODEL ZDiode d IS=1e-13 BV=31 IBV=1m' \
	'.SUBCKT TVB 1 2' 'D1 1 2 ZDiode' '.ENDS TVB' '.MODEL ZDiode d IS=1e-13 BV=25 IBV=1m' \
	'.SUBCKET TVC 1 2' 'D1 1 2 TVCX' 'R1 1 2 1G' '' '.model TVCQ D(IS=1p BV=29 IBV=5m)' '' \
	'Switching Diode - one element of device' '.MODEL DSW D ( IS=1n BV=250 IBV=100µ N=1 )' \
	'.SUBCKT DLK 7 1' 'L1 7 2 2n' 'D1 2 1 DSW' 'RL 1 2 5MEG' '.ENDS' >"$work/zen.lib"
out=$("$bin" --check-model "$work/zen.lib" 2>&1)
for want in '".SUBCKET" made ".SUBCKT"' 'non-ASCII characters' '.ENDS on the same line as a card' \
	"models after their subcircuit's .ENDS" 'DI_DZA             now DI_DZAT' 'D1: TVCX made TVCQ'; do
	if grep -qF -- "$want" <<<"$out"; then pass "zen.lib: $want"; else fail "zen.lib: $want"; sed 's/^/     /' <<<"$out" | head -40; fi
done
check "zen.lib: a library, not a circuit" "$bin" --import-model "$work/zen.lib" --repair "repaired"
zen="$models_dir/zen.lib"
check "repaired: µ"          cat "$zen" "IBV=100u"
check "repaired: own line"   grep -c "^\.ENDS$" "$zen" "4"
check "repaired: ZDiode in"  grep -B1 "^\.ENDS TVA" "$zen" "BV=31"

# a ";" comment line inside a subcircuit (it once crashed the import)
printf '.subckt SEMI a b\n; a comment\nR1 a b 1k\n.ends\n' > "$work/semi.lib"
check "import: ; comment line" "$bin" --import-model "$work/semi.lib" --as-is "symbol   SEMI"
# a numeric model name is renamed where an M line names its model (the 5th field), not in
# its bulk node, which has the same number here
printf '.SUBCKT NF 1 2 3\nM1 1 2 3 5 5\nR1 5 3 1\n.ENDS\n.MODEL 5 NMOS(VTO=1)\n' > "$work/numfet.lib"
"$bin" --import-model "$work/numfet.lib" --repair >/dev/null 2>&1
check "repaired: M line model" grep "^M1" "$models_dir/numfet.lib" "M1 1 2 3 5 M5"
# ports written as parameters ("D=10 G=20 S=30", Diodes' MOSFET table): the numbers are the
# ports, the names the terminals; a real parameter (used in the body) is left as it is
printf '.SUBCKT PAF D=10 G=20 S=30\nM1 10 20 30 30 NM\n.MODEL NM NMOS(VTO=1)\n.ENDS\n' > "$work/paf.lib"
check "check: ports as parameters" "$bin" --check-model "$work/paf.lib" 'ports are written "D=10 G=20 S=30"'
"$bin" --import-model "$work/paf.lib" --repair >/dev/null 2>&1
check "repaired: ports"        grep -A1 "^\.SUBCKT PAF" "$models_dir/paf.lib" "* TERMINALS: D G S"
check "repaired: port line"    grep "^\.SUBCKT PAF" "$models_dir/paf.lib" ".SUBCKT PAF 10 20 30"
check "ports as parameters: symbol" grep -A1 '{:name "PAF"' "$imported" ':like "nmos"'
printf '.SUBCKT PRR a b R=10\nR1 a b {R}\n.ENDS\n' > "$work/prr.lib"
check "real parameter kept"    "$bin" --check-model "$work/prr.lib" "no problems found"
# what is right is left as it is: "+" in an element's name (TI), parentheses in an expression
printf '.SUBCKT CLMP a b c\nGVO+ a b VALUE = {IF(V(c)>0,1,0)}\nD1 a b DVN\n.MODEL DVN D KF={PWR(10,0.5)/1E11} IS=1E-16\n.ENDS\n' > "$work/clmp.lib"
check "expressions not repaired" "$bin" --check-model "$work/clmp.lib" "no problems found"
# a dot in a file's name is not its extension: two files, two copies
printf '.SUBCKT SKA a k\nD1 a k DS\n.MODEL DS D(IS=1n)\n.ENDS\n' > "$work/Sk (Less than .5A).spice.txt"
printf '.SUBCKT SKB a k\nD1 a k DS\n.MODEL DS D(IS=2n)\n.ENDS\n' > "$work/Sk (.5A and Above).spice.txt"
check "import name with a dot" "$bin" --import-model "$work/Sk (Less than .5A).spice.txt" "Sk (Less than .5A).lib"
"$bin" --import-model "$work/Sk (.5A and Above).spice.txt" >/dev/null 2>&1
check "dotted names: two copies" cat "$models_dir/Sk (Less than .5A).lib" ".SUBCKT SKA"
check "dotted names: other copy" cat "$models_dir/Sk (.5A and Above).lib" ".SUBCKT SKB"
check "repaired: own model"  cat "$zen" "D1 1 2 TVCQ"
symf="$imported"
check "zener: A C pins"      grep -A1 '{:name "DI_DZA"' "$symf" ':like "diode"'
check "TVS: pins from circuit" grep '{:name "DLK"' "$symf" ':like "diode"'
# an imported model takes the place of the built-in one of the same name
printf '%s\n' '.model 2N3904 NPN(IS=1e-14 BF=123)' >"$work/my3904.lib"
"$bin" --import-model "$work/my3904.lib" >/dev/null 2>&1
printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "npn" :ref "Q1" :value "2N3904" :at [0 0]}]' \
	' :texts [{:at [0 200] :text ".op" :directive true}]}' >"$work/q3904.edn"
check "imported beats built-in" "$bin" --netlist "$work/q3904.edn" "BF=123"
# VACASK: SPICE element lines in a directive, a resistor model (TC1/TC2) and a PSpice VSWITCH
# (VON < VOFF: on at low voltages) in a subcircuit, PSpice-only parameters left out
cat >"$work/vsub.lib" <<'EOF'
.SUBCKT VSUBX A B C
  RA A B RM 10
  S1 B C C 0 SMX
  D1 C 0 DX
.MODEL RM RES (TC1=1e-3 TC2=1E-6)
.MODEL SMX VSWITCH RON=.001 ROFF=100 VON=-0.5 VOFF=0.5
.MODEL DX D(IS=1n T_ABS=25 TIKF=1e-3)
.ENDS
EOF
"$bin" --import-model "$work/vsub.lib" >/dev/null 2>&1
printf '%s\n' '{:spicy-schematic 1 :components []' \
	' :texts [{:at [0 200] :text "V1 a 0 PULSE(0 1 0 1n 1n 1u 2u)\nX1 a b c VSUBX\n.tran 10n 4u" :directive true}]}' >"$work/vsub.edn"
check "vacask directive source" "$bin" --netlist "$work/vsub.edn" --sim vacask 'v1 (a 0) vsource type="pulse"'
check "vacask directive subckt" "$bin" --netlist "$work/vsub.edn" --sim vacask "x1 (a b c) vsubx"
check "vacask RES model"     "$bin" --netlist "$work/vsub.edn" --sim vacask "model rm sp_resistor tc1=0.001"
check "vacask resistor with model" "$bin" --netlist "$work/vsub.edn" --sim vacask "ra (a b) rm r=10"
check "vacask VSWITCH"       "$bin" --netlist "$work/vsub.edn" --sim vacask "model smx spicy_vsw ron=0.001 roff=100 vt=0 vh=0.5 sense=-1"
check "vacask S element"     "$bin" --netlist "$work/vsub.edn" --sim vacask "s1 (b c c 0) smx"
if "$bin" --netlist "$work/vsub.edn" --sim vacask 2>&1 | grep -qi "t_abs\|tikf"; then fail "vacask PSpice-only parameters left out"; else pass "vacask PSpice-only parameters left out"; fi
# Xyce: library cards without their indent (Xyce misreads an indented subcircuit line)
if "$bin" --netlist "$work/vsub.edn" --sim xyce 2>&1 | grep -q "^RA A B RM 10"; then pass "cards without indent"; else fail "cards without indent"; fi
# an op-amp model: a triangle, and its building blocks (called only inside it) get no symbol
cat > "$work/amp.lib" <<'EOF'
.subckt AMPX IN+ IN- VCC VEE OUT
XG IN+ IN- MID 0 GAINX
E1 OUT 0 MID 0 1
Rs VCC VEE 100k
.ends AMPX
.subckt GAINX A B Y COM
E1 Y COM A B 1e5
.ends GAINX
EOF
check "import op-amp"        "$bin" --import-model "$work/amp.lib" "symbol   AMPX"
check "op-amp symbol"        cat "$imported" ':spice "X{ref} {In+} {In-} {V+} {V-} {Out} {value}"'
if grep -q '"GAINX"' "$imported"; then fail "no symbol for a building block"; else pass "no symbol for a building block"; fi
printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "AMPX" :ref "U1" :value "AMPX" :at [0 0]}]' \
	' :texts [{:at [0 200] :text ".op" :directive true}]}' >"$work/ampx.edn"
check "building block in netlist" "$bin" --netlist "$work/ampx.edn" ".subckt GAINX"
check "subckt instance"      "$bin" --netlist "$work/fet.edn" "XM1 m1_d m1_g m1_s TFET"
check "subckt card"          "$bin" --netlist "$work/fet.edn" ".SUBCKT TFET"
check ".model directive"     "$bin" --netlist "$work/fet.edn" ".model MYD D(IS=1n N=2)"
check "vacask subckt"        "$bin" --netlist "$work/fet.edn" --sim vacask "subckt tfet (10 20 30)"
check "vacask instance"      "$bin" --netlist "$work/fet.edn" --sim vacask "m1 (m1_d m1_g m1_s) tfet"
# sharing: the copies saved in the schematic let a spicy without the imported model run it
check "embed"                "$bin" --embed "$work/fet.edn" "symbol   TFET"
mkdir -p "$work/other"
cp "$work/fet.edn" "$work/other/"
check "shared file netlist"  env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --netlist "$work/other/fet.edn" ".SUBCKT TFET"
check "shared file instance" env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --netlist "$work/other/fet.edn" "XM1 m1_d m1_g m1_s TFET"
# someone with another TFET still gets the copy saved in the file, also after saving it
sed 's/KP=50u/KP=999u/' "$work/fet.lib" >"$work/other/fet.lib"
env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --import-model "$work/other/fet.lib" >/dev/null 2>&1
check "embedded copy wins"   env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --netlist "$work/other/fet.edn" "KP=50u"
env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --embed "$work/other/fet.edn" >/dev/null 2>&1
if grep -q 'KP=999u' "$work/other/fet.edn"; then fail "copy kept on save"; else pass "copy kept on save"; fi
check "copy kept, netlist"   env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --netlist "$work/other/fet.edn" "KP=50u"
# ... and is told it differs, and can choose the library's version
check "embed: differs"       env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --embed "$work/other/fet.edn" "differs  tfet: the library here has another version"
check "embed --update"       env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --embed "$work/other/fet.edn" --update "updated  tfet (the library's version)"
check "updated copy, netlist" env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --netlist "$work/other/fet.edn" "KP=999u"
if env SPICY_CONFIG_DIR="$work/othercfg" "$bin" --embed "$work/other/fet.edn" 2>&1 | grep -q "differs"; then fail "updated: no longer differs"; else pass "updated: no longer differs"; fi
check "embed: unknown option" "$bin" --embed "$work/fet.edn" --updat "unknown option --updat"
# spicy's own models are saved too
cp "$work/rc_lowpass.edn" "$work/rc_shared.edn"
check "built-in model embedded" "$bin" --embed "$work/rc_shared.edn" "(from spicy built-in)"
# the model catalog: kinds and ratings from a vendor's *SRC line, the file's name, the model
check "models: built-in kind" "$bin" --list models Zener '{:name "1N4733" :kind "Zener" :symbol "zener" :V 5.1 :P 1'
cat >"$work/Vendor_Schottky.lib" <<'EOF'
*SRC=B5819W;DI_B5819W;Diodes;Si;  40.0V  1.00A  10.0ns   Vendor Schottky rectifier
.MODEL DI_B5819W D(IS=31u RS=0.05 BV=40)
.MODEL PLAIN1 D(IS=1n BV=30)
EOF
"$bin" --import-model "$work/Vendor_Schottky.lib" >/dev/null 2>&1
check "models: vendor ratings" "$bin" --list models Schottky '{:name "DI_B5819W" :kind "Schottky" :symbol "schottky" :V 40 :I 1 :T 1e-08 :description "Vendor Schottky rectifier"'
check "models: kind from file name" "$bin" --list models Schottky '{:name "PLAIN1" :kind "Schottky" :symbol "schottky" :V 30'
check "models: unknown kind" "$bin" --list models Diod "kinds are Rectifier"
# what the file does not state, given by the user (kept beside the libraries)
check "model-info: set"      "$bin" --model-info plain1 I=2A "desc=My Schottky" ':I 2 :description "My Schottky" :file "Vendor_Schottky.lib" :yours ["I" "desc"]'
check "model-info: listed"   "$bin" --list models Schottky ':name "PLAIN1" :kind "Schottky" :symbol "schottky" :V 30 :I 2'
if grep -rq "My Schottky" "$models_dir"; then fail "model-info: model file unchanged"; else pass "model-info: model file unchanged"; fi
check "model-info: same as file" "$bin" --model-info DI_B5819W "V=40 V" ':V 40 :I 1 :T 1e-08 :description "Vendor Schottky rectifier" :file "Vendor_Schottky.lib"}'
check "model-info: another device" "$bin" --model-info plain1 kind=NPN "can be Rectifier, Switching, Schottky"
check "model-info: no such rating" "$bin" --model-info plain1 R=1 "has no R rating"
check "model-info: forget"   "$bin" --model-info plain1 --forget '{:name "PLAIN1" :kind "Schottky" :symbol "schottky" :V 30 :file "Vendor_Schottky.lib"}'
sed 's/"MYD"/"MYDX"/' "$work/fet.edn" >"$work/typo.edn"
check "missing model"        "$bin" --netlist "$work/typo.edn" "D1: model MYDX not found"
printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "res" :ref "R1" :value "1k" :at [0 0]}]' \
	' :flags [{:name "0" :at [16 16]} {:name "0" :at [16 96]}]' \
	' :texts [{:at [0 200] :text ".op\n.include nowhere.lib" :directive true}]}' >"$work/inc.edn"
check "missing include"      "$bin" --netlist "$work/inc.edn" "file not found"

# a .step run whose second (last) value no simulator takes
sed 's/:value "1k" :at \[288 0\]/:value "{rv}" :at [288 0]/; s/:text ".tran 20u"/:text ".tran 20u\\n.param rv=1k\\n.step param rv list 1k 1k*"/' "$work/rc_lowpass.edn" >"$work/badstep.edn"

if command -v ngspice >/dev/null 2>&1; then
	# V(dd) = 2 V by hand: 5 V through 1k into an NMOS in triode (kp·W/L = 0.5 mA/V², vgs = 5 V)
	check "ngspice subckt"     "$bin" --text --run "$work/fet.edn" "v(dd)                        2 V"
	check "ngspice subckt I"   "$bin" --text --run "$work/fet.edn" "i(vsns_m1_d)"
	check "ngspice .model"     "$bin" --text --run "$work/fet.edn" "v(a)"
	# .meas on a .dc sweep that goes down, of a source written in the directive; a PMOS's
	# drain current is the current into the drain (ngspice's own @m1[id] has the other sign)
	printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "pmos" :ref "M1" :value "PMT" :at [0 0]}]' \
		' :flags [{:name "d" :at [48 96]} {:name "g" :at [0 16]} {:name "0" :at [48 0]}]' \
		' :texts [{:at [0 300] :text "Vd d 0 -1\nVg g 0 0\n.model PMT PMOS(LEVEL=1 VTO=-1 KP=1m)\n.dc Vg 0 -5 -0.1\n.meas dc idm FIND Id(M1) AT=-5\n.meas dc ivd FIND I(Vd) AT=-5" :directive true}]}' >"$work/pdc.edn"
	check "meas dc, sweep down" "$bin" --text --run "$work/pdc.edn" "measure ivd = 3.5 mA at -5 V"
	check "pmos Id into drain" "$bin" --text --run "$work/pdc.edn" "measure idm = -3.5 mA"
	# a failed run must not show the raw file of another schematic in the same folder
	sed 's/:value "1k" :at \[400 0\]/:value "1k bad=(" :at [400 0]/' "$work/fet.edn" >"$work/bad.edn"
	check "failed run, no stale" "$bin" --text --run "$work/bad.edn" "without results"
	check "ngspice transient"  "$bin" --text --run "$work/rc_lowpass.edn" "Transient Analysis"
	# a .step run whose last value fails says so
	check "step without results" "$bin" --text --run "$work/badstep.edn" "[rv=1k*]: no results"
	check "ngspice netlist run" "$bin" --text --run "$work/buck.cir" "v(out)"
	check "ngspice ac"         "$bin" --text --run "$work/rc_ac.edn" "AC Analysis"
	check "ngspice opamp"      "$bin" --text --run "$work/opamp_inverting.edn" "v(out)"
	check "ngspice switch"     "$bin" --text --run "$work/switch.edn" "i(@s1[i])"
	# PSpice models (VSWITCH, TEMP): ngspice runs in its PSpice compatibility mode. 1 V through
	# the switch (1 ohm on) into 1k: v(b) = 999 mV, from an .include'd file and from an imported model
	cat >"$work/psw.lib" <<'EOF'
.subckt PSWX IN OUT CTRL
S1 IN OUT CTRL 0 SMODX
.model SMODX VSWITCH(Ron={1+0*TEMP} Roff=1e9 Von=1 Voff=0)
.ends PSWX
EOF
	sed 's/PSWX/PSWY/g; s/SMODX/SMODY/' "$work/psw.lib" >"$work/pswy.lib"
	"$bin" --import-model "$work/pswy.lib" >/dev/null 2>&1
	for which in "X1 a b c PSWX\n.include psw.lib" "X1 a b c PSWY"; do
		printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "res" :ref "R1" :value "1k" :at [0 0]}]' \
			' :flags [{:name "b" :at [16 16]} {:name "0" :at [16 96]}]' \
			" :texts [{:at [0 200] :text \"V1 a 0 1\nVc c 0 2\n$which\n.op\" :directive true}]}" >"$work/psw.edn"
		name=$(echo "$which" | cut -c10-13)
		check "pspice mode ($name)"    "$bin" --netlist "$work/psw.edn" "ngbehavior=psa"
		check "pspice model run ($name)" "$bin" --text --run "$work/psw.edn" "999 mV"
	done
	check "no pspice mode"     "$bin" --netlist "$work/switch.edn" "* spicy"
	if "$bin" --netlist "$work/switch.edn" 2>&1 | grep -q ngbehavior; then fail "plain netlist without pspice mode"; else pass "plain netlist without pspice mode"; fi
	"$bin" --text --run "$work/opamp_inverting.edn" --csv "$work/o.csv" >/dev/null 2>&1
	gain=$(awk -F, 'NR>1 { if ($4 > m) m = $4 } END { printf "%.2f", m / 0.1 }' "$work/o.csv")
	if [ "$gain" = "10.00" ] || [ "$gain" = "9.99" ]; then pass "opamp gain $gain"; else fail "opamp gain $gain (want 10)"; fi
else
	echo "skip ngspice runs (ngspice is not on the PATH)"
fi
if command -v Xyce >/dev/null 2>&1; then
	check "xyce device current" "$bin" --text --run "$work/rc_lowpass.edn" --sim xyce "I(R1)"
	check "xyce step currents" "$bin" --text --run "$work/step.edn" --sim xyce "I(R1)"
else
	echo "skip Xyce runs (Xyce is not on the PATH)"
fi
if command -v vacask >/dev/null 2>&1; then
	# a step that fails must not show the results of the step before (the same file names)
	if "$bin" --text --run "$work/badstep.edn" --sim vacask 2>&1 | grep -qF '[rv=1k*]" ('; then fail "vacask failed step, no stale"; else pass "vacask failed step, no stale"; fi
	check "vacask step without results" "$bin" --text --run "$work/badstep.edn" --sim vacask "[rv=1k*]: no results"
else
	echo "skip VACASK runs (vacask is not on the PATH)"
fi

# editing without the GUI (scripts, AI agents): build an RC filter from nothing
e="$work/agent.edn"
check "new"            "$bin" --new "$e" ":created true"
check "add part"       "$bin" --add "$e" voltage V1 --value "SIN(0 1 1k)" --at 0,0 ':added "V1"'
check "add rotated"    "$bin" --add "$e" resistor R1 --value 1k --at 160,-64 --rot 1 ':rot 1'
check "add auto ref"   "$bin" --add "$e" capacitor --value 1u --at 320,0 ':added "C1"'
check "connect"        "$bin" --connect "$e" V1.P R1.1 ':connected ["V1.P" "R1.1"]'
check "connect net"    "$bin" --connect "$e" R1.2 C1.1 --net out ':net "out"'
check "ground on pin"  "$bin" --add "$e" ground --to V1.2 ':added "ground"'
"$bin" --add "$e" ground --to C1.2 >/dev/null 2>&1
check "directive"      "$bin" --add "$e" directive ".tran 10u 3m" ':added ".tran 10u 3m"'
check "check ok"       "$bin" --check "$e" ':ok true'
check "get pin net"    "$bin" --get "$e" C1 ':net "out"'
check "set value"      "$bin" --set "$e" R1.value=2k ':changed ["R1.value=2k"]'
check "get value"      "$bin" --get "$e" R1 ':value "2k"'
check "json"           "$bin" --get "$e" R1 --json '"value": "2k"'
check "do rotate"      "$bin" --do "$e" edit/rotate C1 ':action "edit/rotate"'
check "unknown part"   "$bin" --set "$e" R9.value=1 ':kind :not-found'
"$bin" --set "$e" R9.value=1 >/dev/null 2>&1; [ $? = 1 ] && pass "exit 1 on a missing part" || fail "exit 1 on a missing part"
"$bin" --get /nonexistent.edn >/dev/null 2>&1; [ $? = 3 ] && pass "exit 3 on a missing file" || fail "exit 3 on a missing file"
"$bin" --set >/dev/null 2>&1; [ $? = 2 ] && pass "exit 2 on bad usage" || fail "exit 2 on bad usage"
check "gui-only action" "$bin" --do "$e" file/open ':kind :gui-only'
check "remove"         "$bin" --remove "$e" R1 ':removed ["R1"]'
check "check finds open pins" "$bin" --check "$e" 'is not connected'
check "list symbols"   "$bin" --list symbols ':name "res"'
check "list actions"   "$bin" --list actions ':headless true'

if [ "$fails" -gt 0 ]; then
	echo "$fails command-line test(s) failed"
	exit 1
fi
echo "all command-line tests passed"
