#+private
package fetch

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import curl "vendor:curl"

HTTP_OK :: 200
HTTP_FORBIDDEN :: 403
HTTP_NOT_FOUND :: 404

// Returns the document at url. Prints why to stderr and returns false unless the server answers 200.
document :: proc(url: string) -> (body: []byte, ok: bool) {
	data, status := get(url) or_return
	if status != HTTP_OK {
		fmt.eprintfln("fetch %s: http %d", url, status)
		return nil, false
	}
	return data, true
}

// Returns the body of the first url that answers 200. A 403 or 404 moves on to the next url.
// Prints why to stderr and returns false for any other answer, or when every url answered 403 or 404.
first_available :: proc(urls: []string) -> (body: []byte, ok: bool) {
	for url in urls {
		data, status := get(url) or_return
		switch status {
		case HTTP_OK: return data, true
		case HTTP_FORBIDDEN, HTTP_NOT_FOUND: continue
		case:
			fmt.eprintfln("fetch %s: http %d", url, status)
			return nil, false
		}
	}
	fmt.eprintfln("fetch: every mirror answered 403 or 404: %v", urls)
	return nil, false
}

// ok is false when the request failed, and says why on stderr. Any status is a request that worked.
// The body is decompressed, and is nil unless the status is 200.
get :: proc(url: string) -> (body: []byte, status: int, ok: bool) {
	handle := curl.easy_init()
	defer curl.easy_cleanup(handle)
	received := make([dynamic]byte)
	curl.easy_setopt(handle, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	// An empty string accepts every encoding this libcurl can decode. CloudFront sends gzip.
	curl.easy_setopt(handle, .ACCEPT_ENCODING, cstring(""))
	curl.easy_setopt(handle, .WRITEFUNCTION, append_received)
	curl.easy_setopt(handle, .WRITEDATA, &received)

	if code := curl.easy_perform(handle); code != .E_OK {
		fmt.eprintfln("fetch %s: %s", url, curl.easy_strerror(code))
		delete(received)
		return nil, 0, false
	}
	response_code: c.long
	curl.easy_getinfo(handle, .RESPONSE_CODE, &response_code)
	if response_code != HTTP_OK {
		delete(received)
		return nil, int(response_code), true
	}
	return received[:], HTTP_OK, true
}

// The curl write callback. Appends the bytes to the [dynamic]byte that received points to.
append_received :: proc "c" (buffer: [^]byte, size, count: c.size_t, received: rawptr) -> c.size_t {
	// append grows with the allocator stored in the array, so the default context is enough.
	context = runtime.default_context()
	append((^[dynamic]byte)(received), ..buffer[:size * count])
	return size * count
}
