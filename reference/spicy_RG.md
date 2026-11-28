# spicy Reference Guide

This guide describes the SPICE directives and trace expressions that spicy adds to the simulator
netlist, and how they behave on each supported simulator: ngspice, Xyce and VACASK. It is written
in the style of the Xyce Reference Guide (`reference/Xyce_RG.pdf`).

Contents

1. Overview
2. Directives
   - 2.1 `.plot`
   - 2.2 `.meas`
   - 2.3 `.step`
   - 2.4 `.noise`
3. Trace expressions
   - 3.1 Vectors and probes
   - 3.2 Arithmetic and comparison operators
   - 3.3 Functions
   - 3.4 Units
4. Results
   - 4.1 Noise results
   - 4.2 Integrated noise
5. Command line
6. Simulator support
   - 6.1 PSpice and LTspice models
7. Examples

---

## 1 Overview

spicy reads the SPICE directives of a schematic (the text items whose *directive* flag is set).
Most directives are passed to the simulator unchanged. Three are handled by spicy itself and are
kept out of the simulator's netlist:

| Directive | Purpose | Handled by |
|---|---|---|
| `.plot` | Show traces after every run | spicy, in the waveform viewer |
| `.meas` | Measure results | spicy, from the saved data |
| `.step` | Sweep a parameter | spicy, one simulator run per value |

`.noise` is a simulator analysis. spicy translates it for each simulator and gives the same result
names on all three (section 4.1).

spicy checks `.plot`, `.meas` and `.step` before the simulation starts, and for VACASK it also
checks the analyses it translates. A line with an error is reported with the correct form, and
the simulation does not run. Other directives are passed to the simulator, which reports its own
errors.

---

## 2 Directives

### 2.1 `.plot`

**Syntax**

```
.plot EXPR [, EXPR …]
```

**Description**

`.plot` asks for traces to be shown in the waveform viewer after every run. The line is not sent to
the simulator. Each `EXPR` is a trace expression (section 3). Expressions are separated by commas;
commas inside parentheses, as in `V(a,b)`, do not separate them.

Each analysis of a run shows the `.plot` traces it can evaluate, in the viewer's analysis list. For
example, a transient analysis can show `V(out)` but not `onoise_spectrum`. **Tab** moves between
the analyses, and the `.plot` traces of each are shown in the one selected.

If an expression cannot be evaluated in any analysis of the run, the viewer reports it as a
warning. The command line does not use `.plot`.

**Checks before the run**

- The expression must have valid syntax (section 3).
- Every net in `V(...)` and every part in `I(...)` and `Ic(...)` must exist in the schematic.
  Names with a hierarchy (`x1.out`), a bus or a raw vector (`i(@r1[i])`) are checked by the run.

**Examples**

```
.plot V(in), V(out)
.plot V(out) > 0.5
.plot db(V(out)), ph(V(out))
.plot onoise_spectrum
```

**Messages**

Each message names the problem and gives a correct form, for example:

```
.plot "V(outt)": no net "outt" in the schematic. Nets here: N001, out. Correct: V(out)
.plot "V(out": the "(" after "V" is never closed. Correct: V(out)
```

---

### 2.2 `.meas`

**Syntax**

```
.meas tran NAME MAX|MIN|AVG|RMS|PP|INTEG EXPR [FROM=x] [TO=x]
.meas tran NAME FIND EXPR AT=x
.meas tran NAME TRIG EXPR VAL=v [RISE=n|FALL=n|CROSS=n]
                     TARG EXPR VAL=v [RISE=n|FALL=n|CROSS=n]
```

**Description**

`.meas` measures the results of a run. The results are printed in the status bar, the simulator
log and the command line, and listed in the viewer's **Measurements** table.

spicy computes the measurements from the saved data rather than with the simulator's own `.meas`,
so the same lines give the same results on every simulator. The first word after `.meas` names the
analysis: `tran`, `ac` or `dc`.

- `NAME` is the name of the result, shown in the table and the messages. spicy does not check that
  names are unique.
- `MAX`, `MIN`, `AVG`, `RMS`, `PP` (peak to peak) and `INTEG` (integral) are taken over the
  expression. `FROM=x` and `TO=x` limit the range; without them the whole run is used.
- `FIND EXPR AT=x` gives the value of the expression at `x`, interpolated linearly between the two
  nearest points. `x` outside the run is an error.
- `TRIG` and `TARG` give the time from the trigger's crossing to the target's crossing. The crossing
  is at level `VAL=`. `RISE=n`, `FALL=n` or `CROSS=n` select the n-th rising edge, falling edge or
  crossing of either direction. With none given, the first crossing is used. The target is searched
  after the trigger.

`x` is the first vector of the analysis: time for `tran`, frequency for `ac`, the sweep for `dc`.

A complex result (for example `V(out)` in an AC analysis) is measured by its magnitude. Use `db()`
or `ph()` in `EXPR` to measure another quantity.

**Examples**

```
.meas tran vmax MAX V(out)
.meas tran vavg AVG V(out) FROM=5u TO=10u
.meas tran v2us FIND V(out) AT=2u
.meas tran tdelay TRIG V(in) VAL=0.5 RISE=1 TARG V(out) VAL=0.5 RISE=1
```

**Notes**

- Only `tran` is tested. `ac` and `dc` measurements are implemented but not verified.
- The `WHEN` and `DERIV` options of the simulator's own `.meas` are not supported.

---

### 2.3 `.step`

**Syntax**

```
.step param NAME list V1 V2 V3 …
.step param NAME START STOP INCREMENT
```

**Description**

`.step` runs the simulator once for each value of a parameter. The runs are labelled by value in
the viewer. spicy runs the steps itself, so the same line works on all three simulators. Each run
gets its own netlist, with the value set where the netlist defines the parameter:

- `.param NAME=value` (ngspice and Xyce), or `NAME=value` in `parameters` (VACASK), is changed in
  place.
- If the netlist does not define the parameter, spicy adds `.param NAME=value` before `.end`
  (ngspice and Xyce), or `parameters NAME=value` before the `control` block (VACASK).

`START STOP INCREMENT` includes `STOP` when the values reach it, and gives at most 500 values. A
`list` has no limit. A schematic has at most one `.step` line.

**Examples**

```
.param R=1k
.step param R list 1k 2.2k 4.7k
.step param C 1n 10n 1n
```

**Notes**

- Only parameter values are stepped. Device, model, temperature and data-table sweeps are not
  supported, although Xyce and VACASK can run them natively.
- Each value is a separate run, so a sweep of `n` values runs the simulator `n` times.

---

### 2.4 `.noise`

**Syntax**

```
.noise V(OUT) SOURCE dec|oct|lin POINTS FSTART FSTOP
```

**Description**

`.noise` runs a noise analysis. `OUT` is the output node, `SOURCE` is the input source to which
input-referred noise is related, and `POINTS` is the number of points per decade (`dec`), per
octave (`oct`) or in total (`lin`). `FSTART` and `FSTOP` give the frequency range.

For `lin`, VACASK counts intervals rather than points (`points=N` gives N+1 frequencies), so spicy
passes `POINTS - 1` to VACASK and all three simulators sweep the same frequencies. `dec`, `oct`
and `lin` have been tested on all three. With `oct 10` from 10 Hz to 1 MHz, which is not
a whole number of octaves, VACASK ends exactly at `FSTOP`, while ngspice and Xyce stop at the last
whole step before it, so VACASK gives one more point (168 against 167).

Results are noise spectral densities in V/√Hz, named the same on every simulator (section 4.1).
Show them with `.plot onoise_spectrum` or `.plot inoise_spectrum`.

**Examples**

```
.noise V(out) V1 dec 10 10 1Meg
.plot onoise_spectrum
```

**Notes**

- Xyce runs only its `.noise` analysis for a schematic. If the schematic also has `.tran`, `.ac`,
  `.dc` or `.op`, those are not run on Xyce, and spicy warns about it. Use ngspice or VACASK to run
  them together, or keep the noise analysis in its own schematic (as `examples/noise.edn` does).
- Xyce 7.10 rejects `V(out,ref)`, although its Reference Guide documents the form: it fails with
  `Netlist error: Cannot convert '' to integer for expression PTS_PER_SUMMARY`, with any reference
  node. spicy refuses the form for Xyce before the run, with `Xyce does not accept a reference node
  in the output`. Use `V(out)` on Xyce, or run `V(out,ref)` on ngspice.
- On VACASK, spicy translates one output node, `V(out)`, and refuses `V(out,ref)`. VACASK itself
  accepts a node pair, but spicy does not translate it yet.
- Input-referred noise is labelled V/√Hz and its total V. That holds for a voltage source as
  `SOURCE`; with a current source the values are in A/√Hz and A, but spicy still labels them V.

---

## 3 Trace expressions

Trace expressions are used in `.plot`, in `.meas`, in the waveform viewer and with `--trace`.

### 3.1 Vectors and probes

| Form | Meaning |
|---|---|
| `V(NODE)` | Voltage of a net, relative to ground |
| `V(A,B)` | Voltage of net A relative to net B |
| `I(PART)` | Current through a part (for example `I(R1)`) |
| `Ic(PART)` | Collector current of a transistor, or the current of a named pin of a part |
| `time`, `frequency` | The x axis of the analysis |
| `pi` | The constant π |
| `1.5k`, `10m`, `4.7u`, `1Meg` | Numbers with an engineering suffix |
| `1kohm`, `1us`, `1nF`, `2.5mA` | Numbers with a unit (section 3.4) |
| vector name | Any vector of the result, for example `onoise_spectrum` |

### 3.2 Arithmetic and comparison operators

| Operator | Meaning |
|---|---|
| `+` `-` `*` `/` `^` | Arithmetic. Unary `-` is allowed. |
| `<` `>` `<=` `>=` | Comparison. Gives 1 where the comparison holds, otherwise 0. |
| `==` `!=` | Equality and inequality, the same form of result. |

Comparisons give one value per point, so they can be used in arithmetic:
`(V(out) == 1) + (V(out) <= 1) * 10` gives 10, 11 and 0 where `V(out)` is 0, 1 and 2.

Comparisons use the real part of each value. On AC results, compare `mag(V(out))` or
`db(V(out))` instead of `V(out)`.

### 3.3 Functions

| Function | Result |
|---|---|
| `abs(x)`, `mag(x)` | Magnitude |
| `sqrt(x)`, `exp(x)`, `ln(x)`, `log10(x)` | Square root, exponential, natural and base-10 logarithm. `log(x)` is the same as `ln(x)`. |
| `db(x)` | 20·log₁₀ of the magnitude, in dB |
| `ph(x)`, `phase(x)` | Phase in degrees |
| `re(x)`, `im(x)` | Real and imaginary parts, also named `real(x)` and `imag(x)` |
| `sin(x)`, `cos(x)`, `tan(x)`, `atan(x)` | Trigonometric functions |
| `d(x)` | Derivative with respect to the x axis |
| `int(x)` | Running integral with respect to the x axis |
| `min(a, b)`, `max(a, b)` | Per point minimum or maximum. A one-point argument applies to all points. |
| `if(cond, a, b)` | Per point: `a` where `cond` is nonzero, otherwise `b`. A one-point argument applies to all points. On AC results, a complex `cond` counts as nonzero when either part is. |

`if` takes three arguments, `min` and `max` two, and every other function one. The number of
arguments is checked before the run. Examples:

```
if(V(out) > 0.5, V(out), 0)     shows V(out) only while it is above 0.5 V
if(V(out) > 0.5, 1, 0)          a 1/0 flag per point
```

Errors found before the run show a correct form, for example
`.plot "if(V(out), 1)": if() takes 3 arguments, not 2. Correct: if(V(out) > 0.5, 1, 0)`.
Errors found while evaluating, after the run, are shown as warnings in the viewer, and in the
`--trace` output on the command line.

### 3.4 Units

Every result has a unit, worked out from the expression:

| Expression | Unit |
|---|---|
| `V(out) * I(R1)` | W |
| `V(in,out) / I(R1)` | Ω |
| `I(R1) / V(out)` | S |
| `int(I(C1))` | C |
| `d(V(out))` in a transient analysis | V/s |
| `d(db(V(out)))` in an AC analysis | dB/Hz |
| `V(out)^2` | V² |
| `sqrt(onoise_spectrum^2)` | V/√Hz |
| `V(out) + 1`, `max(V(out), 0.5)`, `if(c, V(out), 0)` | V |
| `V(out) + I(R1)` | none: the units differ |
| `V(out) > 0.5`, `ln(V(out))`, `sin(V(out))` | none |
| `db(V(out))`, `ph(V(out))` | dB, ° |

- `*` and `/` combine units, and `^` and `sqrt` take powers of them. Units are kept as powers of V,
  A and s, so a result is written as the named unit when there is one: Ω, S, F, H, W, C, J, Hz.
- `+`, `-`, `min`, `max` and `if` keep the unit their operands share. A plain number takes the unit
  of the other operand, so `V(out) + 1` is in V. Operands in different units give no unit.
- `d()` divides by the unit of the x axis (s, Hz, or the sweep), and `int()` multiplies by it.
- dB and ° are outside this algebra. They are kept with a plain number, and written out over
  another unit, as in dB/Hz; otherwise they are dropped.

**Numbers with a unit**

A plain number has no unit, so `I(R1) * 1k` is in A. To give a number a unit, write the unit after
the SPICE scale factor: `I(R1) * 1kohm` is in V, and `d(V(out)) * 1us` is in V.

| Unit | Write |
|---|---|
| V, A, s | `1V`, `2.5mA`, `1us` |
| Ω | `1kohm` (the letter Ω cannot be typed in an expression) |
| F, H | `1nF`, `10uH` |
| Hz | `1Hz`, `1megHz` |
| W, C, J | `1mW`, `1nC`, `1J` |

SPICE reads the scale factor before the unit, and the expression does the same:

- `1F` is 1 femto with no unit, because `F` is the femto scale factor. A number in farads needs a
  scale factor before the `F`: `1nF`, `100uF`.
- `1MHz` is one milli hertz. Write `1megHz` for a megahertz.
- Letters that name no unit, as in `1kx`, give a plain number.

---

## 4 Results

### 4.1 Noise results

All three simulators give the same vector names for a noise analysis:

| Vector | Unit | Meaning |
|---|---|---|
| `frequency` | Hz | Frequency points |
| `onoise_spectrum` | V/√Hz | Output noise spectral density at `OUT` |
| `inoise_spectrum` | V/√Hz | Input-referred noise spectral density |

The plot is named **Noise Spectral Density Curves** on all three.

Simulators give their densities in different forms. Xyce writes power densities (V²/Hz) to a file
beside the netlist, `<netlist>_noise.dat`. VACASK writes power densities in its raw file. spicy
takes the square root of each, so the values are in V/√Hz. VACASK has no input-referred spectrum;
spicy computes it as the output spectrum divided by the square root of the gain (`|H|²`).

### 4.2 Integrated noise

The integrated noise is the RMS noise voltage over the frequency band. It is the square root of
the integral of the squared spectral density over the sweep (trapezoidal rule):

```
v(onoise_total) = sqrt( ∫ onoise_spectrum² df )
v(inoise_total) = sqrt( ∫ inoise_spectrum² df )
```

ngspice writes its own integrated noise. For Xyce and VACASK spicy computes it from the spectrum,
and the plot is named **Integrated Noise** on all three.

The result depends on the number of points the simulator writes. The integral is evaluated on the
sweep points only, so a coarse sweep gives a less accurate total. ngspice's own totals also change
with the sweep. For the RC example (`examples/noise.edn`, 1 kΩ and 1 nF, 10 Hz to 1 MHz):

| Sweep | Output total: ngspice / Xyce, VACASK | Input total: ngspice / Xyce, VACASK |
|---|---|---|
| `dec 5` | 1.921 µV / 1.957 µV | 4.872 µV / 4.071 µV |
| `dec 50` | 1.931 µV / 1.931 µV | 4.145 µV / 4.071 µV |
| `dec 1001` | 1.931 µV / 1.931 µV | 4.075 µV / 4.071 µV |

Use a fine sweep when the totals matter. The input noise of this circuit is flat at 4.071 nV/√Hz,
so 4.071 µV is its exact total over the band.

Integrated values are listed in the viewer's **Values** table, with one row per one-point result.

---

## 5 Command line

```
spicy --run <file> [--sim <id>] [--csv out.csv] [--points] [--edn | --json | --text]
spicy --run <file> --trace 'EXPR' [--trace 'EXPR' …]
```

- `--sim <id>` selects the simulator (`ngspice`, `xyce` or `vacask`).
- Output is EDN by default. `--json` gives JSON, and `--text` gives readable text.
- `--csv out.csv` writes the last analysis with traces to a CSV file. One-point results (operating
  point, integrated noise) are skipped.
- `--trace EXPR` gives the range and last value of a trace expression. It may be repeated.
- `--points` adds every value of every vector to the EDN or JSON output. Without it, each real
  vector gives its last value and its range, and each complex vector its last magnitude and
  phase. `--text` ignores it.

`--run` gives the `.meas` results and the plots of the run, so these work without the viewer.

---

## 6 Simulator support

| Feature | ngspice | Xyce | VACASK |
|---|---|---|---|
| `.plot` | Yes | Yes | Yes |
| `.meas` (`tran`) | Yes | Yes | Yes |
| `.step` (parameter values) | Yes | Yes | Yes |
| `.noise` (`onoise_spectrum`, `inoise_spectrum`) | Yes | Yes | Yes |
| Integrated noise | Simulator's own | Computed by spicy | Computed by spicy |
| `.noise` alongside other analyses | Yes | No: Xyce runs only `.noise` | Yes |
| `.noise` output node | `V(out)` or `V(out,ref)` | `V(out)` only (Xyce 7.10 rejects `V(out,ref)`) | `V(out)` only (spicy's translation) |
| `.noise` `lin` sweep | Yes | Yes | Yes (spicy converts the count) |

Parameters and numbers. LTspice's `.param Duty 0.46` (no `=`; ngspice, Xyce and VACASK stop at
it) is written `.param Duty=0.46`, and `.param Tsw 1/Fsw` as `.param Tsw={1/Fsw}`. `1µ` (as
LTspice writes it) is `1u` for every simulator: Xyce stops at `µ`. For VACASK, whose names are
case-sensitive where SPICE's are not, parameter names and expressions are lower case (`{D/FS}`
uses `.param Fs=500k`); the numbers of its parameters and expressions are real (VACASK's `1/2`
is integer division, 0; SPICE's is 0.5) and without units (`5V` is `5.0`, `100KHz` is
`100000.0`: VACASK stops at `5v`).

Part names. SPICE takes an element's kind from the first letter of its name; LTspice lets a part
have any name. A part whose name does not start with its kind's letter gets it in front in a
SPICE netlist, as LTspice does: a current source `Loadstep` is `ILoadstep` (as written it would
be an inductor). For VACASK, whose names are free, only a name that is one of its keywords gets
the letter: a resistor `Load` is `rload` (`load …` at the start of a line loads a device file).
`I(Loadstep)` and `I(Load)` in plots, probes and `.meas` find them either way.

LTspice's `.tran … startup` ramps the independent sources up from zero over the first 20 µs.
No simulator here has it: ngspice's `.option ramptime` needs a build option (`XSPICE_EXP`) its
usual builds lack, and is ignored without it; Xyce's `NOOP` and VACASK's `icmode="uic"` start
from zero with the sources at full value. spicy takes `startup` off the `.tran` line and writes
each source of the schematic with a DC value as `DC v PWL(0 0 20u v)`: the transient ramps up as
LTspice's, and an `.op` or `.ac` still sees `v`. Sources that change with time (`PULSE`, `SIN`,
`PWL` …) stay as written, with a warning when they are not 0 at t = 0; LTspice ramps those too.
Sources in subcircuits are not ramped, as in LTspice.

### 6.1 PSpice and LTspice models

Vendor models are written for PSpice or LTspice. spicy runs ngspice in its compatibility mode
for the whole netlist when the netlist (or a file it `.include`s) needs one, and says so in the
netlist's second line (`* LTspice models (…): spicy runs ngspice -D ngbehavior=lta`):

| The netlist has | ngspice mode |
|---|---|
| PSpice: `VSWITCH` / `ISWITCH` models, `TEMP` in expressions, `VALUE` / `TABLE` / `LAPLACE` / `FREQ` sources, `if()`, `int()` | `psa` |
| LTspice: `mfg=` or a text `type=` in a model, an ideal diode, `uplim()`, `dnlim()`, `uplim_tanh()`, `dnlim_tanh()` | `lta` |
| Both | `ltpsa` |

A simulator command in `settings.edn` that sets `ngbehavior` itself is left as it is.

What each simulator runs (ngspice 47, Xyce 7.10, VACASK 0.3.4):

| Model feature | ngspice | Xyce | VACASK |
|---|---|---|---|
| `mfg=`, `type=`, ratings (`Iave`, `Vpk`, `Vds`, `Ron`, `Qg`, `Vceo`, `Icrating` …) | Yes (`lta`) | Yes (ignored) | Yes (left out, as any parameter a VACASK device does not have) |
| LTspice ideal diode: `D(Ron= Roff= Vfwd= …)` | Yes (`lta`: ngspice's `sidiode`) | No: a plain diode, a wrong result (warning) | No: a plain diode, a wrong result (warning) |
| `VDMOS` | Yes | No (error before the run) | Yes |
| `uplim()`, `dnlim()`, `uplim_tanh()`, `dnlim_tanh()` | Yes (`lta`) | No (error) | No B sources (error) |
| `buf()`, `inv()`, `absdelay()`, `delay()`, `idt()`, `idtmod()`, `hypot()`, `round()`, `rand()`, `random()`, `white()` | No (error) | No (error) | No B sources (error) |
| `sdt()`, `table()`, `atan2()` | No (error) | Yes | No B sources (error) |
| `u()` | Yes | No (error) | No B sources (error) |
| `if()`, `int()` | Yes (`psa`) | Yes | No B sources (error) |

The errors and warnings come before the run, and only for what the circuit uses: a library's
other subcircuits and models are not checked, as no simulator reads them. A function defined by a
`.func` (in the subcircuit, or outside every subcircuit) is the `.func`'s. Where there is a simple
equivalent the error gives it: `buf(x)` is `x>0.5 ? 1 : 0`, `inv(x)` is `x>0.5 ? 0 : 1`,
`hypot(x,y)` is `sqrt(x*x+y*y)`.

`spicy --check-model <file>` and the import report list the ideal diodes, VDMOS models and
LTspice functions of a library under "To check yourself".

LTspice's instance parameters of a part (its `SpiceLine`: `10u Rser=5m Lser=1n`) are read by no
other simulator. An imported `.asc` file or SPICE netlist gives them to the part's non-ideal
values (in the part's dialog), which spicy writes as elements around the part:

| LTspice | Capacitor | Inductor | Voltage source | Resistor |
|---|---|---|---|---|
| `Rser` | ESR | DC resistance | Internal resistance | |
| `Lser` | ESL | | | |
| `Rpar` | Leakage resistance | Core loss resistance | | |
| `Cpar` | left out (warning) | Winding capacitance | left out (warning) | |
| `RLshunt` | left out (warning) | | | |
| `V`, `Ipk`, `pwr` | Voltage rating | Current rating (`Ipk`) | | Power rating (`pwr`), `tol` its tolerance |
| `mfg`, `pn`, `type`, `Irms` | kept with the part, not simulated | | | |

LTspice puts a capacitor's `Rpar` across the whole part; spicy's leakage resistance is across the
capacitance alone, a difference of `Rser`/`Rpar`. A parameter set to 0 is left out (ideal).

---

## 7 Examples

`examples/` has one example per feature, each showing every form the feature takes. Comments in
the schematics explain each line. All five run on ngspice, Xyce and VACASK.

| Example | Shows |
|---|---|
| `plot.edn` | `.plot`: one trace, several on one line, `V(a,b)`, currents, expressions |
| `expressions.edn` | Comparisons, `if()`, `min`, `max`, `abs`, `sqrt`, `d()` and `int()` |
| `meas.edn` | Every `.meas` form: `MAX`, `MIN`, `AVG`, `RMS`, `PP`, `INTEG` with and without `FROM`/`TO`, `FIND`, and `TRIG`/`TARG` with `RISE`, `FALL` and `CROSS` |
| `step.edn` | `.step param` with a list; the start/stop/increment form is in a comment |
| `noise.edn` | `.noise` with both spectra; `oct`, `lin` and `V(out,ref)` are in comments |

The transient examples use an RC low-pass of 1 kΩ and 1 nF (time constant 1 µs) driven by a 1 V
pulse, so the measurements can be checked by hand: the 10–90% rise time is ln 9 × 1 µs = 2.197 µs,
and the 0.5 V delay is ln 2 × 1 µs = 693 ns.

```sh
spicy examples/meas.edn
spicy --run examples/noise.edn --sim xyce --trace 'onoise_spectrum'
```
