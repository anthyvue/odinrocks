package songsync

import "core:math"
import "core:testing"
import "../pcm"
import "../songsterr"

@(test)
sync_slides_bars_onto_late_clicks :: proc(t: ^testing.T) {
	expect_bars_on_clicks(t, 0.04)
}

@(test)
sync_leaves_aligned_clicks :: proc(t: ^testing.T) {
	expect_bars_on_clicks(t, 0)
}

@(test)
chord_collapses_to_one_fraction :: proc(t: ^testing.T) {
	notes := [3]songsterr.Tab_Note{{string_index = 0, fret = 0}, {string_index = 1, fret = 2}, {string_index = 0, fret = 3}}
	beats := [2]songsterr.Beat{{duration = {1, 2}, notes = notes[0:2]}, {duration = {1, 2}, notes = notes[2:3]}}
	voices := [1]songsterr.Voice{{beats = beats[:]}}
	measures := [1]songsterr.Measure{{signature = {4, 4}, voices = voices[:]}}

	bars := collect_fractions(measures[:], 24)
	defer {
		for bar in bars do delete(bar)
		delete(bars)
	}

	testing.expect_value(t, len(bars), 1)
	if len(bars) != 1 do return
	testing.expect_value(t, len(bars[0]), 2)
	if len(bars[0]) != 2 do return
	testing.expect_value(t, bars[0][0], 0)
	testing.expect_value(t, bars[0][1], 0.5)
}

// Syncs four 4/4 bars, one a second, that play on beats 1 and 3, to a recording that clicks delay seconds after each of those beats.
// Every measure time has to move by delay.
expect_bars_on_clicks :: proc(t: ^testing.T, delay: f64) {
	notes := [2]songsterr.Tab_Note{{string_index = 0, fret = 0}, {string_index = 0, fret = 3}}
	beats := [4]songsterr.Beat{
		{duration = {1, 4}, notes = notes[0:1]},
		{duration = {1, 4}, rest = true},
		{duration = {1, 4}, notes = notes[1:2]},
		{duration = {1, 4}, rest = true},
	}
	voices := [1]songsterr.Voice{{beats = beats[:]}}
	bar := songsterr.Measure{voices = voices[:]}
	measures := [4]songsterr.Measure{{signature = {4, 4}, voices = voices[:]}, bar, bar, bar}
	measure_times := [5]f64{0, 1, 2, 3, 4}

	frames := make([][2]f32, 5 * pcm.SAMPLE_RATE)
	defer delete(frames)
	for bar_start in measure_times[:4] {
		click(frames, bar_start + delay)
		click(frames, bar_start + 0.5 + delay)
	}
	attacks := measure_attacks(frames)
	defer delete(attacks)

	got := sync_automatically(measures[:], measure_times[:], attacks, 24)
	defer delete(got)

	testing.expect_value(t, len(got), len(measure_times))
	if len(got) != len(measure_times) do return
	for measure_time, index in measure_times {
		want := measure_time + delay
		testing.expectf(t, abs(got[index] - want) <= 0.02, "measure time %d got %.3f want %.3f", index, got[index], want)
	}
}

click :: proc(frames: [][2]f32, time: f64) {
	frame := int(math.round(time * f64(pcm.SAMPLE_RATE)))
	for offset in 0 ..< 300 {
		index := frame + offset
		if index >= len(frames) do return
		value := f32(1.0 - f64(offset) / 300.0)
		if offset % 2 == 1 do value = -value
		frames[index] = {value, value}
	}
}
