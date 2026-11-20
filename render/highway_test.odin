package render

import "core:testing"
import "../chart"

WIDE :: f32(16.0 / 9)

@(test)
narrow_hand_keeps_the_resting_width :: proc(t: ^testing.T) {
	positions := []chart.Hand_Position{{time = 0, fret = 5, width = 4}}
	resting := visible_width(WIDE)
	_, width := desired_frame(positions, 0, resting)
	testing.expect(t, abs(width - resting) < 0.001)
}

@(test)
wide_jump_inside_the_lookahead_widens_the_frame :: proc(t: ^testing.T) {
	positions := []chart.Hand_Position{
		{time = 0, fret = 1, width = 4},
		{time = 2, fret = 17, width = 4},
	}
	resting := visible_width(WIDE)
	center, width := desired_frame(positions, 0, resting)
	// Frets 1..20 span x = 0..20, plus one fret of margin on each side.
	testing.expect(t, width > resting)
	testing.expect_value(t, width, 22)
	testing.expect_value(t, center, 10)
}

@(test)
jump_past_the_lookahead_stays_on_the_current_hand :: proc(t: ^testing.T) {
	later := CAMERA_AHEAD + 3
	positions := []chart.Hand_Position{
		{time = 0, fret = 5, width = 4},
		{time = later, fret = 18, width = 4},
	}
	resting := visible_width(WIDE)
	near_center, near_width := desired_frame(positions, 0, resting)
	far_center, far_width := desired_frame(positions, later - 1, resting)
	testing.expect(t, near_width < far_width)
	testing.expect(t, near_center < far_center)
}

@(test)
spring_starts_slowly_and_settles :: proc(t: ^testing.T) {
	value: f32
	velocity: f32
	spring_toward(&value, &velocity, 10, 1.0 / 240, CAMERA_SMOOTH)
	testing.expect(t, value > 0 && value < 0.05)

	for _ in 0 ..< 480 {
		spring_toward(&value, &velocity, 10, 1.0 / 240, CAMERA_SMOOTH)
	}
	testing.expect(t, abs(value - 10) < 0.5)
}

@(test)
bend_ramps_from_the_attack_when_the_first_point_is_later :: proc(t: ^testing.T) {
	bends := []chart.Bend_Point{{at = 0.5, semitones = 2}}
	testing.expect_value(t, bend_semitones(bends, 0), 0)
	testing.expect_value(t, bend_semitones(bends, 0.25), 1)
	testing.expect_value(t, bend_semitones(bends, 0.5), 2)

	prebend := []chart.Bend_Point{{at = 0, semitones = 2}, {at = 1, semitones = 0}}
	testing.expect_value(t, bend_semitones(prebend, 0), 2)
	testing.expect_value(t, bend_semitones(prebend, 1), 0)
}

@(test)
sounding_gem_rises_with_its_bend :: proc(t: ^testing.T) {
	bends := []chart.Bend_Point{{at = 1, semitones = 2}}
	gem := chart.Gem{time = 1, line = {sustain = 2, bends = bends}}
	testing.expect_value(t, bend_lift(gem, 0), 0)
	testing.expect_value(t, bend_lift(gem, 2), BEND_LIFT)
	testing.expect_value(t, bend_lift(gem, 5), 2 * BEND_LIFT)
}

@(test)
tremolo_samples_land_on_the_zigzag_corners :: proc(t: ^testing.T) {
	expected := [4]f32{0, -1, 0, 1}
	for sample in 0 ..< 8 {
		value := zigzag(f64(sample) / TAIL_SAMPLES_PER_SECOND)
		testing.expect(t, abs(value - expected[sample % 4]) < 0.0001)
	}
}
