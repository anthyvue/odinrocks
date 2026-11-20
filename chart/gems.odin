package chart

import "core:fmt"
import "core:slice"
import "core:strings"
import "../songsterr"

// The most strings a guitar may have. check_tab refuses a tab with more.
MAX_STRINGS :: 8
MAX_VOICES :: 8
// Songsterr bend tone is the Guitar Pro scale: 50 is one semitone, 100 is a whole tone.
TONE_PER_SEMITONE :: 50.0
BEND_POSITION :: 60.0
// Songsterr often writes tremolo picking as plain repeated notes. That many of them in a row on one string and fret,
// each at most TREMOLO_MAX_REPICK seconds after the one before (8 picks a second), become one tremolo gem.
TREMOLO_MIN_NOTES :: 4
TREMOLO_MAX_REPICK :: 0.125

// One note, ready to draw. A zero line is a plain gem.
Gem :: struct {
	string_index: int,
	fret:         int,
	time:         f64,
	line:         Line,
	hop:          Hop,
	pinch:        bool,
	dead:         bool,
}

// The line behind the gem: how long it lasts and where it goes.
Line :: struct {
	sustain: f64,
	shape:   Line_Shape,
	slide:   Slide,
	bends:   []Bend_Point,
}

// One shape per line. Tremolo wins over vibrato.
Line_Shape :: enum {
	Straight,
	Slight_Vibrato,
	Wide_Vibrato,
	Tremolo,
}

// fret is the landing fret of a .To_Next slide.
Slide :: struct {
	into: Slide_Into,
	out:  Slide_Out,
	fret: int,
}

Slide_Into :: enum {
	None,
	Below,
	Above,
}

// Up and Down are a short skew with no landing fret. To_Next ends on the next note of the string.
Slide_Out :: enum {
	None,
	Up,
	Down,
	To_Next,
}

// at is 0 at the attack and 1 at the end of the line.
Bend_Point :: struct {
	at:        f64,
	semitones: f64,
}

Hop :: enum {
	None,
	Hammer,
	Pull,
}

// fraction is the position in the bar: 0 is the downbeat, 1 is the next bar.
Bar_Position :: struct {
	measure:  int,
	fraction: f64,
}

// A gem placed in the bars instead of in seconds. gem has no time, sustain or bends yet. gem_from_note sets them.
// bend is a view of the bend points in the tab.
Beat_Note :: struct {
	start, end: Bar_Position,
	voice:      int,
	bend:       []songsterr.Bend_Point,
	gem:        Gem,
}

// What a voice last played on each string: the fret, and the index of the note that a tie extends. The zero value knows nothing.
@(private)
String_Memory :: struct {
	fret:    [MAX_STRINGS]Maybe(int),
	holding: [MAX_STRINGS]Maybe(int),
}

@(private)
Slide_Word :: struct {
	name: string,
	into: Slide_Into,
	out:  Slide_Out,
}

@(rodata)
SLIDE_WORDS := [?]Slide_Word{
	{"into_from_below", .Below, .None},
	{"into_from_above", .Above, .None},
	{"downwards", .None, .Down},
	{"upwards", .None, .Up},
	{"legato", .None, .To_Next},
	{"toNext", .None, .To_Next},
	{"shift", .None, .To_Next},
	{"below", .Below, .None},
	{"above", .Above, .None},
}

// Prints why to stderr and returns false when the gems of tab cannot be placed against measure_times: too many strings or voices,
// a time signature or a beat length that is not positive, a note on a string the tab does not have,
// or more measure times than the played bars and the end of the last one.
check_tab :: proc(tab: songsterr.Tab, measure_times: []f64) -> bool {
	if tab.strings > MAX_STRINGS {
		fmt.eprintfln("%d strings, at most %d are drawn", tab.strings, MAX_STRINGS)
		return false
	}
	for measure, measure_index in tab.measures {
		if signature, has_signature := measure.signature.?; has_signature && (signature[0] <= 0 || signature[1] <= 0) {
			fmt.eprintfln("measure %d signature %v is not a positive time signature", measure_index, signature)
			return false
		}
		if len(measure.voices) > MAX_VOICES {
			fmt.eprintfln("measure %d has %d voices, at most %d are read", measure_index, len(measure.voices), MAX_VOICES)
			return false
		}
		for voice in measure.voices do for beat in voice.beats do check_beat(beat, measure_index, tab.strings) or_return
	}
	return check_measure_times(tab.measures, measure_times)
}

@(private)
check_measure_times :: proc(measures: []songsterr.Measure, measure_times: []f64) -> bool {
	played := unroll_measures(measures)
	defer delete(played)
	if len(measure_times) > len(played) + 1 {
		fmt.eprintfln("%d bars are played, but there are %d measure times", len(played), len(measure_times))
		return false
	}
	return true
}

@(private)
check_beat :: proc(beat: songsterr.Beat, measure_index, string_count: int) -> bool {
	if beat.duration[1] <= 0 {
		fmt.eprintfln("measure %d has a beat of duration %v", measure_index, beat.duration)
		return false
	}
	for tab_note in beat.notes {
		string_index := tab_note.string_index.? or_continue
		if string_index < 0 || string_index >= string_count {
			fmt.eprintfln("measure %d has a note on string %d of %d", measure_index, string_index, string_count)
			return false
		}
	}
	return true
}

// played are the bars from played_measures, cut to the same measure_times.
place_gems :: proc(played: []songsterr.Measure, frets: int, measure_times: []f64) -> []Gem {
	notes := beat_notes(played, frets)
	defer delete(notes)

	gems := make([dynamic]Gem, 0, len(notes))
	for note in notes do append(&gems, gem_from_note(note, measure_times))

	slice.sort_by(gems[:], proc(a, b: Gem) -> bool {
		if a.string_index != b.string_index do return a.string_index < b.string_index
		return a.time < b.time
	})
	collapse_tremolo_runs(&gems)
	slice.sort_by(gems[:], proc(a, b: Gem) -> bool {
		return a.time < b.time
	})
	return gems[:]
}

// gems are sorted by string, then time. Each tremolo run becomes its first gem, which lasts until the run ends and zigzags.
@(private)
collapse_tremolo_runs :: proc(gems: ^[dynamic]Gem) {
	kept := 0
	for start := 0; start < len(gems); {
		end := start + 1
		for end < len(gems) && repicks(gems[end - 1], gems[end]) do end += 1

		gem := gems[start]
		if end - start >= TREMOLO_MIN_NOTES {
			last := gems[end - 1]
			gem.line.sustain = last.time + last.line.sustain - gem.time
			gem.line.shape = .Tremolo
		} else {
			end = start + 1
		}
		gems[kept] = gem
		kept += 1
		start = end
	}
	resize(gems, kept)
}

// Whether gem picks previous again soon enough to belong to its tremolo run.
@(private)
repicks :: proc(previous, gem: Gem) -> bool {
	same_note := gem.string_index == previous.string_index && gem.fret == previous.fret
	return same_note && is_plain(previous) && is_plain(gem) && gem.time - previous.time <= TREMOLO_MAX_REPICK
}

// A plain gem has no technique: it only says which string, fret, and how long.
@(private)
is_plain :: proc(gem: Gem) -> bool {
	no_line_technique := gem.line.shape == .Straight && gem.line.slide == {} && len(gem.line.bends) == 0
	return no_line_technique && gem.hop == .None && !gem.pinch && !gem.dead
}

@(private)
gem_from_note :: proc(note: Beat_Note, measure_times: []f64) -> Gem {
	start := placed_time(measure_times, note.start)
	end := placed_time(measure_times, note.end)
	gem := note.gem
	gem.time = start
	gem.line.sustain = end - start
	gem.line.bends = slice.mapper(note.bend, bend_point)
	return gem
}

@(private)
placed_time :: proc(measure_times: []f64, position: Bar_Position) -> f64 {
	measure_start := measure_times[position.measure]
	bar_seconds := end_of_measure(measure_times, position.measure) - measure_start
	return measure_start + position.fraction * bar_seconds
}

beat_notes :: proc(measures: []songsterr.Measure, frets: int) -> []Beat_Note {
	notes: [dynamic]Beat_Note
	memory: [MAX_VOICES]String_Memory

	// A time signature sticks until a later bar sets one.
	signature := [2]int{4, 4}
	for measure, measure_index in measures {
		signature = measure.signature.? or_else signature
		bar_quarters := songsterr.quarter_length(signature)
		for voice, voice_index in measure.voices {
			cursor: f64
			for beat in voice.beats {
				template := beat_template(beat, measure_index, voice_index, cursor, bar_quarters)
				read_beat(&notes, &memory[voice_index], beat, template, frets)
				// A grace note takes no time in the bar.
				if beat.grace_note == "" do cursor += songsterr.quarter_length(beat.duration)
			}
		}
	}

	extend_slides_to_next(notes[:])
	return notes[:]
}

// The fields that all notes of beat share: the voice, and where the notes start and end. cursor is where beat starts in the bar, in quarters.
@(private)
beat_template :: proc(beat: songsterr.Beat, measure, voice: int, cursor, bar_quarters: f64) -> Beat_Note {
	fraction := cursor / bar_quarters
	// beforeBeat sits a 32nd note early. onBeat stays on the beat.
	if beat.grace_note == "beforeBeat" do fraction = max(fraction - 0.125 / bar_quarters, 0)
	end_fraction := fraction
	if beat.grace_note == "" do end_fraction = (cursor + songsterr.quarter_length(beat.duration)) / bar_quarters
	return {start = {measure, fraction}, end = {measure, end_fraction}, voice = voice}
}

@(private)
read_beat :: proc(notes: ^[dynamic]Beat_Note, memory: ^String_Memory, beat: songsterr.Beat, template: Beat_Note, frets: int) {
	if beat.rest {
		memory^ = {}
		return
	}
	for tab_note in beat.notes do read_tab_note(notes, memory, beat, tab_note, template, frets)
}

@(private)
read_tab_note :: proc(
	notes: ^[dynamic]Beat_Note,
	memory: ^String_Memory,
	beat: songsterr.Beat,
	tab_note: songsterr.Tab_Note,
	template: Beat_Note,
	frets: int,
) {
	string_index, has_string := tab_note.string_index.?
	if !has_string do return

	if tab_note.tie {
		if index, held := memory.holding[string_index].?; held && !notes[index].gem.dead do notes[index].end = template.end
		if fret, has_fret := tab_note.fret.?; has_fret && fret <= frets do memory.fret[string_index] = fret
		return
	}

	fret, has_fret := tab_note.fret.?
	if !has_fret || fret > frets do return

	note := template
	note.gem.string_index = string_index
	note.gem.fret = fret
	apply_technique(&note, beat, tab_note, memory)
	memory.holding[string_index] = len(notes)
	memory.fret[string_index] = fret
	append(notes, note)
}

@(private)
apply_technique :: proc(note: ^Beat_Note, beat: songsterr.Beat, tab_note: songsterr.Tab_Note, memory: ^String_Memory) {
	gem := &note.gem
	previous, linked := memory.fret[gem.string_index].?
	if tab_note.hp && linked do gem.hop = hop_between(previous, gem.fret)

	harmonic := tab_note.harmonic
	if harmonic == "" do harmonic = beat.harmonic
	gem.pinch = harmonic == "pinch"
	gem.dead = tab_note.dead
	if gem.dead {
		note.end = note.start
		return
	}

	gem.line.slide = read_slide(tab_note.slide)
	gem.line.shape = read_shape(beat, tab_note)
	note.bend = tab_note.bend.points
}

@(private)
hop_between :: proc(previous, fret: int) -> Hop {
	if fret > previous do return .Hammer
	if fret < previous do return .Pull
	return .None
}

@(private)
read_shape :: proc(beat: songsterr.Beat, tab_note: songsterr.Tab_Note) -> Line_Shape {
	// tremolo is a repick speed. A zero denominator means none was written.
	if tab_note.tremolo[1] != 0 || beat.tremolo[1] != 0 do return .Tremolo
	// left-hand vibrato is false, or a strength word: "slight" or "wide".
	left_hand, _ := tab_note.left_hand_vibrato.(string)
	if tab_note.wide_vibrato || left_hand == "wide" || beat.wide_vibrato do return .Wide_Vibrato
	if tab_note.vibrato || left_hand != "" || beat.vibrato do return .Slight_Vibrato
	return .Straight
}

// A To_Next slide wins over a short skew in the same value.
@(private)
read_slide :: proc(value: string) -> (slide: Slide) {
	rest := value
	words: for len(rest) > 0 {
		for word in SLIDE_WORDS {
			if !strings.has_prefix(rest, word.name) do continue
			if word.into != .None do slide.into = word.into
			if word.out != .None && slide.out != .To_Next do slide.out = word.out
			rest = rest[len(word.name):]
			continue words
		}
		return
	}
	return
}

@(private)
bend_point :: proc(point: songsterr.Bend_Point) -> Bend_Point {
	return {
		at = clamp(point.position / BEND_POSITION, 0, 1),
		semitones = point.tone / TONE_PER_SEMITONE,
	}
}

// A To_Next slide lasts until the next note on its string and lands on its fret. With no next note it is no slide.
@(private)
extend_slides_to_next :: proc(notes: []Beat_Note) {
	for &note, index in notes {
		slide := &note.gem.line.slide
		if slide.out != .To_Next do continue
		landing, found := next_on_string(notes, index)
		if !found {
			slide.out = .None
			continue
		}
		slide.fret = landing.gem.fret
		if position_before(note.start, landing.start) do note.end = landing.start
	}
}

// The note after notes[index] on the same string and voice. The notes of one voice are in play order.
@(private)
next_on_string :: proc(notes: []Beat_Note, index: int) -> (next: Beat_Note, found: bool) {
	note := notes[index]
	for other in notes[index + 1:] do if other.voice == note.voice && other.gem.string_index == note.gem.string_index do return other, true
	return
}

@(private)
position_before :: proc(position, other: Bar_Position) -> bool {
	if position.measure != other.measure do return position.measure < other.measure
	return position.fraction < other.fraction
}

// A bar with no time after it lasts as long as the bar before it. A lone bar has no length.
end_of_measure :: proc(measure_times: []f64, measure_index: int) -> f64 {
	next := measure_index + 1
	if next < len(measure_times) do return measure_times[next]
	if measure_index == 0 do return measure_times[0]
	return end_of_last_measure(measure_times[measure_index - 1], measure_times[measure_index])
}

end_of_last_measure :: proc(previous_start, start: f64) -> f64 {
	return start + (start - previous_start)
}
