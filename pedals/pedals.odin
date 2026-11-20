// The sound of the guitar: a NAM capture of a rig, with an input level, a gate, a drop, a delay, and a reverb around it.
// The window sets the knobs, and the audio thread plays each buffer of the guitar through the rack.
package pedals

import "core:math"
import "core:os"
import "core:path/filepath"
import "core:simd/x86"
import "core:slice"
import "core:strings"
import "core:sync"
import "../nam"
import "../pcm"

// Every NAM capture in this folder is a rig to choose. The README credits them.
RIGS_DIR :: "models"
DEFAULT_RIG :: "Crunch - Marshall JVM OD2 red.nam"
// The gate stays open 50 ms after the last sample above its threshold: longer than a period of the lowest string, so a fading note does not chatter.
GATE_HOLD_SAMPLES :: pcm.SAMPLE_RATE / 20
// The part of the way to open or closed that the gate moves per sample. It opens in about 1 ms and fades out in about 100 ms, so it does not click.
GATE_OPEN_RATE :: f32(1.0 / 48)
GATE_CLOSE_RATE :: f32(1.0 / 4800)
DROP_WINDOW :: 2048
MAX_DELAY_SAMPLES :: DELAY_MS.high * pcm.SAMPLE_RATE / 1000
// The x86 control bits that flush denormal floats to zero, in results (FTZ) and in inputs (DAZ, which core:simd/x86 does not name).
@(private)
FLUSH_DENORMALS :: x86._MM_FLUSH_ZERO_ON | 0x0040

// The lowest and the highest value of a knob or of the drop. The tone editor steps a knob inside its range, and clamp_knobs puts a loaded knob inside it.
Range :: struct {
	low, high: int,
}

INPUT_DB :: Range{-24, 12}
GATE_DB :: Range{-90, -20}
// Down to an octave.
DROP_SEMITONES :: Range{-12, -1}
DELAY_MS :: Range{50, 1000}
// More feedback than this rings on forever.
DELAY_FEEDBACK_PERCENT :: Range{0, 90}
PERCENT :: Range{0, 100}

// The pedals around the rig. Levels are beside the guitar, which always plays at full level.
Knobs :: struct {
	// The level of the guitar into the rig. Like the gain of an amp, more drives it harder.
	input_db:               int,
	// The gate opens on a sample louder than this, in dB from full scale, before the rig makes the hiss loud.
	gate_db:                int,
	delay_ms:               int,
	// How much of each echo comes back as the next one.
	delay_feedback_percent: int,
	delay_level_percent:    int,
	// How long the room rings.
	reverb_size_percent:    int,
	// How fast the highs of the room fade, so a damped room sounds darker.
	reverb_damping_percent: int,
	reverb_level_percent:   int,
}

DEFAULT_KNOBS :: Knobs {
	input_db               = 0,
	gate_db                = -70,
	delay_ms               = 380,
	delay_feedback_percent = 30,
	delay_level_percent    = 0,
	reverb_size_percent    = 50,
	reverb_damping_percent = 50,
	reverb_level_percent   = 15,
}

clamp_knobs :: proc(knobs: Knobs) -> Knobs {
	clamped := knobs
	clamped.input_db = clamp_to(knobs.input_db, INPUT_DB)
	clamped.gate_db = clamp_to(knobs.gate_db, GATE_DB)
	clamped.delay_ms = clamp_to(knobs.delay_ms, DELAY_MS)
	clamped.delay_feedback_percent = clamp_to(knobs.delay_feedback_percent, DELAY_FEEDBACK_PERCENT)
	clamped.delay_level_percent = clamp_to(knobs.delay_level_percent, PERCENT)
	clamped.reverb_size_percent = clamp_to(knobs.reverb_size_percent, PERCENT)
	clamped.reverb_damping_percent = clamp_to(knobs.reverb_damping_percent, PERCENT)
	clamped.reverb_level_percent = clamp_to(knobs.reverb_level_percent, PERCENT)
	return clamped
}

@(private)
clamp_to :: proc(value: int, range: Range) -> int {
	return clamp(value, range.low, range.high)
}

gain_from_db :: proc(db: int) -> f32 {
	return math.pow(10, f32(db) / 20)
}

// The drop that makes a guitar in guitar_tuning sound in song_tuning. A tuning is the MIDI note of each open string.
// ok is false unless every string of the song is the same amount lower, inside DROP_SEMITONES.
drop_for_tuning :: proc(guitar_tuning, song_tuning: []int) -> (semitones: int, ok: bool) {
	if len(guitar_tuning) != len(song_tuning) do return 0, false
	semitones = song_tuning[0] - guitar_tuning[0]
	for note, index in song_tuning do if note - guitar_tuning[index] != semitones do return 0, false
	if semitones < DROP_SEMITONES.low || semitones > DROP_SEMITONES.high do return 0, false
	return semitones, true
}

// The file names of the rigs in RIGS_DIR, sorted, which puts them from clean to lead. The caller owns them.
list_rigs :: proc() -> []string {
	infos, err := os.read_all_directory_by_path(RIGS_DIR, context.temp_allocator)
	if err != nil do panic("the rigs folder " + RIGS_DIR + " is missing")
	rigs: [dynamic]string
	for info in infos do if strings.equal_fold(filepath.ext(info.name), ".nam") do append(&rigs, strings.clone(info.name))
	slice.sort(rigs[:])
	return rigs[:]
}

// rig is a file name in RIGS_DIR. The loaded rig plays buffers of up to max_frames.
load_rig :: proc(rig: string, max_frames: int) -> nam.Model {
	path := filepath.join({RIGS_DIR, rig}, context.temp_allocator) or_else panic("rig path")
	return nam.load(path, max_frames)
}

// The rig and the pedals around it, and what they remember between buffers. init loads the rig, destroy frees it.
// It stays put while a thread runs shape. Only that thread touches playing and the fields after it.
Rack :: struct {
	// set_knobs writes knobs under knobs_lock. shape copies them into playing when the lock is free, and else plays with the knobs of its last buffer, so the audio thread never waits.
	knobs_lock:     sync.Mutex,
	knobs:          Knobs,
	// Atomic. set_drop writes it, and 0 turns the drop off.
	drop_semitones: int,
	playing:        Knobs,
	rig:            nam.Model,
	gate:           Gate,
	drop:           Drop,
	delay:          Delay,
	reverb:         Reverb,
}

@(private)
Gate :: struct {
	gain:      f32,
	hold_left: int,
}

@(private)
Drop :: struct {
	ring:  [DROP_WINDOW]f32,
	write: int,
	head:  f32,
}

@(private)
Delay :: struct {
	ring:  [MAX_DELAY_SAMPLES]f32,
	write: int,
}

// rig is a file name in RIGS_DIR, loaded for buffers of up to max_frames. The first buffer plays with knobs.
init :: proc(rack: ^Rack, rig: string, knobs: Knobs, max_frames: int) {
	rack.rig = load_rig(rig, max_frames)
	rack.knobs = knobs
	rack.playing = knobs
}

destroy :: proc(rack: ^Rack) {
	nam.destroy(rack.rig)
}

// Puts loaded in place of the rig of rack, and frees the rig before. No thread may run shape meanwhile.
replace_rig :: proc(rack: ^Rack, loaded: nam.Model) {
	nam.destroy(rack.rig)
	rack.rig = loaded
}

// Hands knobs to the thread that runs shape, which plays with them from its next buffer.
set_knobs :: proc(rack: ^Rack, knobs: Knobs) {
	sync.mutex_lock(&rack.knobs_lock)
	rack.knobs = knobs
	sync.mutex_unlock(&rack.knobs_lock)
}

// Lowers the guitar by semitones, a value of DROP_SEMITONES, from the next buffer that shape plays. 0 turns the drop off.
set_drop :: proc(rack: ^Rack, semitones: int) {
	sync.atomic_store(&rack.drop_semitones, semitones)
}

// Plays buffer through the pedals and the rig of rack, in place.
shape :: proc(rack: ^Rack, buffer: []f32) {
	knobs := take_latest_knobs(rack)
	input_gain := gain_from_db(knobs.input_db)
	for &sample in buffer do sample *= input_gain
	shape_gate(&rack.gate, knobs.gate_db, buffer)
	drop_semitones := sync.atomic_load(&rack.drop_semitones)
	if drop_semitones != 0 do shape_drop(&rack.drop, drop_semitones, buffer)
	nam.process(rack.rig, buffer)
	shape_delay(&rack.delay, knobs, buffer)
	shape_reverb(&rack.reverb, knobs, buffer)
}

// The tails of the gate, the delay, and the reverb fade into denormal floats, which x86 handles many times slower.
// This makes the calling thread, the one that runs shape, treat them as zero. Every x86-64 CPU has SSE.
@(enable_target_feature = "sse")
flush_denormals_on_this_thread :: proc "contextless" () {
	x86._mm_setcsr(x86._mm_getcsr() | FLUSH_DENORMALS)
}

@(private)
take_latest_knobs :: proc(rack: ^Rack) -> Knobs {
	if sync.mutex_try_lock(&rack.knobs_lock) {
		rack.playing = rack.knobs
		sync.mutex_unlock(&rack.knobs_lock)
	}
	return rack.playing
}

// Silences buffer, in place, while it stays below threshold_db.
@(private)
shape_gate :: proc(gate: ^Gate, threshold_db: int, buffer: []f32) {
	threshold := gain_from_db(threshold_db)
	for &sample in buffer {
		if abs(sample) > threshold do gate.hold_left = GATE_HOLD_SAMPLES
		else if gate.hold_left > 0 do gate.hold_left -= 1
		if gate.hold_left > 0 do gate.gain += (1 - gate.gain) * GATE_OPEN_RATE
		else do gate.gain -= gate.gain * GATE_CLOSE_RATE
		sample *= gate.gain
	}
}

// Lowers buffer by semitones, in place. Two read heads half a window apart trail the write head at the pitch ratio. Each fades out as it nears the write head, where it jumps.
@(private)
shape_drop :: proc(drop: ^Drop, semitones: int, buffer: []f32) {
	ratio := math.pow(2, f32(semitones) / 12)
	for &sample in buffer {
		drop.ring[drop.write] = sample
		far := wrap_window(drop.head + DROP_WINDOW / 2)
		sample = read_ring(drop, drop.head) * head_weight(drop, drop.head) + read_ring(drop, far) * head_weight(drop, far)
		drop.head = wrap_window(drop.head + ratio)
		drop.write = (drop.write + 1) % DROP_WINDOW
	}
}

@(private)
read_ring :: proc(drop: ^Drop, position: f32) -> f32 {
	index := int(position)
	next := (index + 1) % DROP_WINDOW
	fraction := position - f32(index)
	return drop.ring[index] + (drop.ring[next] - drop.ring[index]) * fraction
}

@(private)
head_weight :: proc(drop: ^Drop, position: f32) -> f32 {
	distance := f32(drop.write) - position
	if distance < 0 do distance += DROP_WINDOW
	half := f32(DROP_WINDOW) / 2
	return 1 - abs(distance - half) / half
}

@(private)
wrap_window :: proc(position: f32) -> f32 {
	return position - DROP_WINDOW if position >= DROP_WINDOW else position
}

// Adds echoes of buffer to it, in place.
@(private)
shape_delay :: proc(delay: ^Delay, knobs: Knobs, buffer: []f32) {
	length := knobs.delay_ms * pcm.SAMPLE_RATE / 1000
	feedback := from_percent(knobs.delay_feedback_percent)
	level := from_percent(knobs.delay_level_percent)
	for &sample in buffer {
		echo := delay.ring[(delay.write - length) %% MAX_DELAY_SAMPLES]
		delay.ring[delay.write] = sample + echo * feedback
		delay.write = (delay.write + 1) % MAX_DELAY_SAMPLES
		sample += echo * level
	}
}

@(private)
from_percent :: proc(percent: int) -> f32 {
	return f32(percent) / 100
}
