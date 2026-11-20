#+private
package render

import "core:math"
import "../chart"
import rl "vendor:raylib"

// A whole tone, two semitones, rises half a string gap.
BEND_LIFT :: 0.25 * STRING_GAP
SLIDE_IN_SECONDS :: 0.08
// How far a slide with no landing fret goes.
UNPITCHED_FRETS :: f32(1.5)
// How far vibrato and tremolo swing the line to each side. Wide vibrato swings twice as far.
SWING_FRETS :: f32(0.08)
WAVE_HZ :: 5.0
ZIGZAG_HZ :: 14.0
// A sample on each corner of the zigzag keeps its angles sharp, and is plenty for waves and bends.
TAIL_SAMPLES_PER_SECOND :: ZIGZAG_HZ * 4
MARK :: rl.Color{245, 245, 248, 255}

// Tails are half see-through, and drawn far to near before the gems, so a gem is never under a tail.
draw_tails :: proc(now: f64, gems: []chart.Gem, positions: []chart.Hand_Position) {
	#reverse for gem in gems do draw_tail(gem, now, positions)
}

draw_tail :: proc(gem: chart.Gem, now: f64, positions: []chart.Hand_Position) {
	if gem.dead || !tail_in_view(gem, now) do return
	x := lane_x(gem.fret, gem.time, positions)
	landing_x := x
	if gem.line.slide.out == .To_Next do landing_x = lane_x(gem.line.slide.fret, gem.time + gem.line.sustain, positions)
	half_width := gem_width(gem, positions) / 2
	color := rl.Fade(STRING_COLORS[gem.string_index], 0.5)
	draw_sustain(gem, now, x, landing_x, half_width, color)
	draw_slide_in(gem, now, x, half_width, color)
}

tail_in_view :: proc(gem: chart.Gem, now: f64) -> bool {
	return gem.time - SLIDE_IN_SECONDS < now + LOOKAHEAD && gem.time + gem.line.sustain > now - PAST_LIMIT
}

// x is the lane of the gem, and landing_x the lane where a To_Next slide ends.
// The samples sit on a grid that starts at the attack, so the shape holds still while the tail scrolls.
draw_sustain :: proc(gem: chart.Gem, now: f64, x, landing_x, half_width: f32, color: rl.Color) {
	from := max(gem.time, now)
	to := min(gem.time + gem.line.sustain, now + LOOKAHEAD)
	if from >= to do return

	first := int(math.floor((from - gem.time) * TAIL_SAMPLES_PER_SECOND)) + 1
	last := int(math.ceil((to - gem.time) * TAIL_SAMPLES_PER_SECOND)) - 1
	previous := sustain_point(gem, from, now, x, landing_x)
	for sample in first ..= last {
		point := sustain_point(gem, gem.time + f64(sample) / TAIL_SAMPLES_PER_SECOND, now, x, landing_x)
		draw_ribbon(previous, point, half_width, color)
		previous = point
	}
	end := sustain_point(gem, to, now, x, landing_x)
	draw_ribbon(previous, end, half_width, color)
}

draw_slide_in :: proc(gem: chart.Gem, now: f64, x, half_width: f32, color: rl.Color) {
	if gem.line.slide.into == .None do return
	from := max(gem.time - SLIDE_IN_SECONDS, now - PAST_LIMIT)
	to := min(gem.time, now + LOOKAHEAD)
	if from >= to do return

	start := slide_in_point(gem, from, now, x)
	end := slide_in_point(gem, to, now, x)
	draw_ribbon(start, end, half_width, color)
}

// A flat strip on the floor plane, from one point of the line to the next.
draw_ribbon :: proc(from, to: rl.Vector3, half_width: f32, color: rl.Color) {
	side := rl.Vector3{half_width, 0, 0}
	rl.DrawTriangle3D(from - side, to - side, from + side, color)
	rl.DrawTriangle3D(from + side, to - side, to + side, color)
}

sustain_point :: proc(gem: chart.Gem, time, now: f64, x, landing_x: f32) -> rl.Vector3 {
	along := f32(line_progress(gem, time))
	line_x := x
	switch gem.line.slide.out {
	case .To_Next:
		line_x = math.lerp(x, landing_x, along)
	case .Up:
		line_x = x + UNPITCHED_FRETS * along
	case .Down:
		line_x = x - UNPITCHED_FRETS * along
	case .None:
	}
	line_x += swing(gem.line.shape, time - gem.time)
	y := string_y(gem.string_index) + bend_lift(gem, time)
	return {line_x, y, z_at(time - now)}
}

// The line arrives at the gem from UNPITCHED_FRETS below or above.
slide_in_point :: proc(gem: chart.Gem, time, now: f64, x: f32) -> rl.Vector3 {
	remaining := f32(clamp((gem.time - time) / SLIDE_IN_SECONDS, 0, 1))
	direction: f32 = -1 if gem.line.slide.into == .Below else 1
	y := string_y(gem.string_index) + bend_lift(gem, gem.time)
	return {x + direction * UNPITCHED_FRETS * remaining, y, z_at(time - now)}
}

// 0 at the attack of the gem, and 1 at the end of its sustain.
line_progress :: proc(gem: chart.Gem, time: f64) -> f64 {
	if gem.line.sustain <= 0 do return 0
	return clamp((time - gem.time) / gem.line.sustain, 0, 1)
}

// How far the bend of the line lifts it above its string at that time.
bend_lift :: proc(gem: chart.Gem, time: f64) -> f32 {
	semitones := bend_semitones(gem.line.bends, line_progress(gem, time))
	return f32(semitones) * BEND_LIFT
}

// How far the shape moves the line to the side, seconds after the attack. Vibrato waves, tremolo zigzags.
swing :: proc(shape: chart.Line_Shape, seconds: f64) -> f32 {
	switch shape {
	case .Slight_Vibrato:
		return SWING_FRETS * wave(seconds)
	case .Wide_Vibrato:
		return 2 * SWING_FRETS * wave(seconds)
	case .Tremolo:
		return SWING_FRETS * zigzag(seconds)
	case .Straight:
	}
	return 0
}

wave :: proc(seconds: f64) -> f32 {
	return f32(math.sin(math.TAU * WAVE_HZ * seconds))
}

// Starts at 0, and turns sharply at 1 and -1 on odd quarter periods.
zigzag :: proc(seconds: f64) -> f32 {
	phase := ZIGZAG_HZ * seconds + 0.25
	phase -= math.floor(phase)
	return f32(4 * abs(phase - 0.5) - 1)
}

// along is 0 at the attack and 1 at the end of the line. A later first point ramps up from the string.
bend_semitones :: proc(points: []chart.Bend_Point, along: f64) -> f64 {
	count := len(points)
	if count == 0 do return 0
	t := clamp(along, 0, 1)

	first := points[0]
	if t <= first.at {
		if first.at <= 0 do return first.semitones
		return first.semitones * (t / first.at)
	}

	for index in 1 ..< count {
		point := points[index]
		if t > point.at do continue
		previous := points[index - 1]
		span := point.at - previous.at
		if span <= 0 do return point.semitones
		blend := (t - previous.at) / span
		return previous.semitones + (point.semitones - previous.semitones) * blend
	}
	return points[count - 1].semitones
}

// Marks are drawn on the gem, inside a square as tall as the gem.
// A hammer-on points up the board, away from the player, and a pull-off points down. A pinch harmonic is a diamond, and a dead note an X.
draw_gem_marks :: proc(gem: chart.Gem, center: rl.Vector3) {
	h := GEM_HEIGHT / 2
	switch gem.hop {
	case .Hammer:
		draw_loop({center + {0, h, 0}, center + {h, -h, 0}, center + {-h, -h, 0}}, MARK)
	case .Pull:
		draw_loop({center + {0, -h, 0}, center + {h, h, 0}, center + {-h, h, 0}}, MARK)
	case .None:
	}
	if gem.pinch do draw_loop({center + {0, h, 0}, center + {h, 0, 0}, center + {0, -h, 0}, center + {-h, 0, 0}}, MARK)
	if gem.dead {
		draw_line(center + {-h, -h, 0}, center + {h, h, 0}, LINE, MARK)
		draw_line(center + {-h, h, 0}, center + {h, -h, 0}, LINE, MARK)
	}
}
