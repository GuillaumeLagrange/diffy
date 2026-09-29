NVIM ?= nvim
JOBS ?= $(shell nproc)

TEST_FILES := $(wildcard tests/test_*.lua)
RUN = $(NVIM) --headless --noplugin -u tests/minimal_init.lua

.PHONY: test test-gh deps

# one nvim per test file, in parallel; output is grouped per file
test:
ifdef FILE
	$(RUN) -c "lua MiniTest.run_file('$(FILE)')"
else
	@$(MAKE) --no-print-directory -j$(JOBS) --output-sync=target $(TEST_FILES:%=run/%)
endif

# minimal_init clones .deps/ on first run: do it once, before the files race for it
deps:
	@$(RUN) -c qa

run/%: | deps
	@$(RUN) -c "lua MiniTest.run_file('$*')"

GH_FILES := { 'tests/test_github_read.lua', 'tests/test_github_write.lua' }

test-gh:
	DIFFY_TESTGH=1 $(RUN) -c "lua MiniTest.run({ collect = { find_files = function() return $(GH_FILES) end } })"
