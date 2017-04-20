# Pseudo-Makefile for AppStream Generator
all:
	@echo "Please run Meson and Ninja manually. See README.md for details."

js:
	cd contrib/setup && ./build_js.sh

clean:
	rm -rf build/
	rm -rf contrib/setup/js_tmp/
	rm -rf data/templates/default/static/js/flot/
	rm -rf data/templates/default/static/js/highlight/
	rm -rf data/templates/default/static/js/jquery/

.PHONY: clean js test
