#!/usr/bin/env bash
# GUI smoke test (Linux): opens an example, runs it with ngspice, probes two
# signals and saves a screenshot, on a virtual display when xvfb-run exists.
#
#   tests/gui_smoke.sh [path/to/spicy]
#   KEEP_SCREENSHOTS=1 keeps the work folder.
set -u
bin=${1:-./spicy}
case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
root=$(cd "$(dirname "$0")/.." && pwd)

work=$(mktemp -d)
[ -z "${KEEP_SCREENSHOTS:-}" ] && trap 'rm -rf "$work"' EXIT
export SPICY_CONFIG_DIR="$work/cfg" SPICY_SCALE=1 SPICY_WINDOW=1400x900
cp "$root/examples/rc_lowpass.edn" "$work/"

run() { # screenshot name, actions[, schematic]
	local xvfb=()
	command -v xvfb-run >/dev/null 2>&1 && xvfb=(xvfb-run -a -s "-screen 0 1600x1000x24")
	SPICY_ACTIONS="$2" SPICY_SCREENSHOT="$work/$1.png" timeout 120 "${xvfb[@]}" "$bin" "${3:-$work/rc_lowpass.edn}" >>"$work/log.txt" 2>&1
}

run start ""
if command -v ngspice >/dev/null 2>&1; then
	run probed "sim/run;trace:V(out);trace:I(R1);wave/cursor1;wave/cursor2"
	# the waveforms in their own window (screenshot popout-waves.png), then docked from inside it
	run popout "sim/run;trace:V(out);wave/pop-out"
	run docked "sim/run;trace:V(out);wave/pop-out;in-waves:wave/pop-out" || {
		echo "FAIL: docking the waveform window from inside it (exit $?)"
		tail -20 "$work/log.txt"
		exit 1
	}
	# the spectrum of V(out) in a pane of its own
	run fft "sim/run;trace:V(out);fft:V(out)"
	# right-click on the plot: the menu with "FFT of V(out)", and in the spectrum pane its settings
	run fftmenu "sim/run;trace:V(out);rclick:0.5,0.18"
	run fftpanemenu "sim/run;trace:V(out);fft:V(out);rclick:0.5,0.36"
	# double-click on the plot: the marker / cursor menu
	run dblclick "sim/run;trace:V(out);dblclick:0.5,0.25"
	shots="start probed popout popout-waves docked fft fftmenu fftpanemenu dblclick"
else
	echo "ngspice is not installed: no simulation screenshot"
	shots="start"
fi
run picker "place/component"
shots="$shots picker"
# the model table: from a kind's tile (a double-click on a row places a part with that model),
# and from a part's editor
run models "models:Diodes/Zener;dblclick:0.3,0.254"
run choose "choose:D1"
shots="$shots models choose"
if ! grep -q "placing zener with the model 1N4733" "$work/cfg/state/spicy.log"; then
	echo "FAIL: a double-click on the model table's first Zener did not place a 1N4733"
	grep -i "placing\|error" "$work/cfg/state/spicy.log" | tail -5
	exit 1
fi
# typed into the picker's search as it opens: the Zener tile with the one model it matches, the
# table with that search, and a double-click on its row places it
run search "place/component;type:1N4742;click:0.307,0.33;dblclick:0.3,0.254"
shots="$shots search"
if ! grep -q "placing zener with the model 1N4742" "$work/cfg/state/spicy.log"; then
	echo "FAIL: typing 1N4742 into the parts search did not lead to a 1N4742 to place"
	grep -i "placing\|error" "$work/cfg/state/spicy.log" | tail -5
	exit 1
fi
# the model table's editor: a rating and a datasheet link typed in and saved go to model-info.edn
run save "place/component;type:1N4742;click:0.307,0.33;click:0.3,0.254;click:0.379,0.731;type:0.2;click:0.464,0.799;type:https://example.com/1n4742.pdf;click:0.739,0.767"
shots="$shots save"
if ! grep -qF '{"1n4742" {:I 0.2 :datasheet "https://example.com/1n4742.pdf"}}' "$work/cfg/data/model-info.edn" 2>/dev/null; then
	echo "FAIL: IF = 0.2 and a datasheet typed in the model table's editor and saved are not in model-info.edn"
	cat "$work/cfg/data/model-info.edn" 2>&1 | tail -5
	exit 1
fi
# Enter in the editor's datasheet field saves it, and does not place the model too (it did: the
# Enter that ended the typing was Place's, and what was typed was lost)
placed() { grep -c "placing zener with the model 1N4742" "$work/cfg/state/spicy.log"; }
n=$(placed)
run dsenter "place/component;type:1N4742;click:0.307,0.33;click:0.3,0.254;click:0.464,0.799;type:https://example.com/enter.pdf;key:enter"
shots="$shots dsenter"
if ! grep -qF ':datasheet "https://example.com/enter.pdf"' "$work/cfg/data/model-info.edn" 2>/dev/null || [ "$(placed)" != "$n" ]; then
	echo "FAIL: Enter in the model table's datasheet field: not saved, or the model placed ($n placings before, $(placed) after)"
	cat "$work/cfg/data/model-info.edn" 2>&1 | tail -3
	exit 1
fi
# typed and not saved, then Place: kept with the model placed
run dsplace "place/component;type:1N4742;click:0.307,0.33;click:0.3,0.254;click:0.464,0.799;type:https://example.com/place.pdf;click:0.826,0.843"
shots="$shots dsplace"
if ! grep -qF ':datasheet "https://example.com/place.pdf"' "$work/cfg/data/model-info.edn" 2>/dev/null || [ "$(placed)" != "$((n + 1))" ]; then
	echo "FAIL: a datasheet typed in the model table and then Place: not saved, or not placed"
	cat "$work/cfg/data/model-info.edn" 2>&1 | tail -3
	exit 1
fi
# a datasheet: Browse… in D1's editor starts in the schematic's folder; its PDF picked, OK and
# saved, it is kept relative to the schematic. Then Open datasheet in D1's menu opens it (with
# the program SPICY_OPEN_WITH names: one that notes what it was given)
mkdir -p "$work/ds"
cp "$root/examples/rc_lowpass.edn" "$work/ds/g.edn"
printf '%%PDF-1.4\n' >"$work/ds/d1.pdf"
run dsbrowse "edit:D1;click:0.639,0.478;dblclick:0.29,0.294;click:0.676,0.67;file/save" "$work/ds/g.edn"
shots="$shots dsbrowse"
if ! grep -qF ':attrs {"datasheet" "d1.pdf"}' "$work/ds/g.edn"; then
	echo "FAIL: the datasheet picked in D1's editor is not saved as d1.pdf"
	grep -o ':ref "D1"[^}]*}' "$work/ds/g.edn"
	exit 1
fi
printf '#!/bin/sh\necho "$1" >>"%s/opened.txt"\n' "$work" >"$work/openwith.sh"
chmod +x "$work/openwith.sh"
SPICY_OPEN_WITH="$work/openwith.sh" run dsopen "rclick:0.774,0.4;click:0.813,0.683" "$work/ds/g.edn"
shots="$shots dsopen"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/opened.txt" ] && break; sleep 0.1; done
if ! grep -qx "$work/ds/d1.pdf" "$work/opened.txt" 2>/dev/null; then
	echo "FAIL: Open datasheet in D1's menu did not open $work/ds/d1.pdf (got: $(cat "$work/opened.txt" 2>/dev/null))"
	exit 1
fi
# Show SPICE model in D1's menu: its card in the text window
run spicemodel "rclick:0.774,0.4;click:0.813,0.709" "$work/ds/g.edn"
shots="$shots spicemodel"
if ! grep -q "showing D1: the SPICE model 1N4148" "$work/cfg/state/spicy.log"; then
	echo "FAIL: Show SPICE model in D1's menu did not show 1N4148's model"
	grep -i "showing\|error" "$work/cfg/state/spicy.log" | tail -5
	exit 1
fi
# menu items picked as a click picks them: an action, a submenu item (saved in settings.edn)
run menus "menu:View/Move the waveforms;menu:View/UI scale/150 %"
shots="$shots menus"
if ! grep -qE ':scale +1\.5 ' "$work/cfg/settings.edn"; then
	echo "FAIL: View › UI scale › 150 % did not set :ui :scale 1.5"
	tail -20 "$work/log.txt"
	exit 1
fi

for f in $shots; do
	if [ ! -s "$work/$f.png" ]; then
		echo "FAIL: no screenshot $f.png"
		tail -20 "$work/log.txt"
		exit 1
	fi
done
echo "GUI smoke test passed (screenshots: $work)"
