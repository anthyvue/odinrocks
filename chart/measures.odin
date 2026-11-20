package chart

import "core:slice"
import "../songsterr"

// A repeat that is open while the bars are unrolled. pass counts its plays from 1.
// done means its last play has reached the closing bar, so it ends after the alternate endings that follow.
// The song is the outermost repeat, with opening -1. It is never popped, and a closing bar with no opening goes back to bar 0.
@(private)
Open_Repeat :: struct {
	opening: int,
	pass:    int,
	done:    bool,
}

// The bars in the order they are played, cut to the bars that measure_times places.
// Every bar needs its start time, and the last bar may also have its end time. check_tab refuses more times than that.
played_measures :: proc(measures: []songsterr.Measure, measure_times: []f64) -> []songsterr.Measure {
	played := unroll_measures(measures)
	return played[:min(len(played), len(measure_times))]
}

// The bars in the order they are played. A closing bar goes back to its opening until the repeat has been played as often as the bar says.
// An alternate ending plays only on the pass it names. A repeat that ends is popped, so a later jump back into it starts again at pass 1.
@(private)
unroll_measures :: proc(measures: []songsterr.Measure) -> []songsterr.Measure {
	open: [dynamic]Open_Repeat
	defer delete(open)
	append(&open, Open_Repeat{opening = -1, pass = 1})

	unrolled: [dynamic]songsterr.Measure
	index := 0
	for index < len(measures) {
		measure := measures[index]
		end_finished_repeats(&open, measure)
		if measure.repeat_start && open[len(open) - 1].opening != index do append(&open, Open_Repeat{opening = index, pass = 1})

		current := &open[len(open) - 1]
		played := fits_alternate_ending(measure, current.pass)
		if played do append(&unrolled, measure)

		next := index + 1
		if measure.repeat > 0 && current.pass >= measure.repeat {
			current.done = true
		} else if measure.repeat > 0 && played {
			current.pass += 1
			next = max(current.opening, 0)
		}
		index = next
	}
	return unrolled[:]
}

// A repeat whose last play has ended stays open through its alternate endings, and ends at the first bar that is not one.
@(private)
end_finished_repeats :: proc(open: ^[dynamic]Open_Repeat, measure: songsterr.Measure) {
	for len(open) > 1 && open[len(open) - 1].done && len(measure.alternate_ending) == 0 do pop(open)
}

@(private)
fits_alternate_ending :: proc(measure: songsterr.Measure, pass: int) -> bool {
	return len(measure.alternate_ending) == 0 || slice.contains(measure.alternate_ending, pass)
}
