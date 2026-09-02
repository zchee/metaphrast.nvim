// Package sample provides a Go file for the metaphrast test suite. The
// comment block above the package clause spans exactly three lines so the
// hover specs and the smoke test can translate lines 1 to 3 as one paragraph.
package sample

// Greet returns a greeting addressed to name.
func Greet(name string) string {
	return "hello, " + name
}
