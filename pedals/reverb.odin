// Freeverb, by Jezar at Dreampoint and in the public domain, in mono. Eight combs in parallel make the tail, and four allpasses in series smear it.
#+private
package pedals

// The delays of the combs and the allpasses in samples: Freeverb's tuning at 44.1 kHz, scaled to 48 kHz.
@(rodata)
COMB_LENGTHS := [8]int{1215, 1293, 1390, 1476, 1548, 1623, 1695, 1760}
@(rodata)
ALLPASS_LENGTHS := [4]int{605, 480, 371, 245}
MAX_COMB_LENGTH :: 1760
MAX_ALLPASS_LENGTH :: 605
ALLPASS_FEEDBACK :: 0.5
// Freeverb's gains: eight combs add up to a loud tail.
REVERB_INPUT_GAIN :: 0.015
REVERB_WET_GAIN :: 3

Reverb :: struct {
	combs:     [len(COMB_LENGTHS)]Comb,
	allpasses: [len(ALLPASS_LENGTHS)]Allpass,
}

Comb :: struct {
	ring:   [MAX_COMB_LENGTH]f32,
	at:     int,
	damped: f32,
}

Allpass :: struct {
	ring: [MAX_ALLPASS_LENGTH]f32,
	at:   int,
}

// Adds the tail of a room to buffer, in place. Freeverb maps size and damping onto these ranges.
shape_reverb :: proc(reverb: ^Reverb, knobs: Knobs, buffer: []f32) {
	feedback := 0.7 + 0.28 * from_percent(knobs.reverb_size_percent)
	damping := 0.4 * from_percent(knobs.reverb_damping_percent)
	level := from_percent(knobs.reverb_level_percent)
	for &sample in buffer {
		input := sample * REVERB_INPUT_GAIN
		tail: f32
		for &comb, index in reverb.combs do tail += comb_filter(&comb, COMB_LENGTHS[index], input, feedback, damping)
		for &allpass, index in reverb.allpasses do tail = allpass_filter(&allpass, ALLPASS_LENGTHS[index], tail)
		sample += tail * REVERB_WET_GAIN * level
	}
}

// An echo every length samples, which loses its highs by damping on each pass.
comb_filter :: proc(comb: ^Comb, length: int, input, feedback, damping: f32) -> f32 {
	echo := comb.ring[comb.at]
	comb.damped = echo * (1 - damping) + comb.damped * damping
	comb.ring[comb.at] = input + comb.damped * feedback
	comb.at = (comb.at + 1) % length
	return echo
}

// Passes every frequency at the same level and smears it in time.
allpass_filter :: proc(allpass: ^Allpass, length: int, input: f32) -> f32 {
	delayed := allpass.ring[allpass.at]
	allpass.ring[allpass.at] = input + delayed * ALLPASS_FEEDBACK
	allpass.at = (allpass.at + 1) % length
	return delayed - input
}
