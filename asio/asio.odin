// The guitar input: one channel of an ASIO driver. It converts each buffer to f32, keeps its peak, and hands it to one listener on the driver thread.
package asio

import "base:runtime"
import "core:fmt"
import "core:sync"
import win "core:sys/windows"
import "../pcm"

ASIO_TRUE :: i32(1)
ASE_OK :: i32(0)
// RPC_E_CHANGED_MODE, which core:sys/windows does not name: COM is already initialized on this thread in another mode.
COM_CHANGED_MODE :: win.HRESULT(transmute(i32)u32(0x80010106))

@(private)
Sample_Type :: enum i32 {
	Int16_LSB   = 16,
	Int24_LSB   = 17,
	Int32_LSB   = 18,
	Float32_LSB = 19,
	Int32_LSB24 = 27,
}

// The messages a driver can send to on_asio_message. The app handles all of them.
@(private)
Asio_Message :: enum i32 {
	Selector_Supported = 1,
	Engine_Version     = 2,
	Reset_Request      = 3,
	Buffer_Size_Change = 4,
}

@(private)
Asio_Buffer_Info :: struct {
	isInput:    b32,
	channelNum: i32,
	buffers:    [2]rawptr,
}

@(private)
Asio_Channel_Info :: struct {
	channel:      i32,
	isInput:      b32,
	isActive:     b32,
	channelGroup: i32,
	sampleType:   Sample_Type,
	name:         [32]byte,
}

@(private)
Asio_Callbacks :: struct {
	bufferSwitch:         proc "c" (index, directProcess: i32),
	sampleRateDidChange:  proc "c" (rate: f64),
	asioMessage:          proc "c" (selector: Asio_Message, value: i32, message: rawptr, opt: ^f64) -> i32,
	bufferSwitchTimeInfo: proc "c" (params: rawptr, index, directProcess: i32) -> rawptr,
}

@(private)
Iasio :: struct {
	using vtable: ^Iasio_Vtable,
}

@(private)
Iasio_Vtable :: struct {
	QueryInterface:    proc "system" (this: ^Iasio, riid: win.REFIID, ppvObject: ^rawptr) -> win.HRESULT,
	AddRef:            proc "system" (this: ^Iasio) -> win.ULONG,
	Release:           proc "system" (this: ^Iasio) -> win.ULONG,
	init:              proc "system" (this: ^Iasio, sysHandle: rawptr) -> i32,
	getDriverName:     proc "system" (this: ^Iasio, name: rawptr),
	getDriverVersion:  proc "system" (this: ^Iasio) -> i32,
	getErrorMessage:   proc "system" (this: ^Iasio, text: rawptr),
	start:             proc "system" (this: ^Iasio) -> i32,
	stop:              proc "system" (this: ^Iasio) -> i32,
	getChannels:       proc "system" (this: ^Iasio, numInputs, numOutputs: ^i32) -> i32,
	getLatencies:      proc "system" (this: ^Iasio, inputLatency, outputLatency: ^i32) -> i32,
	getBufferSize:     proc "system" (this: ^Iasio, minSize, maxSize, preferredSize, granularity: ^i32) -> i32,
	canSampleRate:     proc "system" (this: ^Iasio, sampleRate: f64) -> i32,
	getSampleRate:     proc "system" (this: ^Iasio, sampleRate: ^f64) -> i32,
	setSampleRate:     proc "system" (this: ^Iasio, sampleRate: f64) -> i32,
	getClockSources:   proc "system" (this: ^Iasio, clocks: rawptr, numSources: ^i32) -> i32,
	setClockSource:    proc "system" (this: ^Iasio, reference: i32) -> i32,
	getSamplePosition: proc "system" (this: ^Iasio, position, timeStamp: rawptr) -> i32,
	getChannelInfo:    proc "system" (this: ^Iasio, info: ^Asio_Channel_Info) -> i32,
	createBuffers:     proc "system" (this: ^Iasio, infos: ^Asio_Buffer_Info, numChannels, bufferSize: i32, callbacks: ^Asio_Callbacks) -> i32,
	disposeBuffers:    proc "system" (this: ^Iasio) -> i32,
	controlPanel:      proc "system" (this: ^Iasio) -> i32,
	future:            proc "system" (this: ^Iasio, selector: i32, opt: rawptr) -> i32,
	outputReady:       proc "system" (this: ^Iasio) -> i32,
}

// Hears each buffer of the guitar channel on the driver thread, after it is converted to f32. samples are valid only during the call.
// data is what hear gets back, so it must stay put until close.
Listener :: struct {
	hear: proc(data: rawptr, samples: []f32),
	data: rawptr,
}

// The driver calls the callbacks with no user pointer, so the open session lives here.
@(private)
Session :: struct {
	driver:         ^Iasio,
	sample_type:    Sample_Type,
	buffer_frames:  i32,
	buffer_info:    Asio_Buffer_Info,
	callbacks:      Asio_Callbacks,
	// Each buffer of the guitar channel, converted to f32 for the listener.
	samples:        []f32,
	peak:           f32,
	reset:          bool,
	guitar_channel: i32,
	listener:       Listener,
}

@(private)
state: Session

buffer_frames :: proc() -> int {
	return int(state.buffer_frames)
}

// The loudest sample of the latest buffer, where 1 is full scale. 0 while the driver is closed.
peak :: proc() -> f32 {
	return sync.atomic_load(&state.peak)
}

// Whether the driver asked to be closed and opened again, when its buffer size changed for example.
reset_requested :: proc() -> bool {
	return sync.atomic_load(&state.reset)
}

// Loads driver and prepares guitar_channel for input. window is the main window of the app, which the driver may use as the parent of its dialogs.
// listener hears every buffer from start until stop or close. failure says why the driver did not open, for the player; then nothing needs closing.
open :: proc(driver: string, guitar_channel: int, window: rawptr, listener: Listener) -> (failure: Maybe(string)) {
	// ASIO drivers register as ThreadingModel=Apartment, so this thread has to enter the STA before miniaudio initializes COM as multithreaded.
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	if hr == COM_CHANGED_MODE do panic("asio.open must run before miniaudio initializes COM")
	if !win.SUCCEEDED(hr) do panic("CoInitializeEx failed")
	defer if failure != nil do release_driver()

	state.guitar_channel = i32(guitar_channel)
	state.listener = listener
	load_driver(driver, window) or_return
	configure_input() or_return
	state.samples = make([]f32, state.buffer_frames)
	return nil
}

start :: proc() {
	require_ok(state.driver->start(), "ASIO start")
}

// Stops the buffers until the next start. The driver calls no callback once it returns, so the listener is not running.
stop :: proc() {
	require_ok(state.driver->stop(), "ASIO stop")
}

close :: proc() {
	state.driver->stop()
	state.driver->disposeBuffers()
	delete(state.samples)
	release_driver()
}

// The names of the drivers registered under HKLM\SOFTWARE\ASIO, in registry order. Empty when none is installed.
list_drivers :: proc() -> []string {
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, win.L("SOFTWARE\\ASIO"), 0, win.KEY_READ, &key) != 0 do return nil
	defer win.RegCloseKey(key)

	names: [dynamic]string
	for index: u32 = 0; ; index += 1 {
		wide: [256]u16
		length := u32(len(wide))
		if win.RegEnumKeyExW(key, index, raw_data(wide[:]), &length, nil, nil, nil, nil) != 0 do break
		name, _ := win.utf16_to_utf8(wide[:length], context.allocator)
		append(&names, name)
	}
	return names[:]
}

// Releases what open loaded before its buffers: the driver, if it loaded, and COM.
@(private)
release_driver :: proc() {
	if state.driver != nil do state.driver->Release()
	win.CoUninitialize()
	state = {}
}

@(private)
require_ok :: proc(result: i32, what: string) {
	if failure, failed := check(result, what).?; failed do panic(failure)
}

// Why the driver failed at what, or nil when result is ASE_OK.
@(private)
check :: proc(result: i32, what: string) -> Maybe(string) {
	if result == ASE_OK do return nil
	return fmt.tprintf("%s: %s", what, driver_message())
}

@(private)
driver_message :: proc() -> string {
	text: [128]byte
	state.driver->getErrorMessage(&text)
	return fmt.tprint(cstring(&text[0]))
}

@(private)
load_driver :: proc(name: string, window: rawptr) -> Maybe(string) {
	key: win.HKEY
	subkey := win.utf8_to_wstring(fmt.tprintf("SOFTWARE\\ASIO\\%s", name))
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, subkey, 0, win.KEY_READ, &key) != 0 do return fmt.tprintf("%s is not registered", name)
	defer win.RegCloseKey(key)

	clsid_text: [80]u16
	size: u32 = size_of(clsid_text)
	if win.RegGetValueW(key, nil, win.L("CLSID"), win.RRF_RT_REG_SZ, nil, raw_data(clsid_text[:]), &size) != 0 do return "its registry key has no CLSID"

	clsid: win.GUID
	if !win.SUCCEEDED(win.CLSIDFromString(win.wstring(raw_data(clsid_text[:])), &clsid)) do return "its CLSID does not parse"

	raw: rawptr
	// ASIO drivers return the driver object when asked for their own class id.
	if !win.SUCCEEDED(win.CoCreateInstance(&clsid, nil, win.CLSCTX_INPROC_SERVER, &clsid, &raw)) do return "Windows cannot load it"
	state.driver = (^Iasio)(raw)

	if state.driver->init(window) != ASIO_TRUE do return fmt.tprintf("it does not start, so the interface may be unplugged: %s", driver_message())
	return nil
}

@(private)
configure_input :: proc() -> Maybe(string) {
	inputs, outputs: i32
	check(state.driver->getChannels(&inputs, &outputs), "getChannels") or_return
	if inputs <= state.guitar_channel do return fmt.tprintf("it has %d inputs, so there is no input %d", inputs, state.guitar_channel + 1)

	info := Asio_Channel_Info{channel = state.guitar_channel, isInput = true}
	check(state.driver->getChannelInfo(&info), "getChannelInfo") or_return
	#partial switch info.sampleType {
	case .Int16_LSB, .Int24_LSB, .Int32_LSB, .Float32_LSB, .Int32_LSB24:
		state.sample_type = info.sampleType
	case:
		return fmt.tprintf("its sample type %v is not supported", info.sampleType)
	}

	check(state.driver->canSampleRate(pcm.SAMPLE_RATE), "canSampleRate") or_return
	check(state.driver->setSampleRate(pcm.SAMPLE_RATE), "setSampleRate") or_return
	rate: f64
	check(state.driver->getSampleRate(&rate), "getSampleRate") or_return
	if rate != pcm.SAMPLE_RATE do return fmt.tprintf("it runs at %.0f Hz, not %d Hz", rate, pcm.SAMPLE_RATE)

	min_size, max_size, preferred, granularity: i32
	check(state.driver->getBufferSize(&min_size, &max_size, &preferred, &granularity), "getBufferSize") or_return
	state.buffer_frames = preferred

	state.callbacks = {
		bufferSwitch         = on_buffer_switch,
		sampleRateDidChange  = on_sample_rate,
		asioMessage          = on_asio_message,
		bufferSwitchTimeInfo = on_buffer_switch_time,
	}
	state.buffer_info = {isInput = true, channelNum = state.guitar_channel}
	return check(state.driver->createBuffers(&state.buffer_info, 1, state.buffer_frames, &state.callbacks), "createBuffers")
}

// The driver calls this from its own thread, which has no Odin context.
@(private)
on_buffer_switch :: proc "c" (index, _: i32) {
	context = runtime.default_context()
	deliver_guitar(index)
}

@(private)
on_buffer_switch_time :: proc "c" (params: rawptr, index, _: i32) -> rawptr {
	context = runtime.default_context()
	deliver_guitar(index)
	return params
}

@(private)
on_sample_rate :: proc "c" (_: f64) {}

@(private)
on_asio_message :: proc "c" (selector: Asio_Message, value: i32, _: rawptr, _: ^f64) -> i32 {
	switch selector {
	case .Selector_Supported:
		// value is the message the driver asks about.
		switch Asio_Message(value) {
		case .Selector_Supported, .Engine_Version, .Reset_Request, .Buffer_Size_Change:
			return 1
		}
	case .Engine_Version:
		return 2
	case .Reset_Request, .Buffer_Size_Change:
		sync.atomic_store(&state.reset, true)
		return 1
	}
	return 0
}

@(private)
deliver_guitar :: proc(index: i32) {
	raw := state.buffer_info.buffers[index]
	if raw == nil do panic("ASIO input buffer is nil")

	convert_samples(state.samples, raw)
	loudest: f32
	for sample in state.samples do loudest = max(loudest, abs(sample))
	sync.atomic_store(&state.peak, loudest)
	state.listener.hear(state.listener.data, state.samples)
}

@(private)
convert_samples :: proc(converted: []f32, raw: rawptr) {
	switch state.sample_type {
	case .Float32_LSB:
		samples := ([^]f32)(raw)
		for &sample, frame in converted do sample = samples[frame]
	case .Int16_LSB:
		samples := ([^]i16)(raw)
		for &sample, frame in converted do sample = f32(samples[frame]) / 32768
	case .Int24_LSB:
		bytes := ([^]u8)(raw)
		for &sample, frame in converted {
			value := i32(bytes[frame * 3]) | i32(bytes[frame * 3 + 1]) << 8 | i32(bytes[frame * 3 + 2]) << 16
			if value & 0x80_00_00 != 0 do value |= ~i32(0xff_ff_ff)
			sample = f32(value) / 8388608
		}
	case .Int32_LSB:
		samples := ([^]i32)(raw)
		for &sample, frame in converted do sample = f32(samples[frame]) / 2147483648
	case .Int32_LSB24:
		samples := ([^]i32)(raw)
		for &sample, frame in converted do sample = f32(samples[frame]) / 8388608
	}
}
