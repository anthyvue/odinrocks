// Finds the pitch of a plucked string, and how far it is from a note.
package pitch

import "core:math"
import "../pcm"

// YIN reads the mean of every DECIMATION input samples, so a window costs a quarter.
// Readings stay within a cent up to E5. A mean of 4 reads fresh high strings a few cents sharp.
DECIMATION :: 2
DETECTION_RATE :: pcm.SAMPLE_RATE / DECIMATION
// The lowest open string of an 8-string guitar in drop E is 41 Hz.
LOWEST_HZ :: 40
HIGHEST_HZ :: 1000
// YIN takes the first dip of the normalized difference below this.
DIP_THRESHOLD :: 0.15
// A window with a lower RMS is silence. It is about -50 dBFS.
SILENCE_RMS :: 0.003

// The fundamental of samples in Hz, found with YIN (de Cheveigné and Kawahara, 2002), the method the other Rocksmith clones use.
// samples run at pcm.SAMPLE_RATE and hold at least two periods of LOWEST_HZ. found is false for silence and for a sound with no clear period.
detect :: proc(samples: []f32) -> (hz: f32, found: bool) {
	signal := decimate(samples)
	if rms(signal) < SILENCE_RMS do return
	max_lag := DETECTION_RATE / LOWEST_HZ
	assert(len(signal) >= 2 * max_lag, "the window is shorter than two periods of the lowest note")
	difference := squared_difference(signal, max_lag)
	normalized := normalize_cumulative(difference)
	lag := first_dip(normalized, DETECTION_RATE / HIGHEST_HZ) or_return
	return DETECTION_RATE / refine_lag(difference, lag), true
}

// The frequency of MIDI note midi, with A4 at 440 Hz.
note_hz :: proc(midi: int) -> f32 {
	return 440 * math.pow(2, f32(midi - 69) / 12)
}

// How many cents hz is above the nearest octave of MIDI note midi, from -600 to 600.
// The octave is ignored because YIN can read a fading low string an octave down.
cents_from_note :: proc(hz: f32, midi: int) -> f32 {
	cents := 1200 * math.log2(hz / note_hz(midi))
	return cents - 1200 * math.round(cents / 1200)
}

// The mean of every DECIMATION samples, in context.temp_allocator.
@(private)
decimate :: proc(samples: []f32) -> []f32 {
	means := make([]f32, len(samples) / DECIMATION, context.temp_allocator)
	for &mean, index in means do mean = math.sum(samples[index * DECIMATION:][:DECIMATION]) / DECIMATION
	return means
}

@(private)
rms :: proc(signal: []f32) -> f32 {
	squares: f32
	for sample in signal do squares += sample * sample
	return math.sqrt(squares / f32(len(signal)))
}

// For every lag up to max_lag, the sum of squared differences between signal and signal shifted by lag, in context.temp_allocator.
// It is small at a lag of one period and at each multiple of it.
@(private)
squared_difference :: proc(signal: []f32, max_lag: int) -> []f32 {
	window := len(signal) - max_lag
	difference := make([]f32, max_lag + 1, context.temp_allocator)
	for &sum, lag in difference {
		for index in 0 ..< window {
			delta := signal[index] - signal[index + lag]
			sum += delta * delta
		}
	}
	return difference
}

// Divides each difference by the mean of the differences up to it, in context.temp_allocator.
// The result starts at 1 and does not dip at the short lags where the raw difference is small only because the shift is small.
@(private)
normalize_cumulative :: proc(difference: []f32) -> []f32 {
	normalized := make([]f32, len(difference), context.temp_allocator)
	normalized[0] = 1
	total: f32
	for lag in 1 ..< len(difference) {
		total += difference[lag]
		normalized[lag] = difference[lag] * f32(lag) / total if total > 0 else 1
	}
	return normalized
}

// The bottom of the first dip below DIP_THRESHOLD, from min_lag on. Later dips are multiples of the period.
// The last lag is not a dip, so refine_lag always has a neighbour on each side.
@(private)
first_dip :: proc(normalized: []f32, min_lag: int) -> (lag: int, found: bool) {
	last := len(normalized) - 1
	for lag = min_lag; lag < last; lag += 1 {
		if normalized[lag] >= DIP_THRESHOLD do continue
		for lag + 1 < last && normalized[lag + 1] < normalized[lag] do lag += 1
		return lag, true
	}
	return
}

// Moves lag to the bottom of the parabola through the raw difference at it and its two neighbours.
// The raw bottom can be one lag beside the normalized one, so the move is at most one lag.
@(private)
refine_lag :: proc(difference: []f32, lag: int) -> f32 {
	before, at, after := difference[lag - 1], difference[lag], difference[lag + 1]
	curve := before - 2 * at + after
	if curve <= 0 do return f32(lag)
	return f32(lag) + clamp((before - after) / (2 * curve), -1, 1)
}
