package youtube

import "core:testing"

@(test)
on_path_is_false_for_a_missing_program :: proc(t: ^testing.T) {
	testing.expect(t, !on_path("odinrocks-no-such-program"))
}

@(test)
on_path_is_true_for_a_program_on_path :: proc(t: ^testing.T) {
	testing.expect(t, on_path("cmd"))
}
