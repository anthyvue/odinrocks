package render

import "core:fmt"
import "../chart"
import "../ui"
import rl "vendor:raylib"

PROGRESS_Y :: 0
PROGRESS_HEIGHT :: 24
PROGRESS_HIT_HEIGHT :: 36
HUD_MARGIN :: 36
STATUS_Y :: 48
STATUS_HEIGHT :: 27
HIT_FLASH :: 0.012
HIT_FLASH_SIZE :: 213

// The song clock in seconds, the guitar gain, the A/V offset, and the guitar input level as a bar.
draw_status :: proc(song_seconds: f64, gain: f32, av_offset_ms: int, level: f32) {
	width, _ := ui.size()
	row := ui.Rect{0, STATUS_Y, width, STATUS_HEIGHT}
	ui.draw_text_in_row(fmt.tprintf("%.2f", song_seconds), HUD_MARGIN, row, .Body, ui.TEXT)
	ui.draw_text_in_row(fmt.tprintf("gain %.1f", gain), 375, row, .Body, ui.TEXT)
	ui.draw_text_in_row(fmt.tprintf("av %+d ms", av_offset_ms), 600, row, .Body, ui.TEXT)
	meter_width := width / 3
	meter := ui.Rect{width - meter_width - HUD_MARGIN, STATUS_Y, meter_width, STATUS_HEIGHT}
	ui.draw_rect(meter, ui.FIELD)
	meter.w = int(clamp(level, 0, 1) * f32(meter_width))
	ui.draw_rect(meter, ui.GOLD)
}

draw_hit_flash :: proc(now: f64, gems: []chart.Gem) {
	for gem in gems {
		if gem.time < now - HIT_FLASH do continue
		if gem.time > now + HIT_FLASH do break
		_, height := ui.size()
		ui.draw_rect({HUD_MARGIN, height - HIT_FLASH_SIZE - HUD_MARGIN, HIT_FLASH_SIZE, HIT_FLASH_SIZE}, rl.WHITE)
		return
	}
}

draw_song_progress :: proc(song_frame, song_frames: int) {
	width, _ := ui.size()
	ui.draw_rect({0, PROGRESS_Y, width, PROGRESS_HEIGHT}, ui.FIELD)
	if song_frames <= 0 do return

	played_width := clamp(int(f64(song_frame) * f64(width) / f64(song_frames)), 0, width)
	ui.draw_rect({0, PROGRESS_Y, played_width, PROGRESS_HEIGHT}, ui.GOLD)
}

is_mouse_on_progress_bar :: proc() -> bool {
	width, _ := ui.size()
	return ui.is_hovered({0, PROGRESS_Y, width, PROGRESS_HIT_HEIGHT})
}

// The song frame under the mouse, along the progress bar.
frame_at_mouse :: proc(song_frames: int) -> int {
	width, _ := ui.size()
	fraction := clamp(f64(ui.mouse_position().x) / f64(width - 1), 0, 1)
	return int(fraction * f64(song_frames))
}
