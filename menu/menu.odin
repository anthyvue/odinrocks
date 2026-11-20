package menu

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../config"
import "../pedals"
import "../songcache"
import "../songsterr"
import "../ui"
import rl "vendor:raylib"

MARGIN :: 36
LIST_TOP :: 150
LIST_ROW_HEIGHT :: 84
GUITARS_TOP :: 216
SETTINGS_TOP :: 144
SETTING_ROW_HEIGHT :: 72
CONTROL_HEIGHT :: 51
// The space above and below the control of a setting row.
ROW_PADDING :: (SETTING_ROW_HEIGHT - CONTROL_HEIGHT) / 2
VALUE_X :: 540
PAUSE_BUTTON_WIDTH :: 300
PAUSE_ROW_HEIGHT :: 72
// Dims the frozen highway under the pause menu.
PAUSE_SHADE :: rl.Color{24, 24, 28, 210}
NO_AUDIO_TEXT :: "The guitar input is closed. Settings chooses the driver and says why."
STRING_RADIO_WIDTH :: 150
METER_TOP :: 342
METER_WIDTH :: 1200
METER_HEIGHT :: 96
TUNER_BUTTONS_TOP :: METER_TOP + METER_HEIGHT + 132
// The meter spans this many cents on each side of the target. The needle stops at the ends.
METER_CENTS :: 50
// A string this close to its note, in cents, is in tune.
IN_TUNE_CENTS :: 3
IN_TUNE :: rl.Color{110, 200, 120, 255}

@(rodata)
NOTE_LETTERS := [12]string{"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

@(rodata)
MODE_LABELS := [songcache.Sync_Mode]string {
	.Basic    = "basic",
	.Advanced = "advanced",
}

// A basic sync plays from the source alone, so deleting it deletes the song.
@(rodata)
DELETE_LABELS := [songcache.Sync_Mode]string {
	.Basic    = "Delete song",
	.Advanced = "Delete sync",
}

// What the library screen keeps between visits: the typed song id, the sync mode checkbox, and the scroll of the list.
Library :: struct {
	song_id:       strings.Builder,
	advanced_sync: bool,
	scroll:        int,
}

// What the user asked each menu for in one frame. An action union is nil when the user asked for nothing.
Open_Settings :: struct {}
Download :: struct {
	song_id:    int,
	mode:       songcache.Sync_Mode,
	redownload: bool,
}
Open_Sync :: struct {
	sync: songcache.Cached_Sync,
}
Library_Action :: union {
	Open_Settings,
	Download,
	Open_Sync,
}

Close_Sync_Menu :: struct {}
Delete_Sync :: struct {}
Play_Guitar :: struct {
	guitar: songsterr.Guitar_Track,
}
Sync_Menu_Action :: union {
	Close_Sync_Menu,
	Delete_Sync,
	Play_Guitar,
}

Close_Tuner :: struct {}
// Play the guitar in its own tuning, which the player's guitar is now tuned to.
Play_Tuned :: struct {}
// Play the guitar in the player's tuning, lowered to the guitar's tuning by the drop.
Play_With_Drop :: struct {
	semitones: int,
}
Tuner_Action :: union {
	Close_Tuner,
	Play_Tuned,
	Play_With_Drop,
}

Close_Settings :: struct {}
Open_Tone :: struct {}
Quit_Game :: struct {}
Settings_Action :: union {
	Close_Settings,
	Open_Tone,
	Quit_Game,
}

Resume :: struct {}
Restart :: struct {}
Quit_Song :: struct {}
Pause_Action :: union {
	Resume,
	Open_Tone,
	Restart,
	Quit_Song,
}

// Draws the library screen and applies this frame's input to library. Returns what the user asked for this frame.
// A download_error shows under the download row, in red.
show_library :: proc(library: ^Library, syncs: []songcache.Cached_Sync, download_error: Maybe(string)) -> (action: Library_Action) {
	rl.ClearBackground(ui.BACKGROUND)
	width, height := ui.size()
	if ui.button({width - MARGIN - 198, 27, 198, 54}, "Settings") do action = Open_Settings{}

	download_row := ui.Row{MARGIN, 27, 54}
	ui.edit_digits(ui.take(&download_row, 630), &library.song_id, "songsterr song id", 16)
	ui.checkbox(ui.take(&download_row, 300), "Advanced sync", &library.advanced_sync)
	mode := songcache.Sync_Mode.Advanced if library.advanced_sync else .Basic
	id, id_ok := strconv.parse_int(strings.to_string(library.song_id))
	cached := id_ok && is_cached(syncs, id, mode)
	clicked := ui.button(ui.take(&download_row, 270), "Redownload" if cached else "Download", id_ok)
	if id_ok && (clicked || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)) do action = Download{id, mode, cached}
	if message, failed := download_error.?; failed do ui.draw_text(message, MARGIN, 99, .Small, ui.ERROR)

	view := ui.Rect{0, LIST_TOP, width, height - LIST_TOP}
	ui.scroll(view, &library.scroll, len(syncs) * LIST_ROW_HEIGHT)
	ui.begin_clip(view)
	defer ui.end_clip()
	if len(syncs) == 0 do ui.draw_text("No completed syncs", MARGIN, LIST_TOP + 12, .Body, ui.DIM)
	for sync, index in syncs {
		rect := ui.Rect{0, LIST_TOP + index * LIST_ROW_HEIGHT - library.scroll, view.w, LIST_ROW_HEIGHT}
		if ui.row_button(rect, view) do action = Open_Sync{sync}
		ui.draw_text_in_row(sync.heading, MARGIN, rect, .Body, ui.TEXT)
	}
	return
}

// Draws the menu of one song in one sync mode and applies the mouse wheel to scroll. Returns what the user asked for this frame.
// No guitar plays or tunes until audio_open, the guitar input. Until then the menu sends the player to Settings.
show_sync_menu :: proc(sync: songcache.Cached_Sync, scroll: ^int, audio_open: bool) -> (action: Sync_Menu_Action) {
	rl.ClearBackground(ui.BACKGROUND)
	width, height := ui.size()
	ui.draw_text(sync.heading, MARGIN, 33, .Title, ui.TEXT)
	ui.draw_text(fmt.tprintf("%s sync mode", MODE_LABELS[sync.mode]), MARGIN, 87, .Body, ui.GOLD)
	if ui.is_back_pressed() do action = Close_Sync_Menu{}
	buttons := ui.Row{MARGIN, 138, 54}
	delete_button := ui.take(&buttons, 270)
	if ui.button(delete_button, DELETE_LABELS[sync.mode]) do action = Delete_Sync{}
	if !audio_open do ui.draw_text_in_row(NO_AUDIO_TEXT, buttons.x, delete_button, .Small, ui.ERROR)

	view := ui.Rect{0, GUITARS_TOP, width, height - GUITARS_TOP}
	ui.scroll(view, scroll, len(sync.guitars) * LIST_ROW_HEIGHT)
	ui.begin_clip(view)
	defer ui.end_clip()
	for guitar, index in sync.guitars {
		rect := ui.Rect{0, GUITARS_TOP + index * LIST_ROW_HEIGHT - scroll^, view.w, LIST_ROW_HEIGHT}
		if audio_open && ui.row_button(rect, view) do action = Play_Guitar{guitar}
		ui.draw_text(guitar.name, MARGIN, rect.y + 12, .Body, ui.TEXT)
		ui.draw_text(tuning_label(guitar.tuning), MARGIN, rect.y + 45, .Small, ui.GOLD)
	}
	return
}

// Draws the tuner that tunes the player's guitar from guitar_tuning to the tuning of guitar, a guitar of the song heading, with the needle at needle cents.
// string_index is the string being tuned, as an index into guitar.tuning. A click on a string, Left, and Right change it.
// The strings run from the low string on the left. Returns what the player asked for this frame.
show_tuner :: proc(heading: string, guitar: songsterr.Guitar_Track, guitar_tuning: []int, string_index: ^int, needle: Maybe(f32)) -> (action: Tuner_Action) {
	rl.ClearBackground(ui.BACKGROUND)
	ui.draw_text(heading, MARGIN, 33, .Title, ui.TEXT)
	ui.draw_text(guitar.name, MARGIN, 87, .Body, ui.GOLD)
	ui.draw_text(fmt.tprintf("Your guitar: %s", tuning_label(guitar_tuning)), MARGIN, 138, .Body, ui.TEXT)
	ui.draw_text("Tune each string of the song, then press Play. Click a string or press Left and Right. Esc returns.", MARGIN, 186, .Small, ui.DIM)

	// The frame shows the string chosen before this frame's input, so one radio is selected.
	chosen := string_index^
	radios := ui.Row{MARGIN, 234, CONTROL_HEIGHT}
	#reverse for midi, index in guitar.tuning {
		if ui.radio(ui.take(&radios, STRING_RADIO_WIDTH), note_name(midi), index == string_index^) do chosen = index
	}
	if rl.IsKeyPressed(.LEFT) && string_index^ + 1 < len(guitar.tuning) do chosen = string_index^ + 1
	if rl.IsKeyPressed(.RIGHT) && string_index^ > 0 do chosen = string_index^ - 1
	draw_meter(needle)
	draw_tuning_advice(note_name(guitar.tuning[string_index^]), needle)
	string_index^ = chosen

	buttons := ui.Row{MARGIN, TUNER_BUTTONS_TOP, CONTROL_HEIGHT}
	if ui.button(ui.take(&buttons, 270), "Play") do action = Play_Tuned{}
	if drop, droppable := pedals.drop_for_tuning(guitar_tuning, guitar.tuning); droppable {
		label := fmt.tprintf("Play with drop %d st", drop)
		if ui.button(ui.take(&buttons, 450), label) do action = Play_With_Drop{drop}
	}
	if ui.is_back_pressed() do action = Close_Tuner{}
	return
}

// Draws a scale of METER_CENTS each side of the target, with the in-tune band in the middle, and the needle on it once a note is heard.
@(private)
draw_meter :: proc(needle: Maybe(f32)) {
	meter := ui.Rect{MARGIN, METER_TOP, METER_WIDTH, METER_HEIGHT}
	center := meter.x + meter.w / 2
	units_per_cent := f32(meter.w / 2) / METER_CENTS
	in_tune_half_width := int(IN_TUNE_CENTS * units_per_cent)
	ui.draw_rect(meter, ui.FIELD)
	ui.draw_rect({center - in_tune_half_width, meter.y, 2 * in_tune_half_width, meter.h}, ui.HOVER)
	for cents := -METER_CENTS; cents <= METER_CENTS; cents += 10 {
		ui.draw_rect({center + int(f32(cents) * units_per_cent) - 1, meter.y, 2, meter.h}, ui.DIM)
	}
	ui.draw_rect({center - 2, meter.y, 4, meter.h}, ui.GOLD)

	cents, heard := needle.?
	if !heard do return
	x := center + int(clamp(cents, -METER_CENTS, METER_CENTS) * units_per_cent)
	color := IN_TUNE if abs(cents) <= IN_TUNE_CENTS else ui.ERROR
	ui.draw_rect({x - 5, meter.y - 12, 10, meter.h + 24}, color)
}

// Draws under the meter which way to turn the peg for target, a note name.
@(private)
draw_tuning_advice :: proc(target: string, needle: Maybe(f32)) {
	y := METER_TOP + METER_HEIGHT + 36
	cents, heard := needle.?
	switch {
	case !heard:
		ui.draw_text(fmt.tprintf("Play the %s string", target), MARGIN, y, .Title, ui.DIM)
	case abs(cents) <= IN_TUNE_CENTS:
		ui.draw_text(fmt.tprintf("%s is in tune", target), MARGIN, y, .Title, IN_TUNE)
	case:
		direction := "up" if cents < 0 else "down"
		ui.draw_text(fmt.tprintf("%+.0f cents, tune %s to %s", cents, direction, target), MARGIN, y, .Title, ui.TEXT)
	}
}

// The open strings of tuning, from the low string, such as "D2 A2 D3 G3 B3 E4".
@(private)
tuning_label :: proc(tuning: []int) -> string {
	names := make([]string, len(tuning), context.temp_allocator)
	for midi, index in tuning do names[len(tuning) - 1 - index] = note_name(midi)
	return strings.join(names, " ", context.temp_allocator)
}

// The name of MIDI note midi with its octave, such as "E2".
@(private)
note_name :: proc(midi: int) -> string {
	return fmt.tprintf("%s%d", NOTE_LETTERS[midi % 12], midi / 12 - 1)
}

// Shades the frame drawn so far and draws the pause menu over it. Returns what the user asked for this frame. Escape resumes.
show_pause_menu :: proc() -> (action: Pause_Action) {
	width, height := ui.size()
	ui.draw_rect({0, 0, width, height}, PAUSE_SHADE)
	x := (width - PAUSE_BUTTON_WIDTH) / 2
	y := height / 2 - 2 * PAUSE_ROW_HEIGHT
	ui.draw_text("Paused", x, y, .Title, ui.TEXT)
	if ui.button({x, y + PAUSE_ROW_HEIGHT, PAUSE_BUTTON_WIDTH, CONTROL_HEIGHT}, "Resume") do action = Resume{}
	if ui.button({x, y + 2 * PAUSE_ROW_HEIGHT, PAUSE_BUTTON_WIDTH, CONTROL_HEIGHT}, "Tone") do action = Open_Tone{}
	if ui.button({x, y + 3 * PAUSE_ROW_HEIGHT, PAUSE_BUTTON_WIDTH, CONTROL_HEIGHT}, "Restart") do action = Restart{}
	if ui.button({x, y + 4 * PAUSE_ROW_HEIGHT, PAUSE_BUTTON_WIDTH, CONTROL_HEIGHT}, "Quit song") do action = Quit_Song{}
	if ui.is_back_pressed() do action = Resume{}
	return
}

draw_missing_tools :: proc(missing_tools: []string) {
	rl.ClearBackground(ui.BACKGROUND)
	ui.draw_text("odinrocks cannot start. These programs are not on PATH:", MARGIN, 33, .Title, ui.ERROR)
	y := 102
	for name in missing_tools {
		ui.draw_text(name, MARGIN, y, .Body, ui.TEXT)
		y += 42
	}
	ui.draw_text("Install them, put them on PATH, and start odinrocks again.", MARGIN, y + 24, .Small, ui.DIM)
}

draw_downloading :: proc(download: Download) {
	rl.ClearBackground(ui.BACKGROUND)
	verb := "Redownloading" if download.redownload else "Downloading"
	ui.draw_text(fmt.tprintf("%s %d %s", verb, download.song_id, MODE_LABELS[download.mode]), MARGIN, 72, .Title, ui.TEXT)
	ui.draw_text("The console shows the progress. Closing the window waits until the download ends.", MARGIN, 132, .Small, ui.DIM)
}

// Draws the settings screen and applies this frame's clicks to settings. Returns what the user asked for this frame.
// drivers are the ASIO drivers the machine has, to choose the guitar input from. audio_failure says why the guitar input did not open, if it did not.
edit_settings :: proc(settings: ^config.Settings, drivers: []string, audio_failure: Maybe(string)) -> (action: Settings_Action) {
	rl.ClearBackground(ui.BACKGROUND)
	width, _ := ui.size()
	ui.draw_text("Settings", MARGIN, 33, .Title, ui.TEXT)
	if failure, failed := audio_failure.?; failed do ui.draw_text(fmt.tprintf("The guitar input did not open: %s", failure), MARGIN, 87, .Small, ui.ERROR)
	else do ui.draw_text("Click either side of a value to change it. Shift steps by 5. Esc returns.", MARGIN, 87, .Small, ui.DIM)
	if ui.button({width - MARGIN - 198, 27, 198, 54}, "Tone") do action = Open_Tone{}

	y := SETTINGS_TOP
	ui.step_number(draw_setting_name(&y, "A/V offset"), fmt.tprintf("%+d ms", settings.av_offset_ms), &settings.av_offset_ms, -config.MAX_AV_OFFSET_MS, config.MAX_AV_OFFSET_MS, 10)
	ui.step_number(draw_setting_name(&y, "Guitar gain"), gain_label(settings.guitar_gain_tenths), &settings.guitar_gain_tenths, 0, config.MAX_GAIN_TENTHS)
	ui.step_number(draw_setting_name(&y, "Song gain"), gain_label(settings.song_gain_tenths), &settings.song_gain_tenths, 0, config.MAX_GAIN_TENTHS)
	ui.step_number(draw_setting_name(&y, "Guitar channel index"), fmt.tprint(settings.guitar_channel), &settings.guitar_channel, 0, 63)
	edit_asio_driver(settings, drivers, &y)
	ui.toggle(draw_setting_name(&y, "Hit flash"), &settings.draw_hit_flash)
	ui.toggle(draw_setting_name(&y, "Fullscreen (F11)"), &settings.borderless)
	if ui.button({MARGIN, y, 270, CONTROL_HEIGHT}, "Quit game") do action = Quit_Game{}
	if ui.is_back_pressed() do action = Close_Settings{}
	return
}

// Draws the tone screen and applies this frame's clicks to settings. rigs are the rigs to choose from, and input_peak is the level of the guitar. closed is true when Escape leaves.
show_tone :: proc(settings: ^config.Settings, rigs: []string, input_peak: f32) -> (closed: bool) {
	rl.ClearBackground(ui.BACKGROUND)
	return edit_tone(settings, rigs, input_peak)
}

// Shades the frame drawn so far and draws the tone editor over it, like show_tone.
show_tone_overlay :: proc(settings: ^config.Settings, rigs: []string, input_peak: f32) -> (closed: bool) {
	width, height := ui.size()
	ui.draw_rect({0, 0, width, height}, PAUSE_SHADE)
	return edit_tone(settings, rigs, input_peak)
}

// Draws the rig, the levels, and the pedals of settings, and applies this frame's clicks to them. closed is true when Escape leaves.
@(private)
edit_tone :: proc(settings: ^config.Settings, rigs: []string, input_peak: f32) -> (closed: bool) {
	ui.draw_text("Tone", MARGIN, 33, .Title, ui.TEXT)
	ui.draw_text("Play your guitar: every change is heard at once. If every rig sounds like fuzz, lower Input until a hard strum peaks near -12 dB. Esc returns.", MARGIN, 87, .Small, ui.DIM)

	y := SETTINGS_TOP
	edit_rig(&settings.rig, rigs, &y)
	knobs := &settings.pedals
	peak := "silent" if input_peak <= 0 else fmt.tprintf("%.0f dB", 20 * math.log10(input_peak))
	input := draw_setting_name(&y, "Input")
	input.w = 600
	ui.step_number(input, fmt.tprintf("%+d dB, peak %s", knobs.input_db, peak), &knobs.input_db, pedals.INPUT_DB.low, pedals.INPUT_DB.high)
	ui.step_number(draw_setting_name(&y, "Guitar gain"), gain_label(settings.guitar_gain_tenths), &settings.guitar_gain_tenths, 0, config.MAX_GAIN_TENTHS)
	step_knob(&y, "Gate", "%d dB", &knobs.gate_db, pedals.GATE_DB)
	step_knob(&y, "Delay time", "%d ms", &knobs.delay_ms, pedals.DELAY_MS, 10)
	step_knob(&y, "Delay feedback", "%d%%", &knobs.delay_feedback_percent, pedals.DELAY_FEEDBACK_PERCENT)
	step_knob(&y, "Delay level", "%d%%", &knobs.delay_level_percent, pedals.PERCENT)
	step_knob(&y, "Reverb size", "%d%%", &knobs.reverb_size_percent, pedals.PERCENT)
	step_knob(&y, "Reverb damping", "%d%%", &knobs.reverb_damping_percent, pedals.PERCENT)
	step_knob(&y, "Reverb level", "%d%%", &knobs.reverb_level_percent, pedals.PERCENT)
	if ui.button(draw_setting_name(&y, "Pedals"), "Defaults") do knobs^ = pedals.DEFAULT_KNOBS
	return ui.is_back_pressed()
}

// Steps rig through rigs, by file name, in the row at y, and moves y to the next row.
@(private)
edit_rig :: proc(rig: ^string, rigs: []string, y: ^int) {
	index, _ := slice.linear_search(rigs, rig^)
	stepped := index
	rect := draw_setting_name(y, "Rig")
	rect.w = 750
	ui.step_number(rect, filepath.stem(rig^), &stepped, 0, len(rigs) - 1)
	if stepped == index do return
	delete(rig^)
	rig^ = strings.clone(rigs[stepped])
}

// Draws a row named name at y that steps value inside range, and moves y to the next row. format labels it with value.
@(private)
step_knob :: proc(y: ^int, name, format: string, value: ^int, range: pedals.Range, unit := 1) {
	ui.step_number(draw_setting_name(y, name), fmt.tprintf(format, value^), value, range.low, range.high, unit)
}

// Draws one radio per driver, from the row of the name down, and moves y below them. A click on another driver chooses it.
@(private)
edit_asio_driver :: proc(settings: ^config.Settings, drivers: []string, y: ^int) {
	top := y^
	name_row := draw_setting_name(y, "ASIO driver")
	if len(drivers) == 0 do ui.draw_text_in_row("No ASIO driver is installed", VALUE_X, name_row, .Body, ui.ERROR)
	for driver, index in drivers {
		rect := ui.Rect{VALUE_X, top + index * SETTING_ROW_HEIGHT, 600, CONTROL_HEIGHT}
		if ui.radio(rect, driver, driver == settings.asio_driver) && driver != settings.asio_driver {
			delete(settings.asio_driver)
			settings.asio_driver = strings.clone(driver)
		}
	}
	y^ = top + max(len(drivers), 1) * SETTING_ROW_HEIGHT
}

// Draws name at y, moves y to the next row, and returns where that row's control goes.
@(private)
draw_setting_name :: proc(y: ^int, name: string) -> (control: ui.Rect) {
	control = {VALUE_X, y^, 450, CONTROL_HEIGHT}
	ui.draw_text_in_row(name, MARGIN, control, .Body, ui.TEXT)
	y^ += SETTING_ROW_HEIGHT
	return
}

@(private)
gain_label :: proc(tenths: int) -> string {
	return fmt.tprintf("%.1f", config.gain_from_tenths(tenths))
}

@(private)
is_cached :: proc(syncs: []songcache.Cached_Sync, song_id: int, mode: songcache.Sync_Mode) -> bool {
	for sync in syncs do if sync.song_id == song_id && sync.mode == mode do return true
	return false
}
