# spicy

A fast, single-binary schematic editor and waveform viewer for **ngspice**, **Xyce** and **VACASK**.

Draw a circuit, press **F5**, and probe voltages and currents right on the schematic.
Symbols, models and default settings are built into the binary, so nothing else needs to be installed besides a simulator.

## Features

### Schematic editor
- Place parts from a part picker (**F2**) or with single-key shortcuts (`R`, `C`, `L`, …).
- Wires with Manhattan routing (Space flips the corner). A wire drawn through a part connects to its pins. Dragged parts pull their wires along (rubber-banding).
- Net labels, grounds, comments and SPICE directives (`.tran`, `.ac`, `.dc`, `.op`, `.param`, …).
- Copy, paste, duplicate, rotate and mirror, plus undo/redo (200 levels).
- Tabs for several open schematics. They reopen at the next start.
- Net highlighting on hover. Operating-point voltages are shown on the wires after a `.op` run.

### Built-in parts and models
- **Passives:** resistor, capacitor, polarised capacitor, inductor, 2- and 3-winding transformers.
- **Semiconductors:** diode, Zener, Schottky, LED, NPN/PNP BJTs, N/P MOSFETs, op-amp.
- **Sources:** voltage and current sources (DC, pulse, sine, PWL, AC), behavioural sources (`V=…`, `I=…`), E/G controlled sources, voltage-controlled switch.
- **Model library:** you can type a part number as the value, e.g. `1N4148`, `1N4007`, `1N5819`, `BAT54`, `2N3904`, `2N3906`, `2N2222`, `BC547`, `2N7002`, `IRF540`, and more. Default `.model` cards are added when they're needed.

### Models and symbols
- **Import SPICE models** (`.lib`, `.mod`, …). spicy makes a symbol for each subcircuit, matching its pins to the ports.
- **Symbol editor:** draw graphics, place and name pins, map pins to subcircuit ports, and save to your own symbol library.
- **Embed models:** a schematic can carry copies of the models and symbols it uses, so it simulates on any machine.

### Simulation
- Supports **ngspice**, **Xyce** and **VACASK**, and you can switch between them with **F7**. spicy translates the netlist to VACASK's own language automatically.
- Simulations run as a separate process, so a simulator crash can't take spicy down.
- Optionally re-run on every save, set a run timeout, add extra libraries or SPICE lines to every netlist.
- View the generated netlist (**Ctrl+Shift+N**) and the simulator log (**Ctrl+L**).
- You can add any SPICE-compatible simulator by editing `settings.edn`.

### Waveform viewer
- Click a wire to plot its voltage, or click a part to plot its current (probe mode).
- **Trace expressions:** `V(out)`, `V(a,b)`, `I(R1)`, `Ic(Q1)`, arithmetic, and functions such as `db`, `mag`, `ph`, `abs`, `sqrt`, `ln`, `log10`, `d` (derivative), `min`, `max`.
- Multiple panes, two cursors with readout, markers, box zoom and zoom-back.
- **FFT:** right-click a transient trace and choose **FFT** to see its spectrum in a new pane. The pane has its own frequency axis and a choice of Hann, Hamming, Blackman, flat-top or rectangular window. Amplitude can be in dB or linear, and the FFT covers the time range you're zoomed into. The defaults are set in `settings.edn` (`:waveform :fft-…`).
- AC results as Bode plots (magnitude in dB + phase), magnitude, phase or real/imaginary.
- Fast with very long traces (min/max decimation).
- Switch between analyses of a run (op, tran, ac, …) with **Tab**.
- **`.plot` directive:** `.plot V(out), I(R1)` in a SPICE directive shows those traces after every run, in the analysis they belong to. The line is checked before the run: syntax, and that the nets and parts it names exist in the schematic.
- **Pop-out window** (**Ctrl+Shift+W**): waveforms in their own window, e.g. on a second monitor or full screen.
- Export the traces to CSV.

### Import
- **LTspice `.asc` schematics:** open them directly or convert them with `--import-asc`.
- **SPICE netlists** (`.cir`, `.net`, `.sp`, …): each element becomes a part, wired up with net labels.

### Customisation
All configuration is plain [EDN](https://github.com/edn-format/edn) and **reloads as soon as you save it**:

| File | What it controls |
|---|---|
| `settings.edn` | UI, layout, schematic editor, waveform viewer, simulators |
| `themes.edn` | Colour themes: Dark, Light, Classic, Oscilloscope, Nord, Solarized Light, or your own |
| `shortcuts.edn` | Every keyboard shortcut |
| `symbols/*.edn` | Your own symbols, which add to or replace the built-in ones |

A setting you leave out keeps its default, and typos are reported. To restore the defaults, delete the file. Run `spicy --paths` to see where the files are.

## Build

You only need the [Odin](https://odin-lang.org) compiler. raylib comes with Odin and is linked statically.

```sh
make            # optimised build -> ./spicy
make install    # install to ~/.local/bin
```

Prebuilt binaries for Linux (x86_64, arm64), macOS (universal) and Windows are published on the releases page.

You also need at least one simulator on your `PATH`: [ngspice](https://ngspice.sourceforge.io), [Xyce](https://xyce.sandia.gov) or [VACASK](https://codeberg.org/arpadbuermen/VACASK). If a simulator isn't on your `PATH`, point spicy at it:

```sh
spicy --set-program vacask /opt/vacask/bin/vacask
```

## Usage

```sh
spicy                                   # start the GUI
spicy circuit.edn other.asc             # open schematics (LTspice files are imported)
```

### Command line (no GUI)

```sh
spicy --netlist <file> [--sim <id>]                 # print the netlist
spicy --run <file> [--sim <id>] [--csv out.csv]     # simulate and list or save the results
spicy --import-asc <in.asc> <out.edn>               # convert an LTspice schematic
spicy --import-model <file>                         # add a SPICE model library
spicy --embed <file.edn>                            # embed used models and symbols in the file
spicy --set-program <simulator> <path>              # set the program a simulator runs
spicy --paths                                       # where settings, symbols, models and logs live
spicy --check-config                                # check the config files for problems
spicy --diagnostics                                 # versions, paths, environment (for bug reports)
spicy --version | --help
```

Logging options: `--log-level <debug|info|warning|error|fatal>`, `-v`, `-q`, `--log-file <path|none>`.

Environment variables: `SPICY_CONFIG_DIR` (config folder), `SPICY_SCALE` (UI scale).

## Essential shortcuts

| Key | Action |
|---|---|
| `F2` / `P` | Part picker |
| `W` | Draw wire |
| `N` | Net label |
| `S` / `.` | SPICE directive |
| `Ctrl+R` / `Ctrl+E` | Rotate / mirror |
| `F5` / `Ctrl+Enter` | Run simulation |
| `F6` | Edit simulation command |
| `F7` | Choose simulator |
| `Alt+P` | Probe mode |
| `F` | Fit to view |
| `Ctrl+B` | Show/hide waveforms |
| `1` / `2` / `M` | Cursor 1 / cursor 2 / marker |
| `F1` | All shortcuts |

## Examples

The `examples/` folder has ready-to-run schematics: an RC low-pass filter (transient and AC), an inverting op-amp, a switch and a transformer.

```sh
spicy examples/rc_lowpass.edn
spicy --run examples/rc_ac.edn
```
