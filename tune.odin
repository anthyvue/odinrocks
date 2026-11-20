package main

import "core:math"
import "core:sync"
import "menu"
import "pitch"
import "songsterr"
import rl "vendor:raylib"

// The newest samples that pitch.detect reads each frame: 85 ms, two periods of its lowest note and some more.
PITCH_WINDOW :: 4096
// The time constant of the needle: it moves 63% of the way to a steady reading in this time. It hides the jitter of single readings.
NEEDLE_EASE_SECONDS :: 0.15

// The newest samples of the guitar. The ASIO thread writes them while the tuner reads them, so they stay put.
// The ring holds two windows, so a buffer written during a copy lands on samples older than the window.
Guitar_History :: struct {
	ring:    [2 * PITCH_WINDOW]f32,
	// The number of samples written so far. Sample n is in ring[n % len(ring)].
	written: int,
}

// The tuner of guitar, from the low string. back is the menu that the tuner returns to.
start_tuner :: proc(back: Sync_Screen, guitar: songsterr.Guitar_Track) -> Tuner_Screen {
	return {back = back, guitar = guitar, string_index = len(guitar.tuning) - 1}
}

// Draws one frame of the tuner, which listens to history and tunes from guitar_tuning, the tuning the player's guitar had. Applies the input of that frame to tuner.
// Returns what else the player asked for.
tune_frame :: proc(tuner: ^Tuner_Screen, history: ^Guitar_History, guitar_tuning: []int) -> menu.Tuner_Action {
	target := tuner.guitar.tuning[tuner.string_index]
	if cents, heard := listen_for_cents(history, target); heard do tuner.needle = ease_needle(tuner.needle, cents, rl.GetFrameTime())

	tuned_string := tuner.string_index
	action := menu.show_tuner(tuner.back.sync.heading, tuner.guitar, guitar_tuning, &tuner.string_index, tuner.needle)
	if tuner.string_index != tuned_string do tuner.needle = nil
	return action
}

// Appends samples to history. Only one thread may record, the ASIO thread, while the tuner reads.
record_guitar :: proc(history: ^Guitar_History, samples: []f32) {
	written := sync.atomic_load(&history.written)
	for sample, index in samples do history.ring[(written + index) % len(history.ring)] = sample
	sync.atomic_store(&history.written, written + len(samples))
}

// How many cents the newest samples of history are above the nearest octave of MIDI note target. heard is false while no clear note plays.
listen_for_cents :: proc(history: ^Guitar_History, target: int) -> (cents: f32, heard: bool) {
	window: [PITCH_WINDOW]f32
	copy_newest(history, window[:])
	hz := pitch.detect(window[:]) or_return
	return pitch.cents_from_note(hz, target), true
}

// Fills window with the newest len(window) samples of history, oldest first. The ones from before the first buffer are 0.
copy_newest :: proc(history: ^Guitar_History, window: []f32) {
	start := sync.atomic_load(&history.written) - len(window)
	for &sample, index in window do sample = history.ring[(start + index) %% len(history.ring)]
}

// Moves needle toward cents by the part of NEEDLE_EASE_SECONDS that seconds is. The first reading sets it.
ease_needle :: proc(needle: Maybe(f32), cents: f32, seconds: f32) -> f32 {
	shown, ok := needle.?
	if !ok do return cents
	return shown + (cents - shown) * (1 - math.exp(-seconds / NEEDLE_EASE_SECONDS))
}
