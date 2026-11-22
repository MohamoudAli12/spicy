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
check "vacask netlist"       "$bin" --netlist "$work/rc_lowpass.edn" --sim vacask "analysis tran1 tran"
check "vacask diode name"    "$bin" --netlist "$work/rc_lowpass.edn" --sim vacask "m_1n4148"
check "opamp subcircuit"     "$bin" --netlist "$work/opamp_inverting.edn" ".subckt spicy_opamp"
check "switch netlist"       "$bin" --netlist "$work/switch.edn" "S1 out 0 ctl 0 SW"
check "xyce switch model"    "$bin" --netlist "$work/switch.edn" --sim xyce "VSWITCH(RON=1 ROFF=1Meg VON="
check "xyce switch steps"    "$bin" --netlist "$work/switch.edn" --sim xyce ".options timeint erroption=1"
check "transformer netlist" "$bin" --netlist "$work/transformer.edn" "KT1 LT1_P LT1_S 0.999"
check "vacask transformer"  "$bin" --netlist "$work/transformer.edn" --sim vacask "kt1 () mutual k=0.999 ind1=\"lt1_p\" ind2=\"lt1_s\""
check "vacask switch"        "$bin" --netlist "$work/switch.edn" --sim vacask "embed \"spicy_vsw.va\""

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
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*"
echo '{:schematic {:grid-style :lines}} ; mine' >"$work/pcfg/settings.edn"
check "set program"          env SPICY_CONFIG_DIR="$work/pcfg" "$bin" --set-program vacask /opt/x/vacask "vacask runs /opt/x/vacask"
check "set program kept"     cat "$work/pcfg/settings.edn" "; mine"
check "set program config"   env SPICY_CONFIG_DIR="$work/pcfg" "$bin" --check-config "no problems"
env SPICY_CONFIG_DIR="$work/pcfg" "$bin" --set-program vacask /opt/y/vacask >/dev/null
check "set program again"    cat "$work/pcfg/settings.edn" '["/opt/y/vacask" "-qp" "{netlist}"]'

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
# spicy's own models are saved too
cp "$work/rc_lowpass.edn" "$work/rc_shared.edn"
check "built-in model embedded" "$bin" --embed "$work/rc_shared.edn" "(from spicy built-in)"
sed 's/"MYD"/"MYDX"/' "$work/fet.edn" >"$work/typo.edn"
check "missing model"        "$bin" --netlist "$work/typo.edn" "D1: model MYDX not found"
printf '%s\n' '{:spicy-schematic 1 :components [{:symbol "res" :ref "R1" :value "1k" :at [0 0]}]' \
	' :flags [{:name "0" :at [16 16]} {:name "0" :at [16 96]}]' \
	' :texts [{:at [0 200] :text ".op\n.include nowhere.lib" :directive true}]}' >"$work/inc.edn"
check "missing include"      "$bin" --netlist "$work/inc.edn" "file not found"

if command -v ngspice >/dev/null 2>&1; then
	# V(dd) = 2 V by hand: 5 V through 1k into an NMOS in triode (kp·W/L = 0.5 mA/V², vgs = 5 V)
	check "ngspice subckt"     "$bin" --run "$work/fet.edn" "v(dd)                        2 V"
	check "ngspice subckt I"   "$bin" --run "$work/fet.edn" "i(vsns_m1_d)"
	check "ngspice .model"     "$bin" --run "$work/fet.edn" "v(a)"
	# a failed run must not show the raw file of another schematic in the same folder
	sed 's/:value "1k" :at \[400 0\]/:value "1k bad=(" :at [400 0]/' "$work/fet.edn" >"$work/bad.edn"
	check "failed run, no stale" "$bin" --run "$work/bad.edn" "without results"
	check "ngspice transient"  "$bin" --run "$work/rc_lowpass.edn" "Transient Analysis"
	check "ngspice netlist run" "$bin" --run "$work/buck.cir" "v(out)"
	check "ngspice ac"         "$bin" --run "$work/rc_ac.edn" "AC Analysis"
	check "ngspice opamp"      "$bin" --run "$work/opamp_inverting.edn" "v(out)"
	check "ngspice switch"     "$bin" --run "$work/switch.edn" "i(@s1[i])"
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
		check "pspice model run ($name)" "$bin" --run "$work/psw.edn" "999 mV"
	done
	check "no pspice mode"     "$bin" --netlist "$work/switch.edn" "* spicy"
	if "$bin" --netlist "$work/switch.edn" 2>&1 | grep -q ngbehavior; then fail "plain netlist without pspice mode"; else pass "plain netlist without pspice mode"; fi
	"$bin" --run "$work/opamp_inverting.edn" --csv "$work/o.csv" >/dev/null 2>&1
	gain=$(awk -F, 'NR>1 { if ($4 > m) m = $4 } END { printf "%.2f", m / 0.1 }' "$work/o.csv")
	if [ "$gain" = "10.00" ] || [ "$gain" = "9.99" ]; then pass "opamp gain $gain"; else fail "opamp gain $gain (want 10)"; fi
else
	echo "skip ngspice runs (ngspice is not on the PATH)"
fi

if [ "$fails" -gt 0 ]; then
	echo "$fails command-line test(s) failed"
	exit 1
fi
echo "all command-line tests passed"
