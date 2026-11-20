package chart

import "core:testing"

@(test)
open_before_a_jump_keeps_the_hand_it_had :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 12}, {time = 1, fret = 0}, {time = 2, fret = 15}, {time = 3, fret = 0}, {time = 4, fret = 3}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 2)
	if len(positions) != 2 do return
	expect_position(t, positions[0], 0, 12, HAND_SPAN)
	expect_position(t, positions[1], 4, 3, HAND_SPAN)
	testing.expect_value(t, hand_at(positions, 3).fret, 12)
	testing.expect_value(t, hand_at(positions, 4).fret, 3)
}

@(test)
opens_before_a_phrase_use_that_phrase :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 0}, {time = 1, fret = 0}, {time = 2, fret = 12}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 1)
	if len(positions) != 1 do return
	expect_position(t, positions[0], 0, 12, HAND_SPAN)
}

@(test)
trailing_open_keeps_the_hand_where_it_was :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 7}, {time = 1, fret = 0}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 1)
	if len(positions) != 1 do return
	expect_position(t, positions[0], 0, 7, HAND_SPAN)
	testing.expect_value(t, hand_at(positions, 1).fret, 7)
}

@(test)
five_fret_jump_starts_a_new_position :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 5}, {time = 1, fret = 8}, {time = 2, fret = 10}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 2)
	if len(positions) != 2 do return
	expect_position(t, positions[0], 0, 5, HAND_SPAN)
	expect_position(t, positions[1], 2, 10, HAND_SPAN)
}

@(test)
lowest_fret_in_a_fitting_phrase_is_the_index_finger :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 7}, {time = 1, fret = 5}, {time = 2, fret = 8}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 1)
	if len(positions) != 1 do return
	expect_position(t, positions[0], 0, 5, HAND_SPAN)
}

@(test)
wide_chord_holds_later_notes_inside_it :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 3}, {time = 0, fret = 8}, {time = 1, fret = 5}, {time = 2, fret = 9}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 2)
	if len(positions) != 2 do return
	expect_position(t, positions[0], 0, 3, 6)
	expect_position(t, positions[1], 2, 9, HAND_SPAN)
}

@(test)
wide_chord_on_the_same_fret_extends_the_position :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 5}, {time = 1, fret = 5}, {time = 1, fret = 9}, {time = 2, fret = 14}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 2)
	if len(positions) != 2 do return
	expect_position(t, positions[0], 0, 5, 5)
	expect_position(t, positions[1], 2, 14, HAND_SPAN)
}

@(test)
same_time_notes_are_one_shape_in_either_order :: proc(t: ^testing.T) {
	low_first := [?]Gem{{time = 0, fret = 3}, {time = 0, fret = 8}}
	high_first := [?]Gem{{time = 0, fret = 8}, {time = 0, fret = 3}}
	low := hand_positions(low_first[:])
	defer delete(low)
	high := hand_positions(high_first[:])
	defer delete(high)

	testing.expect_value(t, len(low), 1)
	testing.expect_value(t, len(high), 1)
	if len(low) != 1 || len(high) != 1 do return
	expect_position(t, low[0], 0, 3, 6)
	expect_position(t, high[0], 0, 3, 6)
}

@(test)
open_string_in_a_chord_does_not_pull_the_hand_to_the_nut :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 0}, {time = 0, fret = 7}, {time = 0, fret = 9}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 1)
	if len(positions) != 1 do return
	expect_position(t, positions[0], 0, 7, HAND_SPAN)
}

@(test)
only_open_notes_sit_at_the_first_fret :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 1, fret = 0}, {time = 2, fret = 0}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 1)
	if len(positions) != 1 do return
	expect_position(t, positions[0], 1, 1, HAND_SPAN)
}

@(test)
hand_can_return_to_a_fret_it_left :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 0, fret = 5}, {time = 1, fret = 12}, {time = 2, fret = 5}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, len(positions), 3)
	if len(positions) != 3 do return
	expect_position(t, positions[0], 0, 5, HAND_SPAN)
	expect_position(t, positions[1], 1, 12, HAND_SPAN)
	expect_position(t, positions[2], 2, 5, HAND_SPAN)
}

@(test)
no_gems_has_no_positions :: proc(t: ^testing.T) {
	positions := hand_positions(nil)
	testing.expect_value(t, len(positions), 0)
	testing.expect_value(t, hand_at(positions, 0).fret, 1)
	testing.expect_value(t, hand_at(positions, 0).width, HAND_SPAN)
}

@(test)
hand_at_keeps_the_latest_position :: proc(t: ^testing.T) {
	gems := [?]Gem{{time = 2, fret = 5}, {time = 6, fret = 12}}
	positions := hand_positions(gems[:])
	defer delete(positions)

	testing.expect_value(t, hand_at(positions, 0).fret, 5)
	testing.expect_value(t, hand_at(positions, 2).fret, 5)
	testing.expect_value(t, hand_at(positions, 5).fret, 5)
	testing.expect_value(t, hand_at(positions, 6).fret, 12)
}

@(test)
fret_span_ahead_unions_positions_inside_the_window :: proc(t: ^testing.T) {
	positions := []Hand_Position{
		{time = 0, fret = 5, width = 4},
		{time = 4, fret = 12, width = 4},
		{time = 9, fret = 2, width = 4},
	}
	first, last, ok := fret_span_ahead(positions, 0, 5)
	testing.expect(t, ok)
	testing.expect_value(t, first, 5)
	testing.expect_value(t, last, 15)
}

@(test)
fret_span_ahead_ignores_a_position_past_the_horizon :: proc(t: ^testing.T) {
	positions := []Hand_Position{
		{time = 0, fret = 5, width = 4},
		{time = 6, fret = 12, width = 4},
	}
	first, last, ok := fret_span_ahead(positions, 0, 5)
	testing.expect(t, ok)
	testing.expect_value(t, first, 5)
	testing.expect_value(t, last, 8)
}

@(test)
fret_span_ahead_includes_a_position_that_starts_on_the_horizon :: proc(t: ^testing.T) {
	positions := []Hand_Position{
		{time = 0, fret = 3, width = 4},
		{time = 5, fret = 14, width = 5},
	}
	first, last, ok := fret_span_ahead(positions, 0, 5)
	testing.expect(t, ok)
	testing.expect_value(t, first, 3)
	testing.expect_value(t, last, 18)
}

@(test)
fret_span_ahead_drops_a_position_that_has_ended :: proc(t: ^testing.T) {
	positions := []Hand_Position{
		{time = 0, fret = 3, width = 4},
		{time = 4, fret = 10, width = 4},
	}
	first, last, ok := fret_span_ahead(positions, 4, 5)
	testing.expect(t, ok)
	testing.expect_value(t, first, 10)
	testing.expect_value(t, last, 13)
}

@(test)
fret_span_ahead_waits_for_the_first_position :: proc(t: ^testing.T) {
	positions := []Hand_Position{{time = 10, fret = 7, width = 4}}
	_, _, early := fret_span_ahead(positions, 0, 5)
	testing.expect(t, !early)
	first, last, ok := fret_span_ahead(positions, 5, 5)
	testing.expect(t, ok)
	testing.expect_value(t, first, 7)
	testing.expect_value(t, last, 10)
}

@(test)
fret_span_ahead_is_empty_without_positions :: proc(t: ^testing.T) {
	_, _, ok := fret_span_ahead(nil, 0, 5)
	testing.expect(t, !ok)
}

@(private)
expect_position :: proc(t: ^testing.T, got: Hand_Position, time: f64, fret, width: int) {
	testing.expect_value(t, got.time, time)
	testing.expect_value(t, got.fret, fret)
	testing.expect_value(t, got.width, width)
}
