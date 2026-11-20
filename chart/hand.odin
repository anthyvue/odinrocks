package chart

// fret is the index finger. The window covers fret ..< fret+width.
Hand_Position :: struct {
	time:  f64,
	fret:  int,
	width: int,
}

HAND_SPAN :: 4

@(private)
Fret_Span :: struct {
	lo, hi: int,
}

hand_positions :: proc(gems: []Gem) -> []Hand_Position {
	if len(gems) == 0 do return nil

	positions: [dynamic]Hand_Position
	pending: Maybe(Fret_Span)
	group_start := gems[0].time
	index := 0

	for index < len(gems) {
		time := gems[index].time
		frets, next := same_time_frets(gems, index)
		index = next
		span := frets.? or_continue

		held, has_held := pending.?
		if !has_held {
			pending = span
			continue
		}

		joined := Fret_Span{min(held.lo, span.lo), max(held.hi, span.hi)}
		allowed := max(HAND_SPAN, held.hi - held.lo + 1)
		if joined.hi - joined.lo + 1 <= allowed {
			pending = joined
			continue
		}

		keep_position(&positions, group_start, held)
		group_start = time
		pending = span
	}

	last := pending.? or_else Fret_Span{1, 1}
	keep_position(&positions, group_start, last)
	return positions[:]
}

hand_at :: proc(positions: []Hand_Position, time: f64) -> Hand_Position {
	if len(positions) == 0 do return {fret = 1, width = HAND_SPAN}
	chosen := positions[0]
	for position in positions {
		if position.time > time do break
		chosen = position
	}
	return chosen
}

// Frets covered by positions whose [time, next time) overlaps [now, now+horizon].
fret_span_ahead :: proc(positions: []Hand_Position, now, horizon: f64) -> (first, last: int, ok: bool) {
	until := now + horizon
	for position, index in positions {
		if position.time > until do break
		ends := max(f64)
		if index + 1 < len(positions) do ends = positions[index + 1].time
		if ends <= now do continue

		lo := position.fret
		hi := position.fret + position.width - 1
		if !ok do first, last = lo, hi
		first = min(first, lo)
		last = max(last, hi)
		ok = true
	}
	return
}

// The index finger goes on span.lo. Wide spans widen the hand. The same fret again widens the previous position instead.
@(private)
keep_position :: proc(positions: ^[dynamic]Hand_Position, time: f64, span: Fret_Span) {
	width := max(HAND_SPAN, span.hi - span.lo + 1)
	if len(positions) > 0 {
		previous := &positions[len(positions) - 1]
		if previous.fret == span.lo {
			previous.width = max(previous.width, width)
			return
		}
	}
	append(positions, Hand_Position{time = time, fret = span.lo, width = width})
}

// The frets of the gems that sound at the time of gems[start], and the index of the first gem after them. nil when every one of them is open.
@(private)
same_time_frets :: proc(gems: []Gem, start: int) -> (span: Maybe(Fret_Span), next: int) {
	time := gems[start].time
	next = start
	for next < len(gems) && gems[next].time == time {
		fret := gems[next].fret
		next += 1
		if fret <= 0 do continue
		if found, has_found := span.?; has_found do span = Fret_Span{min(found.lo, fret), max(found.hi, fret)}
		else do span = Fret_Span{fret, fret}
	}
	return
}
