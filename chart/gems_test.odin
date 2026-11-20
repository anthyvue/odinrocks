package chart

import "core:testing"
import "../songsterr"

delete_gems :: proc(gems: []Gem) {
	for gem in gems do delete(gem.line.bends)
	delete(gems)
}

@(test)
one_walk_keeps_grace_tie_signature_and_time :: proc(t: ^testing.T) {
	chord := [2]songsterr.Tab_Note{
		{string_index = 0, fret = 5},
		{string_index = 1, fret = 7},
	}
	grace := [1]songsterr.Tab_Note{{string_index = 0, fret = 3}}
	on_beat := [1]songsterr.Tab_Note{{string_index = 2, fret = 4}}
	tied := [1]songsterr.Tab_Note{{string_index = 0, fret = 5, tie = true}}
	junk := [3]songsterr.Tab_Note{
		{string_index = 0, fret = 30},
		{fret = 1},
		{string_index = 0},
	}
	other_voice := [1]songsterr.Tab_Note{{string_index = 5, fret = 12}}
	clamped := [1]songsterr.Tab_Note{{string_index = 1, fret = 1}}
	after_grace := [1]songsterr.Tab_Note{{string_index = 0, fret = 2}}
	third := [1]songsterr.Tab_Note{{string_index = 0, fret = 9}}
	carried := [2]songsterr.Tab_Note{
		{string_index = 0, fret = 0},
		{string_index = 3, fret = 4},
	}

	leading := [6]songsterr.Beat{
		{duration = {1, 4}, notes = chord[:]},
		{duration = {1, 16}, grace_note = "beforeBeat", notes = grace[:]},
		{duration = {1, 16}, grace_note = "onBeat", notes = on_beat[:]},
		{duration = {1, 4}, notes = tied[:]},
		{duration = {1, 4}, rest = true},
		{duration = {1, 4}, notes = junk[:]},
	}
	second_voice := [1]songsterr.Beat{{duration = {1, 4}, notes = other_voice[:]}}
	middle := [3]songsterr.Beat{
		{duration = {1, 16}, grace_note = "beforeBeat", notes = clamped[:]},
		{duration = {1, 4}, notes = after_grace[:]},
		{duration = {1, 4}, notes = third[:]},
	}
	last := [2]songsterr.Beat{
		{duration = {1, 4}, notes = carried[0:1]},
		{duration = {1, 4}, notes = carried[1:2]},
	}
	opening_voices := [2]songsterr.Voice{
		{beats = leading[:]},
		{beats = second_voice[:]},
	}
	middle_voices := [1]songsterr.Voice{{beats = middle[:]}}
	last_voices := [1]songsterr.Voice{{beats = last[:]}}
	measures := [3]songsterr.Measure{
		{signature = {4, 4}, voices = opening_voices[:]},
		{signature = {3, 4}, voices = middle_voices[:]},
		{voices = last_voices[:]},
	}

	notes := beat_notes(measures[:], 24)
	defer delete(notes)
	testing.expect_value(t, len(notes), 10)
	if len(notes) != 10 do return

	expect_note(t, notes[0], 0, 0, 0, 5)
	expect_note(t, notes[1], 0, 0, 1, 7)
	expect_note(t, notes[2], 0, 0.21875, 0, 3)
	expect_note(t, notes[3], 0, 0.25, 2, 4)
	expect_note(t, notes[4], 0, 0, 5, 12)
	expect_note(t, notes[5], 1, 0, 1, 1)
	expect_note(t, notes[6], 1, 0, 0, 2)
	expect_note(t, notes[7], 1, 1.0 / 3.0, 0, 9)
	expect_note(t, notes[8], 2, 0, 0, 0)
	expect_note(t, notes[9], 2, 1.0 / 3.0, 3, 4)

	times := [4]f64{10, 14, 20, 23}
	played := played_measures(measures[:], times[:])
	defer delete(played)
	gems := place_gems(played, 24, times[:])
	defer delete_gems(gems)
	testing.expect_value(t, len(gems), 10)
	if len(gems) != 10 do return

	expect_gem(t, gems, 0, 5, 10)
	expect_gem(t, gems, 1, 7, 10)
	expect_gem(t, gems, 5, 12, 10)
	expect_gem(t, gems, 0, 3, 10.875)
	expect_gem(t, gems, 2, 4, 11)
	expect_gem(t, gems, 1, 1, 14)
	expect_gem(t, gems, 0, 2, 14)
	expect_gem(t, gems, 0, 9, 14 + (1.0 / 3.0) * 6)
	expect_gem(t, gems, 0, 0, 20)
	expect_gem(t, gems, 3, 4, 20 + (1.0 / 3.0) * 3)

	// The tie follows the grace, so it lengthens that gem. The chord note keeps its own quarter.
	testing.expect_value(t, find_gem(t, gems, 0, 10).line.sustain, 1)
	testing.expect_value(t, find_gem(t, gems, 0, 10.875).line.sustain, 1.125)
}

@(private)
expect_note :: proc(t: ^testing.T, got: Beat_Note, measure: int, fraction: f64, string_index, fret: int) {
	testing.expect_value(t, got.start, Bar_Position{measure, fraction})
	testing.expect_value(t, got.gem.string_index, string_index)
	testing.expect_value(t, got.gem.fret, fret)
}

@(private)
find_gem :: proc(t: ^testing.T, gems: []Gem, string_index: int, time: f64) -> Gem {
	for gem in gems {
		if gem.string_index == string_index && gem.time == time do return gem
	}
	testing.expectf(t, false, "missing gem string %d at %v", string_index, time)
	return {}
}

@(private)
expect_gem :: proc(t: ^testing.T, gems: []Gem, string_index, fret: int, time: f64) {
	for gem in gems {
		if gem.string_index != string_index || gem.fret != fret do continue
		testing.expect_value(t, gem.time, time)
		return
	}
	testing.expectf(t, false, "missing gem string %d fret %d", string_index, fret)
}

@(test)
techniques_land_on_the_gem :: proc(t: ^testing.T) {
	bend_points := [2]songsterr.Bend_Point{
		{position = 0, tone = 0},
		{position = 60, tone = 100},
	}
	vibrato := [1]songsterr.Tab_Note{{string_index = 0, fret = 5, vibrato = true}}
	hammer := [1]songsterr.Tab_Note{{string_index = 0, fret = 7, hp = true}}
	pull := [1]songsterr.Tab_Note{{string_index = 0, fret = 4, hp = true}}
	after_rest := [2]songsterr.Tab_Note{
		{string_index = 1, fret = 2},
		{string_index = 0, fret = 9, hp = true},
	}
	tied := [1]songsterr.Tab_Note{{string_index = 1, fret = 2, tie = true}}
	legato := [1]songsterr.Tab_Note{{
		string_index = 2,
		fret = 7,
		slide = "legato",
		bend = {points = bend_points[:]},
	}}
	landing := [1]songsterr.Tab_Note{{string_index = 2, fret = 12}}
	wide := [1]songsterr.Tab_Note{{string_index = 3, fret = 5}}
	tremolo := [1]songsterr.Tab_Note{{string_index = 3, fret = 8}}
	into := [1]songsterr.Tab_Note{{string_index = 4, fret = 9, slide = "belowlegato"}}
	into_landing := [1]songsterr.Tab_Note{{string_index = 4, fret = 12}}
	pinch := [1]songsterr.Tab_Note{{
		string_index = 5,
		fret = 3,
		slide = "upwards",
		harmonic = "pinch",
		vibrato = true,
		tremolo = {1, 32},
	}}
	dead := [1]songsterr.Tab_Note{{string_index = 5, fret = 3, dead = true}}

	bar0 := [4]songsterr.Beat{
		{duration = {1, 4}, notes = vibrato[:]},
		{duration = {1, 4}, notes = hammer[:]},
		{duration = {1, 4}, notes = pull[:]},
		{duration = {1, 4}, rest = true},
	}
	bar1 := [5]songsterr.Beat{
		{duration = {1, 4}, notes = after_rest[:]},
		{duration = {1, 4}, notes = tied[:]},
		{duration = {1, 8}, notes = legato[:]},
		{duration = {1, 8}, rest = true},
		{duration = {1, 4}, notes = landing[:]},
	}
	bar2 := [4]songsterr.Beat{
		{duration = {1, 4}, notes = wide[:], wide_vibrato = true},
		{duration = {1, 4}, notes = tremolo[:], tremolo = {1, 16}},
		{duration = {1, 4}, notes = into[:]},
		{duration = {1, 4}, notes = into_landing[:]},
	}
	bar3 := [2]songsterr.Beat{
		{duration = {1, 4}, notes = pinch[:]},
		{duration = {1, 4}, notes = dead[:]},
	}
	voices := [4]songsterr.Voice{
		{beats = bar0[:]},
		{beats = bar1[:]},
		{beats = bar2[:]},
		{beats = bar3[:]},
	}
	measures := [4]songsterr.Measure{
		{signature = {4, 4}, voices = voices[0:1]},
		{voices = voices[1:2]},
		{voices = voices[2:3]},
		{voices = voices[3:4]},
	}
	times := [5]f64{0, 4, 8, 12, 16}
	played := played_measures(measures[:], times[:])
	defer delete(played)
	gems := place_gems(played, 24, times[:])
	defer delete_gems(gems)
	testing.expect_value(t, len(gems), 13)

	wave := find_gem(t, gems, 0, 0)
	testing.expect_value(t, wave.line.shape, .Slight_Vibrato)
	testing.expect_value(t, wave.line.sustain, 1)
	testing.expect_value(t, wave.hop, .None)

	testing.expect_value(t, find_gem(t, gems, 0, 1).hop, .Hammer)
	testing.expect_value(t, find_gem(t, gems, 0, 2).hop, .Pull)
	rested := find_gem(t, gems, 0, 4)
	testing.expect_value(t, rested.fret, 9)
	testing.expect_value(t, rested.hop, .None)

	held := find_gem(t, gems, 1, 4)
	testing.expect_value(t, held.line.sustain, 2)
	testing.expect_value(t, held.line.shape, .Straight)
	testing.expect_value(t, held.line.slide.out, .None)

	slide := find_gem(t, gems, 2, 6)
	testing.expect_value(t, slide.line.sustain, 1)
	testing.expect_value(t, slide.line.slide.out, .To_Next)
	testing.expect_value(t, slide.line.slide.fret, 12)
	testing.expect_value(t, len(slide.line.bends), 2)
	testing.expect_value(t, slide.line.bends[0].semitones, 0)
	testing.expect_value(t, slide.line.bends[1].at, 1)
	testing.expect_value(t, slide.line.bends[1].semitones, 2)
	testing.expect_value(t, find_gem(t, gems, 2, 7).fret, 12)

	wide_gem := find_gem(t, gems, 3, 8)
	testing.expect_value(t, wide_gem.line.shape, .Wide_Vibrato)
	zigzag := find_gem(t, gems, 3, 9)
	testing.expect_value(t, zigzag.line.shape, .Tremolo)

	arrival := find_gem(t, gems, 4, 10)
	testing.expect_value(t, arrival.line.slide.into, .Below)
	testing.expect_value(t, arrival.line.slide.out, .To_Next)
	testing.expect_value(t, arrival.line.slide.fret, 12)
	testing.expect_value(t, arrival.line.sustain, 1)

	pinched := find_gem(t, gems, 5, 12)
	testing.expect_value(t, pinched.pinch, true)
	testing.expect_value(t, pinched.line.shape, .Tremolo)
	testing.expect_value(t, pinched.line.slide.out, .Up)
	muted := find_gem(t, gems, 5, 13)
	testing.expect_value(t, muted.dead, true)
	testing.expect_value(t, muted.line.sustain, 0)
	testing.expect_value(t, muted.line.shape, .Straight)
}

@(test)
fast_repeated_notes_become_one_tremolo_gem :: proc(t: ^testing.T) {
	chord := [2]songsterr.Tab_Note{
		{string_index = 0, fret = 5},
		{string_index = 1, fret = 7},
	}
	melody := [1]songsterr.Tab_Note{{string_index = 0, fret = 8}}
	too_few := [1]songsterr.Tab_Note{{string_index = 0, fret = 9}}
	alone := [1]songsterr.Tab_Note{{string_index = 0, fret = 10}}
	slow := [1]songsterr.Tab_Note{{string_index = 2, fret = 3}}

	sixteenth :: [2]int{1, 16}
	fast: [16]songsterr.Beat
	for &beat, index in fast {
		beat.duration = sixteenth
		switch {
		case index < 8: beat.notes = chord[:]
		case index < 12: beat.notes = melody[:]
		case index < 15: beat.notes = too_few[:]
		case: beat.notes = alone[:]
		}
	}
	slow_beats := [5]songsterr.Beat{
		{duration = sixteenth, notes = slow[:]},
		{duration = sixteenth, notes = slow[:]},
		{duration = sixteenth, notes = slow[:]},
		{duration = sixteenth, notes = slow[:]},
		{duration = {3, 4}, rest = true},
	}
	voices := [2]songsterr.Voice{{beats = fast[:]}, {beats = slow_beats[:]}}
	measures := [2]songsterr.Measure{
		{signature = {4, 4}, voices = voices[0:1]},
		{voices = voices[1:2]},
	}
	// A 1 s bar is a sixteenth every 62.5 ms. A 4 s bar is one every 250 ms.
	times := [3]f64{0, 1, 5}
	played := played_measures(measures[:], times[:])
	defer delete(played)
	gems := place_gems(played, 24, times[:])
	defer delete_gems(gems)
	testing.expect_value(t, len(gems), 11)

	for string_index in 0 ..= 1 {
		held := find_gem(t, gems, string_index, 0)
		testing.expect_value(t, held.line.shape, .Tremolo)
		testing.expect_value(t, held.line.sustain, 0.5)
	}
	repicked := find_gem(t, gems, 0, 0.5)
	testing.expect_value(t, repicked.fret, 8)
	testing.expect_value(t, repicked.line.shape, .Tremolo)
	testing.expect_value(t, repicked.line.sustain, 0.25)

	testing.expect_value(t, find_gem(t, gems, 0, 0.75).line.shape, .Straight)
	testing.expect_value(t, find_gem(t, gems, 0, 0.8125).line.shape, .Straight)
	testing.expect_value(t, find_gem(t, gems, 0, 0.9375).fret, 10)
	testing.expect_value(t, find_gem(t, gems, 2, 1.75).line.shape, .Straight)
}

@(test)
left_hand_vibrato_strength_picks_the_line_shape :: proc(t: ^testing.T) {
	beat := songsterr.Beat{duration = {1, 4}}
	testing.expect_value(t, read_shape(beat, songsterr.Tab_Note{left_hand_vibrato = "slight"}), Line_Shape.Slight_Vibrato)
	testing.expect_value(t, read_shape(beat, songsterr.Tab_Note{left_hand_vibrato = "wide"}), Line_Shape.Wide_Vibrato)
	testing.expect_value(t, read_shape(beat, songsterr.Tab_Note{left_hand_vibrato = false}), Line_Shape.Straight)
}

@(test)
check_tab_refuses_what_place_gems_cannot_place :: proc(t: ^testing.T) {
	on_string_5 := [1]songsterr.Tab_Note{{string_index = 5, fret = 3}}
	beats := [1]songsterr.Beat{{duration = {1, 4}, notes = on_string_5[:]}}
	voices := [1]songsterr.Voice{{beats = beats[:]}}
	measures := [1]songsterr.Measure{{signature = [2]int{4, 4}, voices = voices[:]}}
	tab := songsterr.Tab{strings = 6, measures = measures[:]}
	start_and_end := []f64{0, 2}
	testing.expect(t, check_tab(tab, start_and_end))

	one_time_too_many := []f64{0, 2, 4}
	testing.expect(t, !check_tab(tab, one_time_too_many))

	too_few_strings := tab
	too_few_strings.strings = 5
	testing.expect(t, !check_tab(too_few_strings, start_and_end))

	too_many_strings := tab
	too_many_strings.strings = MAX_STRINGS + 1
	testing.expect(t, !check_tab(too_many_strings, start_and_end))

	measures[0].signature = [2]int{4, 0}
	testing.expect(t, !check_tab(tab, start_and_end))
	measures[0].signature = nil

	beats[0].duration = {1, 0}
	testing.expect(t, !check_tab(tab, start_and_end))
	beats[0].duration = {1, 4}

	many_voices: [MAX_VOICES + 1]songsterr.Voice
	measures[0].voices = many_voices[:]
	testing.expect(t, !check_tab(tab, start_and_end))
}
