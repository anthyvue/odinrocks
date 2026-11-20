package pitch

import "core:math"
import "core:math/rand"
import "core:testing"
import "../pcm"

WINDOW :: 4096

@(test)
reads_open_strings_within_a_cent :: proc(t: ^testing.T) {
	// From the low E of an 8-string in drop E to the high E of a guitar.
	open_strings := []int{28, 33, 35, 40, 45, 50, 55, 59, 64}
	for midi in open_strings {
		for seconds_since_pluck in ([]f32{0.05, 0.5, 2}) {
			samples := pluck(note_hz(midi) * math.pow(2, f32(7) / 1200), seconds_since_pluck)
			hz, found := detect(samples[:])
			cents := cents_from_note(hz, midi)
			testing.expectf(t, found && abs(cents - 7) < 1, "note %d, %v s after the pluck: found %v, %.2f cents", midi, seconds_since_pluck, found, cents)
		}
	}
}

@(test)
silence_and_noise_have_no_pitch :: proc(t: ^testing.T) {
	silence: [WINDOW]f32
	_, found := detect(silence[:])
	testing.expect(t, !found)

	noise: [WINDOW]f32
	for &sample in noise do sample = 0.1 * (rand.float32() * 2 - 1)
	_, found = detect(noise[:])
	testing.expect(t, !found)
}

@(test)
cents_from_note_ignores_the_octave :: proc(t: ^testing.T) {
	ten_cents_sharp := math.pow(2, f32(10) / 1200)
	testing.expect(t, abs(cents_from_note(note_hz(40) * ten_cents_sharp, 40) - 10) < 0.01)
	testing.expect(t, abs(cents_from_note(note_hz(28) * ten_cents_sharp, 40) - 10) < 0.01)
	testing.expect(t, abs(cents_from_note(note_hz(38), 40) + 200) < 0.01)
}

// A string plucked seconds_since_pluck before the window: harmonics that fade, a fundamental weaker than the second harmonic, and some noise.
pluck :: proc(hz: f32, seconds_since_pluck: f32) -> (samples: [WINDOW]f32) {
	for &sample, index in samples {
		seconds := seconds_since_pluck + f32(index) / pcm.SAMPLE_RATE
		for harmonic in 1 ..= 20 {
			loudness := (0.4 if harmonic == 1 else 1 / f32(harmonic)) * math.exp(-seconds * f32(harmonic) * 0.4)
			sample += 0.2 * loudness * math.sin(2 * math.PI * f32(harmonic) * hz * seconds + f32(harmonic))
		}
		sample += 0.002 * (rand.float32() * 2 - 1)
	}
	return
}
