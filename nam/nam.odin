// A NAM capture of a guitar rig (amp and cab), played by NeuralAudio from neuralaudio.dll. The README says how the DLL was built.
package nam

import "core:fmt"
import "core:math"
import "core:os"
import win "core:sys/windows"
import "../pcm"

foreign import neuralaudio "neuralaudio.lib"

// Every rig plays a pluck that peaks at LEVELING_PEAK_DB, a firm strum, at LEVELING_RMS_DB, so a switch of rigs keeps the volume.
LEVELING_PEAK_DB :: -12
LEVELING_RMS_DB :: -20
LEVELING_SAMPLES :: pcm.SAMPLE_RATE / 2
// The silence after the pluck, so the rig does not remember the pluck when the guitar starts.
SETTLING_SAMPLES :: pcm.SAMPLE_RATE / 10

// A loaded capture. It plays buffers of up to the max_frames it was loaded with.
Model :: struct {
	loader:      ^Loader,
	model:       ^Neural_Model,
	// Brings the guitar to the level the rig was captured at, when the capture says what that was.
	input_gain:  f32,
	output_gain: f32,
}

// Loads and levels the capture at path. The captures ship with the app, so a missing one is a bug.
load :: proc(path: string, max_frames: int) -> (model: Model) {
	// NeuralAudio returns an empty model for a missing file, which crashes the first process.
	if !os.exists(path) do fmt.panicf("the NAM capture %s is missing", path)
	model.loader = CreateLoader()
	SetDefaultMaxAudioBufferSize(model.loader, i32(max_frames))
	model.model = CreateModelFromFile(model.loader, win.utf8_to_wstring(path))
	model.input_gain = gain_from_db(GetRecommendedInputDBAdjustment(model.model))
	// The leveling pluck plays at unity.
	model.output_gain = 1
	model.output_gain = leveling_gain(model, max_frames)
	return
}

destroy :: proc(model: Model) {
	DeleteModel(model.model)
	DeleteLoader(model.loader)
}

// Plays buffer through the rig, in place.
process :: proc(model: Model, buffer: []f32) {
	for &sample in buffer do sample *= model.input_gain
	Process(model.model, raw_data(buffer), raw_data(buffer), uint(len(buffer)))
	for &sample in buffer do sample *= model.output_gain
}

// The output gain that brings the leveling pluck through model to LEVELING_RMS_DB. Then silence, so the pluck has faded from the rig.
// NeuralAudio can level a capture by itself, but only one whose metadata has its loudness, which older captures lack.
@(private)
leveling_gain :: proc(model: Model, max_frames: int) -> f32 {
	buffer := make([]f32, max_frames, context.temp_allocator)
	amplitude := gain_from_db(LEVELING_PEAK_DB)
	energy: f64
	for played := 0; played < LEVELING_SAMPLES + SETTLING_SAMPLES; played += len(buffer) {
		for &sample, index in buffer {
			at := played + index
			sample = amplitude * pluck(f32(at) / pcm.SAMPLE_RATE) if at < LEVELING_SAMPLES else 0
		}
		process(model, buffer)
		for sample, index in buffer do if played + index < LEVELING_SAMPLES do energy += f64(sample * sample)
	}
	rms_db := f32(10 * math.log10(energy / LEVELING_SAMPLES))
	return gain_from_db(LEVELING_RMS_DB - rms_db)
}

// A low A string at seconds after it is picked: eight harmonics that fade out, peaking near 1.
@(private)
pluck :: proc(seconds: f32) -> f32 {
	sum: f32
	for harmonic in 1 ..= 8 do sum += math.sin(2 * math.PI * 110 * f32(harmonic) * seconds) / f32(harmonic)
	return 0.55 * sum * math.exp(-3 * seconds)
}

@(private)
gain_from_db :: proc(db: f32) -> f32 {
	return math.pow(10, db / 20)
}

@(private)
Loader :: struct {}
@(private)
Neural_Model :: struct {}

@(private, default_calling_convention = "c")
foreign neuralaudio {
	CreateLoader :: proc() -> ^Loader ---
	DeleteLoader :: proc(loader: ^Loader) ---
	SetDefaultMaxAudioBufferSize :: proc(loader: ^Loader, max_size: i32) ---
	CreateModelFromFile :: proc(loader: ^Loader, path: cstring16) -> ^Neural_Model ---
	DeleteModel :: proc(model: ^Neural_Model) ---
	GetRecommendedInputDBAdjustment :: proc(model: ^Neural_Model) -> f32 ---
	Process :: proc(model: ^Neural_Model, input, output: [^]f32, count: uint) ---
}
