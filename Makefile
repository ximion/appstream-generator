# Pseudo-Makefile for AppStream Generator
all:
	@echo "Please run Meson and Ninja manually. See README.md for details."

build-dub:
	dub build --parallel

build-dub-fast:
	@echo "! Building without optimizations"
	dub build --parallel --build=debug-nooptimize

js:
	cd contrib/setup && ./build_js.sh

clean:
	rm -rf build/
	rm -rf .dub/
	rm -f dub.selections.json
	rm -rf contrib/setup/js_tmp/
	rm -rf data/templates/default/static/js/flot/
	rm -rf data/templates/default/static/js/highlight/
	rm -rf data/templates/default/static/js/jquery/

install-dub:
	./contrib/setup/install.sh

update-submodule:
	git submodule init
	git submodule update

.PHONY: clean js test install-dub update-submodule
