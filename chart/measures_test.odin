package chart

import "core:slice"
import "core:testing"
import "../songsterr"

// Bar n carries signature {n, 4}, so the played order reads as bar numbers.
numbered_bar :: proc(n: int, repeat_start := false, repeat := 0, endings: []int = nil) -> songsterr.Measure {
	return songsterr.Measure{
		signature = [2]int{n, 4},
		repeat_start = repeat_start,
		repeat = repeat,
		alternate_ending = endings,
	}
}

expect_played :: proc(t: ^testing.T, measures: []songsterr.Measure, want: []int) {
	unrolled := unroll_measures(measures)
	defer delete(unrolled)
	got := make([]int, len(unrolled), context.temp_allocator)
	for measure, i in unrolled do got[i] = measure.signature.?[0]
	testing.expectf(t, slice.equal(got, want), "played %v, want %v", got, want)
}

@(test)
bars_without_repeats_play_once :: proc(t: ^testing.T) {
	measures := [3]songsterr.Measure{numbered_bar(1), numbered_bar(2), numbered_bar(3)}
	expect_played(t, measures[:], {1, 2, 3})
}

@(test)
repeat_plays_its_bars_as_many_times_as_the_closing_bar_says :: proc(t: ^testing.T) {
	measures := [4]songsterr.Measure{
		numbered_bar(1, repeat_start = true),
		numbered_bar(2),
		numbered_bar(3, repeat = 2),
		numbered_bar(4),
	}
	expect_played(t, measures[:], {1, 2, 3, 1, 2, 3, 4})
}

@(test)
alternate_endings_play_on_the_pass_they_name :: proc(t: ^testing.T) {
	first := [1]int{1}
	second := [1]int{2}
	measures := [4]songsterr.Measure{
		numbered_bar(1, repeat_start = true),
		numbered_bar(2, repeat = 2, endings = first[:]),
		numbered_bar(3, endings = second[:]),
		numbered_bar(4),
	}
	expect_played(t, measures[:], {1, 2, 1, 3, 4})
}

@(test)
inner_repeat_plays_again_when_the_outer_repeat_jumps_back :: proc(t: ^testing.T) {
	measures := [5]songsterr.Measure{
		numbered_bar(1, repeat_start = true),
		numbered_bar(2, repeat_start = true),
		numbered_bar(3, repeat = 2),
		numbered_bar(4, repeat = 2),
		numbered_bar(5),
	}
	expect_played(t, measures[:], {1, 2, 3, 2, 3, 4, 1, 2, 3, 2, 3, 4, 5})
}

@(test)
closing_bar_without_opening_goes_back_to_the_song_start :: proc(t: ^testing.T) {
	measures := [3]songsterr.Measure{numbered_bar(1), numbered_bar(2, repeat = 2), numbered_bar(3)}
	expect_played(t, measures[:], {1, 2, 1, 2, 3})
}

@(test)
song_repeat_replays_the_repeats_inside_it :: proc(t: ^testing.T) {
	measures := [3]songsterr.Measure{
		numbered_bar(1, repeat_start = true),
		numbered_bar(2, repeat = 2),
		numbered_bar(3, repeat = 2),
	}
	expect_played(t, measures[:], {1, 2, 1, 2, 3, 1, 2, 1, 2, 3})
}
