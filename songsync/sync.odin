package songsync

import "core:math"
import "core:slice"
import "../chart"
import "../pcm"
import "../songsterr"

// The sync measures the recording in slices of 10 ms.
SLICE_FRAMES :: 480
SEARCH_FRAMES :: 36000
SMOOTH_PER_SECOND :: 2.0
ABSOLUTE_PER_SECOND :: 1.2
STRETCH_PER_SECOND :: 0.5
// The score of a shift that no path of shifts reaches.
UNREACHABLE :: math.NEG_INF_F64

// Slide each measure boundary onto the attacks in the recording. Only the result uses context.allocator. The scratch data uses context.temp_allocator.
// played are the bars from chart.played_measures, cut to the same measure_times. attacks are the attacks of the recording, from measure_attacks.
sync_automatically :: proc(played: []songsterr.Measure, measure_times: []f64, attacks: []f32, frets: int) -> []f64 {
	synced_allocator := context.allocator
	context.allocator = context.temp_allocator

	if len(attacks) == 0 do return slice.clone(measure_times, synced_allocator)

	bars := collect_fractions(played, frets)
	peaks := measure_peaks(attacks, measure_times, len(bars))
	shifts := boundary_shifts()
	steps := score_paths(attacks, bars, peaks, measure_times, shifts)
	picked, found := trace_best_path(steps, len(shifts))
	if !found do return slice.clone(measure_times, synced_allocator)

	synced := shift_measure_times(measure_times, shifts, picked)
	return slice.clone(synced, synced_allocator)
}

// The best path of shifts that ends on one shift of one boundary: its score, and the index of the shift of the boundary before.
@(private)
Path_Step :: struct {
	score: f64,
	from:  int,
}

// The forward pass: one row of len(shifts) steps per measure time.
@(private)
score_paths :: proc(attacks: []f32, bars: [][dynamic]f64, peaks: []f64, measure_times, shifts: []f64) -> []Path_Step {
	shift_count := len(shifts)
	steps := make([]Path_Step, len(measure_times) * shift_count)
	for shift, shift_index in shifts do steps[shift_index].score = -abs(shift) * ABSOLUTE_PER_SECOND

	last := len(measure_times) - 1
	// The last played measure has no end time. Then it follows the measure before with the same length.
	open_last := len(bars) == len(measure_times)
	for boundary in 1 ..= last {
		measure := boundary - 1
		old_span := measure_times[boundary] - measure_times[measure]
		previous_row := steps[measure * shift_count:][:shift_count]
		row := steps[boundary * shift_count:][:shift_count]
		for shift, shift_index in shifts {
			end := measure_times[boundary] + shift
			absolute := abs(shift) * ABSOLUTE_PER_SECOND
			best := Path_Step{score = UNREACHABLE}
			for previous_shift, previous_index in shifts {
				start := measure_times[measure] + previous_shift
				previous_score := previous_row[previous_index].score
				if end <= start || previous_score == UNREACHABLE do continue

				gained := mean_attack(attacks, bars[measure][:], start, end, peaks[measure])
				if open_last && boundary == last {
					gained += mean_attack(attacks, bars[boundary][:], end, chart.end_of_last_measure(start, end), peaks[boundary])
				}
				stretch := abs((end - start) - old_span) * STRETCH_PER_SECOND
				smooth := abs(shift - previous_shift) * SMOOTH_PER_SECOND
				total := previous_score + gained - stretch - smooth - absolute
				if total > best.score do best = {total, previous_index}
			}
			row[shift_index] = best
		}
	}
	return steps
}

// The index of the shift of each boundary on the best path that steps holds. found is false when no path reaches the last boundary.
@(private)
trace_best_path :: proc(steps: []Path_Step, shift_count: int) -> (picked: []int, found: bool) {
	time_count := len(steps) / shift_count
	last := time_count - 1
	last_row := steps[last * shift_count:]
	chosen := 0
	for step, shift_index in last_row do if step.score > last_row[chosen].score do chosen = shift_index
	if last_row[chosen].score == UNREACHABLE do return

	picked = make([]int, time_count)
	picked[last] = chosen
	for boundary := last; boundary > 0; boundary -= 1 do picked[boundary - 1] = steps[boundary * shift_count + picked[boundary]].from
	return picked, true
}

// Moves each measure time by its picked shift. The result stays at or after 0 and strictly rising.
@(private)
shift_measure_times :: proc(measure_times, shifts: []f64, picked: []int) -> []f64 {
	synced := make([]f64, len(measure_times))
	for measure_time, boundary in measure_times {
		shifted := max(measure_time + shifts[picked[boundary]], 0)
		if boundary > 0 && shifted <= synced[boundary - 1] do shifted = synced[boundary - 1] + 0.001
		synced[boundary] = shifted
	}
	return synced
}

@(private)
boundary_shifts :: proc() -> []f64 {
	max_slices := SEARCH_FRAMES / SLICE_FRAMES
	shift_count := max_slices * 2 + 1
	shifts := make([]f64, shift_count)
	for &shift, shift_index in shifts {
		slices := shift_index - max_slices
		shift = f64(slices * SLICE_FRAMES) / f64(pcm.SAMPLE_RATE)
	}
	return shifts
}

// How much the loudness of frames rose from one slice to the next. A fall is 0. frames are stereo at pcm.SAMPLE_RATE.
measure_attacks :: proc(frames: [][2]f32) -> []f32 {
	loudness := make([]f32, len(frames) / SLICE_FRAMES, context.temp_allocator)
	for &value, index in loudness {
		sum: f64
		for frame in frames[index * SLICE_FRAMES:][:SLICE_FRAMES] {
			mono := (f64(frame[0]) + f64(frame[1])) * 0.5
			sum += mono * mono
		}
		value = f32(math.sqrt(sum / SLICE_FRAMES))
	}
	attacks := make([]f32, len(loudness))
	for index in 1 ..< len(loudness) do attacks[index] = max(loudness[index] - loudness[index - 1], 0)
	return attacks
}

@(private)
measure_peaks :: proc(attacks: []f32, measure_times: []f64, measure_count: int) -> []f64 {
	peaks := make([]f64, measure_count)
	for &peak, measure_index in peaks do peak = window_peak(attacks, measure_times[measure_index], chart.end_of_measure(measure_times, measure_index))
	return peaks
}

@(private)
window_peak :: proc(attacks: []f32, start, end: f64) -> f64 {
	search := f64(SEARCH_FRAMES) / f64(pcm.SAMPLE_RATE)
	from_slice := max(slice_at(start - search), 0)
	to_slice := min(slice_at(end + search), len(attacks) - 1)
	peak: f64
	for index in from_slice ..= to_slice do peak = max(peak, f64(attacks[index]))
	return peak
}

@(private)
mean_attack :: proc(attacks: []f32, fractions: []f64, start, end, peak: f64) -> f64 {
	if len(fractions) == 0 || end <= start || peak <= 1e-8 do return 0
	span := end - start
	total: f64
	for fraction in fractions do total += attack_at(attacks, start + fraction * span)
	return total / f64(len(fractions)) / peak
}

@(private)
attack_at :: proc(attacks: []f32, time: f64) -> f64 {
	index := slice_at(time)
	if index < 0 || index >= len(attacks) do return 0
	return f64(attacks[index])
}

// The index of the slice that holds time. Negative before the recording starts.
@(private)
slice_at :: proc(time: f64) -> int {
	sample := int(math.round(time * f64(pcm.SAMPLE_RATE)))
	return math.floor_div(sample, SLICE_FRAMES)
}

@(private)
collect_fractions :: proc(measures: []songsterr.Measure, frets: int) -> [][dynamic]f64 {
	notes := chart.beat_notes(measures, frets)
	defer delete(notes)

	bars := make([][dynamic]f64, len(measures))
	for note in notes do append(&bars[note.start.measure], note.start.fraction)
	for &bar in bars {
		slice.sort(bar[:])
		dedupe_fractions(&bar)
	}
	return bars
}

@(private)
dedupe_fractions :: proc(fractions: ^[dynamic]f64) {
	if len(fractions) < 2 do return
	kept := 1
	for index in 1 ..< len(fractions) {
		if fractions[index] - fractions[kept - 1] <= 0.001 do continue
		fractions[kept] = fractions[index]
		kept += 1
	}
	resize(fractions, kept)
}
