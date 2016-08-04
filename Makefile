# Makefile for AppStream Generator
all:
	dub build --parallel

build:
	dub build --parallel

fast:
	@echo "! Building without optimizations"
	dub build --parallel --build=debug-nooptimize

test:
	dub test

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

install:
	./contrib/setup/install.sh

update-submodule:
	git submodule init
	git submodule update

.PHONY: clean js test install update-submodule
