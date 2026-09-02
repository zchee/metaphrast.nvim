TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/

.PHONY: test fmt lint

test:
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}' }"

fmt:
	@stylua .

lint:
	@luacheck lua/ plugin/ tests/
