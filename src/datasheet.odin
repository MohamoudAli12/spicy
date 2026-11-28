package spicy

import "core:log"
import "core:os"
import "core:strings"

// Datasheets. A part has its own (its "datasheet" field, saved in the schematic) or else its
// model's (model-info.edn, set in the model table), so a datasheet given once to a model
// serves every part that uses it. Either is a web link or a file. A file in the schematic's
// folder or below is kept relative to it: the folder can move with its datasheets.
// Opening one goes to the system's default program: a PDF viewer for a file, the browser
// for a link.

DATASHEET_EXTS := []string{"pdf", "html", "htm", "djvu"}

datasheet_is_url :: proc(s: string) -> bool {
	l := lower(strings.trim_space(s))
	return strings.has_prefix(l, "http://") || strings.has_prefix(l, "https://") || strings.has_prefix(l, "www.")
}

// What a datasheet opens: a link as it is ("www." gets https://), else the file's path, from
// base_dir when relative ("~" is the home folder, a file:// link is its path). "" for none.
datasheet_target :: proc(ds, base_dir: string) -> (target: string, is_url: bool) {
	t := clean_path(ds)
	if len(t) == 0 do return "", false
	l := lower(t)
	if strings.has_prefix(l, "www.") do return tcat("https://", t), true
	if datasheet_is_url(t) do return t, true
	if strings.has_prefix(l, "file://") {
		t = percent_decode(t[len("file://"):])
		if len(t) == 0 do return "", false
	}
	if t == "~" || strings.has_prefix(t, "~/") || strings.has_prefix(t, "~\\") do t = tcat(home_dir(), t[1:])
	if !is_abs(t) && len(base_dir) > 0 do t = path_join(base_dir, t)
	when ODIN_OS == .Windows {
		// a path saved with "/" (datasheet_store), for Explorer
		t, _ = strings.replace_all(t, "/", "\\", context.temp_allocator)
	}
	return t, false
}

// The datasheet a part opens: its own, else its model's (from_model).
comp_datasheet :: proc(c: ^Comp) -> (ds: string, from_model: bool) {
	if own := strings.trim_space(comp_attr(c, "datasheet")); len(own) > 0 do return own, false
	if f := strings.fields(c.value, context.temp_allocator); len(f) > 0 {
		if m := model_datasheet(f[0]); len(m) > 0 do return m, true
	}
	return "", false
}

// The datasheet given to a model in the model table, "" for none.
model_datasheet :: proc(name: string) -> string {
	key := lower(name)
	for &r in catalog_rows() do if r.key == key do return r.sheet
	return ""
}

// Opens a part's datasheet (its own, else its model's); a status message says why not.
comp_open_datasheet :: proc(d: ^Doc, ci: int) {
	c := &d.sch.comps[ci]
	ds, from_model := comp_datasheet(c)
	if len(ds) == 0 {
		status(tcat(c.ref, " has no datasheet: give it one in its editor (Datasheet), or its model one in the model table"), true)
		return
	}
	// the part's own file is from the schematic's folder; a model's is a full path
	if e := datasheet_open(ds, "" if from_model else dir_of(d.path)); len(e) > 0 do status(tcat(c.ref, ": ", e), true)
	else do status(tcat(c.ref, ": opening ", ds))
}

// Opens it with the system's program: "" when started, else why not (a file that is not
// there, no program).
datasheet_open :: proc(ds, base_dir: string) -> string {
	target, url := datasheet_target(ds, base_dir)
	if len(target) == 0 do return "no datasheet: give one in the part's editor (Datasheet) or the model table"
	if !url && !file_exists(target) do return tcat("datasheet not found: ", target)
	// SPICY_OPEN_WITH: another program (the tests use one that notes what it was given)
	if with := os.get_env("SPICY_OPEN_WITH", context.temp_allocator); len(with) > 0 {
		command := []string{with, target}
		when ODIN_OS == .Windows {
			// a batch file runs only through the command interpreter (CreateProcess's documentation)
			// (its path with backslashes: cmd reads a "/" in it as an option)
			if e := file_ext_lower(with); e == "cmd" || e == "bat" {
				w, _ := strings.replace_all(with, "/", "\\", context.temp_allocator)
				command = {"cmd.exe", "/c", w, target}
			}
		}
		if _, err := os.process_start({command = command}); err != nil do return tcat("cannot run ", with)
	} else if !open_external(target) {
		return tcat("cannot open ", target)
	}
	log.infof("opening the datasheet %s", target)
	return ""
}

// A datasheet as it is saved: a file in base_dir or below relative to it (with "/"), else as
// given.
datasheet_store :: proc(ds, base_dir: string) -> string {
	t := clean_path(ds)
	if len(t) == 0 || len(base_dir) == 0 || datasheet_is_url(t) || !is_abs(t) do return t
	b := strings.trim_right(base_dir, "/\\")
	if len(t) > len(b) + 1 && t[:len(b)] == b && (t[len(b)] == '/' || t[len(b)] == '\\') {
		// with "/" (Windows takes it too): the schematic opens on any system
		rel, _ := strings.replace_all(t[len(b) + 1:], "\\", "/", context.temp_allocator)
		return rel
	}
	return t
}

// The file picker for a datasheet, from the part's editor or the model table (back): it
// starts in the folder of the datasheet now (current), and goes back with the file picked.
datasheet_browse :: proc(back: Dialog_Kind, current, base_dir: string) {
	dl := &app.dlg
	dl.sheet_back = back
	set_str(&dl.sheet_start, dir_name(current) if len(current) > 0 else base_dir)
	dialog_open(.Pick_Datasheet)
	if len(current) > 0 && dir_name(current) == dl.dir do set_str(&dl.name, base_name(current))
}

// Back from the picker: the file picked ("" for none) into the field of the dialog it came from.
datasheet_back :: proc(path: string) {
	dl := &app.dlg
	#partial switch dl.sheet_back {
	case .Model_Table:
		if len(path) > 0 do model_table_set_sheet(path)
	case .Part_Edit:
		if len(path) > 0 do set_str(&dl.datasheet, datasheet_store(path, dir_of(doc().path)))
	}
	dl.kind = dl.sheet_back
	dl.first_frame = false
	ui.focus = 0
}

// "%20" and the like in a file:// link.
@(private = "file")
percent_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	b := strings.builder_make(context.temp_allocator)
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a' + 10)
		case 'A' ..= 'F': return int(c - 'A' + 10)
		}
		return -1
	}
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0 {
			strings.write_byte(&b, u8(hex(s[i + 1]) * 16 + hex(s[i + 2])))
			i += 2
		} else do strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}
