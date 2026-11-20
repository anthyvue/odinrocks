package ui

import "core:c"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

BACKGROUND :: rl.Color{24, 24, 28, 255}
FIELD :: rl.Color{36, 36, 42, 255}
HOVER :: rl.Color{46, 46, 54, 255}
DIM :: rl.Color{150, 150, 156, 255}
TEXT :: rl.Color{210, 210, 214, 255}
GOLD :: rl.Color{232, 192, 64, 255}
ERROR :: rl.Color{230, 110, 100, 255}

// The layout is in units of a 1920x1080 screen. Every procedure here scales units to the pixels of the window, so nothing is drawn at a lower resolution.
REFERENCE_WIDTH :: 1920
REFERENCE_HEIGHT :: 1080

GAP :: 12

Text_Size :: enum {
	Small,
	Body,
	Title,
}

@(rodata)
TEXT_HEIGHTS := [Text_Size]f32 {
	.Small = 24,
	.Body  = 30,
	.Title = 42,
}

// The default font is a 10 px bitmap. Its glyph pixels stay even only at multiples of 10 px.
FONT_PIXEL_STEP :: 10

// x, y, w and h are units.
Rect :: struct {
	x, y, w, h: int,
}

Row :: struct {
	x, y, h: int,
}

// Returns the next rect of the row and moves the row past it.
take :: proc(row: ^Row, width: int) -> Rect {
	rect := Rect{row.x, row.y, width, row.h}
	row.x += width + GAP
	return rect
}

// Escape and the right mouse button both go back.
is_back_pressed :: proc() -> bool {
	return rl.IsKeyPressed(.ESCAPE) || rl.IsMouseButtonPressed(.RIGHT)
}

button :: proc(rect: Rect, label: string, enabled := true) -> (clicked: bool) {
	hovered := enabled && is_hovered(rect)
	draw_box(rect, hovered, GOLD if enabled else FIELD)
	draw_label(rect, label, TEXT if enabled else DIM)
	return hovered && rl.IsMouseButtonPressed(.LEFT)
}

// A click flips on.
toggle :: proc(rect: Rect, on: ^bool) {
	hovered := is_hovered(rect)
	if hovered && rl.IsMouseButtonPressed(.LEFT) do on^ = !on^
	draw_box(rect, hovered, GOLD if on^ else DIM)
	draw_label(rect, "on" if on^ else "off", GOLD if on^ else DIM)
}

radio :: proc(rect: Rect, label: string, selected: bool) -> (clicked: bool) {
	DOT :: 27
	dot := Rect{rect.x, rect.y + (rect.h - DOT) / 2, DOT, DOT}
	if selected do draw_rect(dot, GOLD)
	else do draw_outline(dot, TEXT)
	draw_text_in_row(label, rect.x + DOT + 15, rect, .Body, GOLD if selected else TEXT)
	return is_hovered(rect) && rl.IsMouseButtonPressed(.LEFT)
}

// A click flips checked.
checkbox :: proc(rect: Rect, label: string, checked: ^bool) {
	BOX :: 27
	box := Rect{rect.x, rect.y + (rect.h - BOX) / 2, BOX, BOX}
	if is_hovered(rect) && rl.IsMouseButtonPressed(.LEFT) do checked^ = !checked^
	draw_outline(box, GOLD if checked^ else TEXT)
	if checked^ do draw_rect({box.x + 6, box.y + 6, BOX - 12, BOX - 12}, GOLD)
	draw_text_in_row(label, box.x + BOX + 15, rect, .Body, GOLD if checked^ else TEXT)
}

// A click on the left half subtracts unit from value, the right half adds it. Shift makes it five units. The result is clamped to low..high.
step_number :: proc(rect: Rect, label: string, value: ^int, low, high: int, unit := 1) {
	hovered := is_hovered(rect)
	draw_box(rect, hovered, DIM)
	draw_text_in_row("<", rect.x + 15, rect, .Body, DIM)
	draw_text_in_row(label, rect.x + 42, rect, .Body, GOLD)
	draw_text_in_row(">", rect.x + rect.w - 30, rect, .Body, DIM)
	if !hovered || !rl.IsMouseButtonPressed(.LEFT) do return

	step := unit if mouse_position().x >= f32(rect.x + rect.w / 2) else -unit
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do step *= 5
	value^ = clamp(value^ + step, low, high)
}

// Appends this frame's typed digits and the digits pasted with Ctrl+V to digits, up to limit digits, and handles Backspace.
edit_digits :: proc(rect: Rect, digits: ^strings.Builder, placeholder: string, limit: int) {
	for char := rl.GetCharPressed(); char != 0; char = rl.GetCharPressed() do write_digit(digits, char, limit)
	pasting := (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) && rl.IsKeyPressed(.V)
	if pasting do for char in string(rl.GetClipboardText()) do write_digit(digits, char, limit)
	if rl.IsKeyPressed(.BACKSPACE) || rl.IsKeyPressedRepeat(.BACKSPACE) do strings.pop_byte(digits)

	text := strings.to_string(digits^)
	draw_box(rect, false, GOLD)
	if len(text) == 0 do draw_label(rect, placeholder, DIM)
	else do draw_label(rect, text, TEXT)
}

// Appends char to digits when it is a digit and digits holds fewer than limit digits. Other characters, such as the spaces around a pasted id, are skipped.
@(private)
write_digit :: proc(digits: ^strings.Builder, char: rune, limit: int) {
	if char >= '0' && char <= '9' && strings.builder_len(digits^) < limit do strings.write_byte(digits, u8(char))
}

// Highlights rect while the mouse is over it inside view, the visible part of a scrolled list.
row_button :: proc(rect, view: Rect) -> (clicked: bool) {
	hovered := is_hovered(rect) && is_hovered(view)
	if hovered do draw_rect(rect, HOVER)
	return hovered && rl.IsMouseButtonPressed(.LEFT)
}

// Applies the mouse wheel to offset while view is hovered, then keeps offset inside the content.
scroll :: proc(view: Rect, offset: ^int, content_height: int) {
	if is_hovered(view) do offset^ -= int(rl.GetMouseWheelMove() * 60)
	offset^ = clamp(offset^, 0, max(content_height - view.h, 0))
}

begin_clip :: proc(view: Rect) {
	pixels := to_screen(view)
	rl.BeginScissorMode(c.int(pixels.x), c.int(pixels.y), c.int(pixels.width), c.int(pixels.height))
}

end_clip :: rl.EndScissorMode

@(private)
draw_label :: proc(rect: Rect, text: string, color: rl.Color) {
	draw_text_in_row(text, rect.x + 15, rect, .Body, color)
}

// Draws text with its top left corner at x, y.
draw_text :: proc(text: string, x, y: int, size: Text_Size, color: rl.Color) {
	s := scale()
	draw_text_pixels(text, math.round(f32(x) * s), math.round(f32(y) * s), text_pixels(size), color)
}

// Draws text from x, centered vertically on row. Only the y and h of row matter.
draw_text_in_row :: proc(text: string, x: int, row: Rect, size: Text_Size, color: rl.Color) {
	band := to_screen(row)
	height := text_pixels(size)
	left := math.round(f32(x) * scale())
	top := band.y + math.floor((band.height - f32(height)) / 2)
	draw_text_pixels(text, left, top, height, color)
}

draw_rect :: proc(rect: Rect, color: rl.Color) {
	rl.DrawRectangleRec(to_screen(rect), color)
}

// The line is one unit thick, and at least one pixel.
@(private)
draw_outline :: proc(rect: Rect, color: rl.Color) {
	rl.DrawRectangleLinesEx(to_screen(rect), max(math.round(scale()), 1), color)
}

is_hovered :: proc(rect: Rect) -> bool {
	mouse := mouse_position()
	return f32(rect.x) <= mouse.x && mouse.x < f32(rect.x + rect.w) && f32(rect.y) <= mouse.y && mouse.y < f32(rect.y + rect.h)
}

// The mouse in units.
mouse_position :: proc() -> rl.Vector2 {
	return rl.GetMousePosition() / scale()
}

// The window in units. One side is the reference size and the other is at least as large.
size :: proc() -> (width, height: int) {
	s := scale()
	width = int(math.round(f32(rl.GetScreenWidth()) / s))
	height = int(math.round(f32(rl.GetScreenHeight()) / s))
	return
}

@(private)
draw_box :: proc(rect: Rect, hovered: bool, outline: rl.Color) {
	draw_rect(rect, HOVER if hovered else FIELD)
	draw_outline(rect, outline)
}

// Pixels per unit. The whole reference screen fits the window.
@(private)
scale :: proc() -> f32 {
	return min(f32(rl.GetScreenWidth()) / REFERENCE_WIDTH, f32(rl.GetScreenHeight()) / REFERENCE_HEIGHT)
}

// Rounds the edges, not the size, so rects that touch in units also touch on screen.
@(private)
to_screen :: proc(rect: Rect) -> rl.Rectangle {
	s := scale()
	left := math.round(f32(rect.x) * s)
	top := math.round(f32(rect.y) * s)
	right := math.round(f32(rect.x + rect.w) * s)
	bottom := math.round(f32(rect.y + rect.h) * s)
	return {left, top, right - left, bottom - top}
}

// The height of text in pixels, rounded to the step of the bitmap font.
@(private)
text_pixels :: proc(size: Text_Size) -> c.int {
	steps := max(math.round(TEXT_HEIGHTS[size] * scale() / FONT_PIXEL_STEP), 1)
	return c.int(steps) * FONT_PIXEL_STEP
}

@(private)
draw_text_pixels :: proc(text: string, x, y: f32, height: c.int, color: rl.Color) {
	rl.DrawText(strings.clone_to_cstring(text, context.temp_allocator), c.int(x), c.int(y), height, color)
}
