#!/usr/bin/env python3
# Writes src/vacask_params.odin: the model parameters of VACASK's SPICE devices, from the device
# sources VACASK ships (src/vacask/devices/spice in a release, devices/spice in its repository).
#
#   python3 tools/vacask_params.py <vacask>/src/vacask/devices/spice > src/vacask_params.odin
import re,sys
D=sys.argv[1]
mods=["bjt","jfet1","jfet2","vdmos","mos1","mos2","mos3","mos6","mos9"]
out=[]
for m in mods:
    t=open(f"{D}/{m}.va").read()
    t=re.sub(r'//.*','',t)
    model=set(); inst=set()
    for a,typ,name in re.findall(r'(\(\*[^*]*\*\))?\s*parameter\s+(real|integer|string)\s+([A-Za-z_]\w*)',t):
        (inst if 'type = "instance"' in (a or '') or 'type="instance"' in (a or '') else model).add(name.lower())
    for al,tg in re.findall(r'aliasparam\s+([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)',t):
        if tg.lower() in model: model.add(al.lower())
    mn=re.search(r'module\s+(\w+)',t).group(1)
    out.append((mn,sorted(model)))
print("package spicy\n")
print("// The model parameters of VACASK's SPICE devices, aliases included (generated from the")
print("// device sources of VACASK 0.3.4, devices/spice/*.va, by tools/vacask_params.py: the")
print("// parameters that are not instance parameters). A model card's parameter that is not in")
print("// its device's list is left out of the VACASK netlist, as ngspice leaves it out: VACASK")
print("// would stop at it.\n")
for mn,ps in out:
    print('@(private = "file")')
    print(f'{mn.upper()}_PARAMS := []string{{' + ", ".join(f'"{p}"' for p in ps) + "}\n")
print("vacask_model_params :: proc(module: string) -> []string {")
print("\tswitch module {")
for mn,ps in out:
    print(f'\tcase "{mn}": return {mn.upper()}_PARAMS')
print("\t}")
print("\treturn nil")
print("}")
