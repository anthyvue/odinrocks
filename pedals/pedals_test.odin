package pedals

import "core:math"
import "core:testing"
import "../pcm"

@(test)
every_rig_plays_a_note_at_the_same_loudness :: proc(t: ^testing.T) {
	rigs := list_rigs()
	defer {
		for rig in rigs do delete(rig)
		delete(rigs)
	}
	testing.expect(t, len(rigs) > 0)
	for rig in rigs {
		rack := new(Rack)
		defer free(rack)
		init(rack, rig, DEFAULT_KNOBS, 128)
		defer destroy(rack)
		squares: f32
		buffer: [128]f32
		blocks := pcm.SAMPLE_RATE / 2 / len(buffer)
		for block in 0 ..< blocks {
			for &sample, index in buffer do sample = 0.25 * math.sin(f32(block * len(buffer) + index) * 110 * 2 * math.PI / pcm.SAMPLE_RATE)
			shape(rack, buffer[:])
			for sample in buffer do squares += sample * sample
		}
		rms_db := 10 * math.log10(squares / f32(blocks * len(buffer)))
		testing.expectf(t, rms_db > -32 && rms_db < -8, "%s: %.1f dB", rig, rms_db)
	}
}

@(test)
gate_keeps_a_low_note_open_and_silences_hiss :: proc(t: ^testing.T) {
	gate: Gate
	// A low E that has faded to just above the threshold only crosses it near its peaks. It still passes unchanged from 20 ms on.
	note: [48000]f32
	for &sample, step in note do sample = 0.0012 * math.sin(f32(step) * 82 * 2 * math.PI / pcm.SAMPLE_RATE)
	shaped := note
	shape_gate(&gate, -60, shaped[:])
	for step in 960 ..< len(note) do testing.expectf(t, abs(shaped[step] - note[step]) <= abs(note[step]) * 0.001, "step %d: %v instead of %v", step, shaped[step], note[step])
	// Hiss 10 dB below the threshold fades out after the note.
	hiss: [48000]f32
	for &sample, step in hiss do sample = 0.0003 * math.sin(f32(step) * 1.3)
	shape_gate(&gate, -60, hiss[:])
	loudest: f32
	for sample in hiss[36000:] do loudest = max(loudest, abs(sample))
	testing.expectf(t, loudest < 0.000003, "hiss after the gate closed: %v", loudest)
}

@(test)
delay_echoes_a_click_after_its_time_and_feeds_back :: proc(t: ^testing.T) {
	delay := new(Delay)
	defer free(delay)
	knobs := Knobs{delay_ms = 100, delay_feedback_percent = 50, delay_level_percent = 40}
	period := 100 * pcm.SAMPLE_RATE / 1000
	buffer := make([]f32, 3 * period + 1)
	defer delete(buffer)
	buffer[0] = 1
	shape_delay(delay, knobs, buffer)
	testing.expect_value(t, buffer[0], 1)
	testing.expect_value(t, buffer[period - 1], 0)
	testing.expect(t, abs(buffer[period] - 0.4) < 0.0001)
	testing.expect(t, abs(buffer[2 * period] - 0.2) < 0.0001)
}

@(test)
bigger_reverb_rings_longer :: proc(t: ^testing.T) {
	small := reverb_tail_energy({reverb_size_percent = 20, reverb_damping_percent = 50, reverb_level_percent = 100})
	big := reverb_tail_energy({reverb_size_percent = 90, reverb_damping_percent = 50, reverb_level_percent = 100})
	testing.expectf(t, small > 0 && big > small * 10, "small %v big %v", small, big)
}

// The energy that a reverb set by knobs plays between 0.5 and 1 second after a click.
reverb_tail_energy :: proc(knobs: Knobs) -> f32 {
	reverb := new(Reverb)
	defer free(reverb)
	buffer := make([]f32, pcm.SAMPLE_RATE)
	defer delete(buffer)
	buffer[0] = 1
	shape_reverb(reverb, knobs, buffer)
	return energy(buffer[pcm.SAMPLE_RATE / 2:])
}

@(test)
drop_for_tuning_lowers_every_string_by_the_same_amount :: proc(t: ^testing.T) {
	E_STANDARD :: []int{64, 59, 55, 50, 45, 40}
	D_STANDARD :: []int{62, 57, 53, 48, 43, 38}
	DROP_D :: []int{64, 59, 55, 50, 45, 38}
	DROP_C :: []int{62, 57, 53, 48, 43, 36}
	SEVEN_STRING :: []int{64, 59, 55, 50, 45, 40, 35}
	Case :: struct {
		guitar, song: []int,
		semitones:    int,
		ok:           bool,
	}
	cases := []Case {
		{E_STANDARD, D_STANDARD, -2, true},
		{DROP_D, DROP_C, -2, true},
		{E_STANDARD, DROP_D, 0, false},
		{D_STANDARD, E_STANDARD, 0, false},
		{E_STANDARD, E_STANDARD, 0, false},
		{E_STANDARD, SEVEN_STRING, 0, false},
	}
	for c in cases {
		semitones, ok := drop_for_tuning(c.guitar, c.song)
		testing.expectf(t, semitones == c.semitones && ok == c.ok, "%v to %v: %d %v", c.guitar, c.song, semitones, ok)
	}
}

@(test)
drop_octave_doubles_the_period :: proc(t: ^testing.T) {
	drop: Drop
	samples: [8000]f32
	for &sample, index in samples do sample = math.sin(f32(index) * 480 * 2 * math.PI / pcm.SAMPLE_RATE)
	shape_drop(&drop, -12, samples[:])
	settled := samples[4000:]
	low := correlate(settled, 200)
	high := correlate(settled, 100)
	testing.expectf(t, low > 0 && low > high * 2, "low %v high %v", low, high)
}

correlate :: proc(samples: []f32, lag: int) -> f32 {
	total: f32
	for index in 0 ..< len(samples) - lag {
		total += samples[index] * samples[index + lag]
	}
	return total
}

energy :: proc(samples: []f32) -> (total: f32) {
	for sample in samples do total += sample * sample
	return
}
