package render

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "../chart"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The world is measured in frets. x runs from the nut toward the body, so fret n spans x = n-1 .. n.
// y is the height above the floor. String i is i+1 string gaps up, so the floor is one gap below the lowest string.
// z is time. The strings stand at z = 0, and the future runs away from the player, along -z.
FRET_COUNT :: 25
STRING_GAP :: f32(0.28)
Z_PER_SECOND :: f32(12)
LOOKAHEAD :: 4.5
PAST_LIMIT :: 0.05

GEM_WIDTH :: f32(0.65)
GEM_HEIGHT :: 0.8 * STRING_GAP
// Lines are thin rods, not GL lines, which stay one pixel wide at any resolution. Strings and frets are twice as thick.
LINE :: f32(0.03)
WIRE :: 2 * LINE
DIGIT_HEIGHT :: 2 * STRING_GAP

// The camera aims at a point CAMERA_AIM_Y above the nut, from CAMERA_BACK away. It backs off along that line to show more frets.
CAMERA_AIM_Y :: f32(3)
CAMERA_BACK :: rl.Vector3{0, 1.5, 8}
CAMERA_FOVY :: f32(45)
CAMERA_AHEAD :: 5.0
CAMERA_SMOOTH :: f32(0.7)
SEEK_SNAP :: 0.5
SPRING_DT_MAX :: f32(1.0 / 30)

INLAY_FRETS :: bit_set[0 ..= FRET_COUNT]{3, 5, 7, 9, 12, 15, 17, 19, 21, 24}

HIGHWAY_BACKGROUND :: rl.Color{4, 7, 16, 255}
LANE_LINE :: rl.Color{40, 78, 132, 255}
WIRE_COLOR :: rl.Color{196, 172, 128, 255}
NUT_COLOR :: rl.Color{232, 220, 186, 255}
HAND_FILL :: rl.Color{12, 22, 46, 255}
HAND_EDGE :: rl.Color{70, 214, 224, 255}
HAND_DIGIT :: rl.Color{244, 204, 72, 255}
OUT_OF_HAND_DIGIT :: rl.Color{46, 126, 138, 255}
STEM_COLOR :: rl.Color{255, 150, 40, 255}
BAR_COLOR :: rl.Color{96, 130, 184, 255}
CHORD_FRAME :: rl.Color{96, 208, 255, 255}

@(rodata)
STRING_COLORS := [chart.MAX_STRINGS]rl.Color{
	{190, 70, 235, 255},
	{50, 210, 70, 255},
	{255, 130, 20, 255},
	{50, 130, 255, 255},
	{255, 225, 30, 255},
	{255, 50, 50, 255},
	{235, 60, 200, 255},
	{40, 220, 220, 255},
}

Camera :: struct {
	center:          f32,
	width:           f32,
	center_velocity: f32,
	width_velocity:  f32,
	now:             f64,
	placed:          bool,
}

// Every part is flat or thin and is drawn back to front, so the highway needs no depth test and culls no faces.
draw_highway :: proc(camera: ^Camera, now: f64, gems: []chart.Gem, positions: []chart.Hand_Position, measure_times: []f64, string_count: int) {
	aspect := f32(rl.GetScreenWidth()) / f32(rl.GetScreenHeight())
	resting_width := visible_width(aspect)
	follow_camera(camera, now, positions, resting_width)
	view := neck_camera(camera.center, max(camera.width / resting_width, 1))
	hand := chart.hand_at(positions, now)

	rl.BeginMode3D(view)
	rlgl.DisableDepthTest()
	rlgl.DisableBackfaceCulling()
	draw_lanes()
	draw_hand_lanes(now, positions)
	draw_bar_lines(now, measure_times, positions)
	draw_guitar(string_count)
	draw_tails(now, gems, positions)
	draw_gems(now, gems, positions, string_count)
	rl.EndMode3D()
	rlgl.EnableBackfaceCulling()

	draw_fret_digits(view, hand)
	draw_gem_fret_digits(view, now, gems)
}

// scale 1 is the resting view. A larger scale backs the camera off to show more frets.
@(private)
neck_camera :: proc(center, scale: f32) -> rl.Camera3D {
	aim := rl.Vector3{center, CAMERA_AIM_Y, 0}
	return {position = aim + CAMERA_BACK * scale, target = aim, up = {0, 1, 0}, fovy = CAMERA_FOVY, projection = .PERSPECTIVE}
}

// The width the resting camera shows at its aim. aspect is the width of the window over its height.
@(private)
visible_width :: proc(aspect: f32) -> f32 {
	return 2 * linalg.length(CAMERA_BACK) * math.tan(math.to_radians(CAMERA_FOVY / 2)) * aspect
}

@(private)
follow_camera :: proc(camera: ^Camera, now: f64, positions: []chart.Hand_Position, resting_width: f32) {
	center, width := desired_frame(positions, now, resting_width)
	if !camera.placed || abs(now - camera.now) > SEEK_SNAP {
		camera^ = {center = center, width = width, placed = true}
	} else {
		dt := rl.GetFrameTime()
		spring_toward(&camera.center, &camera.center_velocity, center, dt, CAMERA_SMOOTH)
		spring_toward(&camera.width, &camera.width_velocity, width, dt, CAMERA_SMOOTH)
	}
	camera.now = now
}

// The frets the hand uses in the next CAMERA_AHEAD seconds, with one fret of margin on each side.
// The frame never gets narrower than resting_width.
@(private)
desired_frame :: proc(positions: []chart.Hand_Position, now: f64, resting_width: f32) -> (center, width: f32) {
	first, last, found := chart.fret_span_ahead(positions, now, CAMERA_AHEAD)
	if !found {
		hand := chart.hand_at(positions, now)
		first, last = hand.fret, hand.fret + hand.width - 1
	}
	left, right := fret_edges(first, last)
	return (left + right) / 2, max(right - left + 2, resting_width)
}

// Critically damped, so a new span eases in instead of starting at full speed.
@(private)
spring_toward :: proc(value, velocity: ^f32, target, dt, smooth_time: f32) {
	step := min(dt, SPRING_DT_MAX)
	omega := 2 / smooth_time
	accel := omega * omega * (target - value^) - 2 * omega * velocity^
	velocity^ += accel * step
	value^ += velocity^ * step
}

// A line on the floor under each fret wire, from the strings to the far end.
@(private)
draw_lanes :: proc() {
	far := z_at(LOOKAHEAD)
	for wire in 0 ..= FRET_COUNT {
		x := f32(wire)
		draw_line({x, 0, 0}, {x, 0, far}, LINE, NUT_COLOR if wire == 0 else LANE_LINE)
	}
}

@(private)
draw_hand_lanes :: proc(now: f64, positions: []chart.Hand_Position) {
	for position, index in positions {
		near, far := hand_depth(now, positions, index) or_continue
		left, right := hand_edges(position)
		rl.DrawPlane({(left + right) / 2, 0, (near + far) / 2}, {right - left, near - far}, HAND_FILL)
		draw_line({left, 0, near}, {left, 0, far}, LINE, HAND_EDGE)
		draw_line({right, 0, near}, {right, 0, far}, LINE, HAND_EDGE)
	}
}

@(private)
draw_bar_lines :: proc(now: f64, measure_times: []f64, positions: []chart.Hand_Position) {
	for measure_time in measure_times {
		z := depth_of(measure_time - now) or_continue
		left, right := hand_edges(chart.hand_at(positions, measure_time))
		draw_line({left, 0, z}, {right, 0, z}, LINE, BAR_COLOR)
	}
}

// The fret wires stand on the floor and reach the top of the board. The strings run from the nut to the last fret.
@(private)
draw_guitar :: proc(string_count: int) {
	top := board_top(string_count)
	for wire in 0 ..= FRET_COUNT {
		x := f32(wire)
		draw_line({x, 0, 0}, {x, top, 0}, WIRE, NUT_COLOR if wire == 0 else WIRE_COLOR)
	}
	for color, string_index in STRING_COLORS[:string_count] {
		y := string_y(string_index)
		draw_line({0, y, 0}, {FRET_COUNT, y, 0}, WIRE, color)
	}
}

// Gems are sorted by time, so the gems of one chord are neighbours. Drawn far to near.
@(private)
draw_gems :: proc(now: f64, gems: []chart.Gem, positions: []chart.Hand_Position, string_count: int) {
	end := len(gems)
	for end > 0 {
		start := chord_start(gems, end - 1)
		draw_gem_group(now, gems[start:end], positions, string_count)
		end = start
	}
}

@(private)
chord_start :: proc(gems: []chart.Gem, last: int) -> int {
	first := last
	for first > 0 && gems[first - 1].time == gems[last].time do first -= 1
	return first
}

@(private)
draw_gem_group :: proc(now: f64, group: []chart.Gem, positions: []chart.Hand_Position, string_count: int) {
	if len(group) > 1 do draw_chord_frame(now, group[0], positions, string_count)
	else do draw_stem(now, group[0], positions)
	for gem in group do draw_gem(now, gem, positions)
}

// A gem is a flat card that faces the player.
@(private)
draw_gem :: proc(now: f64, gem: chart.Gem, positions: []chart.Hand_Position) {
	center, visible := gem_center(gem, now, positions)
	if !visible do return
	rl.DrawCubeV(center, {gem_width(gem, positions), GEM_HEIGHT, 0}, STRING_COLORS[gem.string_index])
	draw_gem_marks(gem, center)
}

// A stem drops from an upcoming fretted gem to its fret digit on the floor.
@(private)
draw_stem :: proc(now: f64, gem: chart.Gem, positions: []chart.Hand_Position) {
	if gem.fret == 0 || gem.time <= now do return
	center, visible := gem_center(gem, now, positions)
	if !visible do return
	draw_line(center, {center.x, 0, center.z}, LINE, STEM_COLOR)
}

// The frame outlines the hand window across the whole board, so every chord gets the same frame.
@(private)
draw_chord_frame :: proc(now: f64, chord_gem: chart.Gem, positions: []chart.Hand_Position, string_count: int) {
	z, visible := gem_depth(chord_gem, now)
	if !visible do return
	left, right := hand_edges(chart.hand_at(positions, chord_gem.time))
	top := board_top(string_count)
	draw_loop({{left, 0, z}, {right, 0, z}, {right, top, z}, {left, top, z}}, CHORD_FRAME)
}

// Lists the frets of the hand, and the inlay frets outside it, in the two string gaps below the floor.
@(private)
draw_fret_digits :: proc(camera: rl.Camera3D, hand: chart.Hand_Position) {
	for fret in 1 ..= FRET_COUNT {
		in_hand := fret >= hand.fret && fret < hand.fret + hand.width
		if !in_hand && fret not_in INLAY_FRETS do continue
		color := HAND_DIGIT if in_hand else OUT_OF_HAND_DIGIT
		draw_digits(camera, fret, {home_x(fret), -STRING_GAP, 0}, color)
	}
}

// A fretted gem ahead gets its fret under its stem, unless the gem before it has the same fret.
@(private)
draw_gem_fret_digits :: proc(camera: rl.Camera3D, now: f64, gems: []chart.Gem) {
	for gem, index in gems {
		if gem.time > now + LOOKAHEAD do break
		if gem.time <= now || gem.fret == 0 do continue
		if index > 0 && gems[index - 1].fret == gem.fret do continue
		z := depth_of(gem.time - now) or_continue
		draw_digits(camera, gem.fret, {home_x(gem.fret), 0, z}, STEM_COLOR)
	}
}

// Centered on at, and as tall as DIGIT_HEIGHT looks there, so far digits are small.
// It is in screen pixels, not ui units, because the camera places it.
@(private)
draw_digits :: proc(camera: rl.Camera3D, number: int, at: rl.Vector3, color: rl.Color) {
	bottom := rl.GetWorldToScreen(at - {0, DIGIT_HEIGHT / 2, 0}, camera)
	top := rl.GetWorldToScreen(at + {0, DIGIT_HEIGHT / 2, 0}, camera)
	font_size := c.int(bottom.y - top.y)
	text := fmt.ctprint(number)
	width := rl.MeasureText(text, font_size)
	rl.DrawText(text, c.int(top.x) - width / 2, c.int(top.y), font_size, color)
}

@(private)
draw_line :: proc(from, to: rl.Vector3, thickness: f32, color: rl.Color) {
	rl.DrawCylinderEx(from, to, thickness / 2, thickness / 2, 8, color)
}

// Joins each point to the next, and the last point to the first.
@(private)
draw_loop :: proc(points: []rl.Vector3, color: rl.Color) {
	for point, index in points do draw_line(point, points[(index + 1) % len(points)], LINE, color)
}

// The center of the gem. A bent gem rises with its line while it sounds.
@(private)
gem_center :: proc(gem: chart.Gem, now: f64, positions: []chart.Hand_Position) -> (center: rl.Vector3, ok: bool) {
	z := gem_depth(gem, now) or_return
	x := lane_x(gem.fret, gem.time, positions)
	y := string_y(gem.string_index) + bend_lift(gem, now)
	return {x, y, z}, true
}

// A gem whose sustain is still sounding stays on the strings.
@(private)
gem_depth :: proc(gem: chart.Gem, now: f64) -> (z: f32, ok: bool) {
	until := gem.time - now
	if until > LOOKAHEAD do return
	sustain := gem.line.sustain
	if sustain > 0 && until < 0 {
		if until + sustain < 0 do return
		return 0, true
	}
	return depth_of(until)
}

// The z of seconds_ahead, when that moment is on the highway.
@(private)
depth_of :: proc(seconds_ahead: f64) -> (z: f32, ok: bool) {
	if seconds_ahead > LOOKAHEAD || seconds_ahead < -PAST_LIMIT do return
	return z_at(seconds_ahead), true
}

@(private)
z_at :: proc(seconds_ahead: f64) -> f32 {
	return -f32(seconds_ahead) * Z_PER_SECOND
}

// The z range of the floor under positions[index], cut to the highway.
@(private)
hand_depth :: proc(now: f64, positions: []chart.Hand_Position, index: int) -> (near, far: f32, visible: bool) {
	start := positions[index].time - now
	end := LOOKAHEAD
	if index + 1 < len(positions) do end = positions[index + 1].time - now
	if end <= 0 || start >= LOOKAHEAD do return
	return z_at(max(start, 0)), z_at(min(end, LOOKAHEAD)), true
}

@(private)
string_y :: proc(string_index: int) -> f32 {
	return f32(string_index + 1) * STRING_GAP
}

// One gap above the highest string, as the floor is one gap below the lowest.
@(private)
board_top :: proc(string_count: int) -> f32 {
	return string_y(string_count)
}

// The middle of the fret.
@(private)
home_x :: proc(fret: int) -> f32 {
	return f32(fret) - 0.5
}

// The lane of a fretted gem, or the middle of the hand window for an open gem.
@(private)
lane_x :: proc(fret: int, time: f64, positions: []chart.Hand_Position) -> f32 {
	if fret > 0 do return home_x(fret)
	left, right := hand_edges(chart.hand_at(positions, time))
	return (left + right) / 2
}

// An open gem spans the hand window.
@(private)
gem_width :: proc(gem: chart.Gem, positions: []chart.Hand_Position) -> f32 {
	if gem.fret > 0 do return GEM_WIDTH
	left, right := hand_edges(chart.hand_at(positions, gem.time))
	return right - left
}

@(private)
hand_edges :: proc(hand: chart.Hand_Position) -> (left, right: f32) {
	return fret_edges(hand.fret, hand.fret + hand.width - 1)
}

// The left edge of fret first and the right edge of fret last, kept on the board and at least one fret apart.
@(private)
fret_edges :: proc(first, last: int) -> (left, right: f32) {
	low := clamp(first, 1, FRET_COUNT)
	high := clamp(last, low, FRET_COUNT)
	return f32(low - 1), f32(high)
}
