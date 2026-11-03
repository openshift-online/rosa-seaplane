# Renders the Structurizr C4 model to readable diagrams.
#
# Fully containerized: the only host dependency is a container engine
# (podman by default; override with `make ENGINE=docker ...`). No JDK, no
# Node, no local Chrome required.
#
# Default rendering is PlantUML + Graphviz, which gives proper nested C4
# group boxes and legible edges. Mermaid auto-layout produces an unreadable
# hairball for a model this size, so it is kept only as an opt-in target for
# embedding a single view into a markdown ADR (the repo's markdown convention).
#
#   make            # export PlantUML from the DSL, then render every view to SVG
#   make svg        # same as `make all` (scalable, zoomable - best for reading)
#   make png        # also render PNGs
#   make mermaid    # export Mermaid (.mmd) for embedding a view into a markdown doc
#   make lite       # serve interactive Structurizr Lite at http://localhost:8080
#   make static     # export a self-contained static site (diagrams only) to static-site/
#   make clean      # remove generated .puml / .mmd / .svg / .png

C4_DIR          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
WORKSPACE       := workspace.dsl
ENGINE          ?= podman
STRUCTURIZR_IMG ?= docker.io/structurizr/structurizr
PLANTUML_IMG    ?= docker.io/plantuml/plantuml
MERMAID_IMG     ?= docker.io/minlag/mermaid-cli

# :Z relabels the bind mount for SELinux (rootless Podman on Fedora/RHEL).
# The structurizr image runs as UID 65532, which cannot write a host-owned
# bind mount under rootless Podman. --user 0:0 maps container root to the
# invoking user on the host (normal rootless pattern on native Linux); files
# stay owned by you. Only applied for native Linux Podman: on macOS, Podman
# Machine's VM maps "container root" differently (not back to the host user
# via virtiofs), so --user 0:0 there breaks writes instead of fixing them —
# `uname` is checked (not just ENGINE) since both setups report `podman`.
# Docker (rootful on Linux CI runners and Docker Desktop) has no such
# wrinkle: it doesn't userns-remap by default, so container UID 0 really is
# host root and can write into the host-owned bind mount regardless of its
# ownership/permissions. --user 0:0 is therefore applied unconditionally for
# Docker (this is what unblocks `make ENGINE=docker static` on GitHub
# Actions runners, which run as a non-root, non-65532 `runner` user).
ifeq ($(ENGINE),podman)
ifeq ($(shell uname),Linux)
STRUCTURIZR_USER_FLAGS := --user 0:0
else
STRUCTURIZR_USER_FLAGS :=
endif
else ifeq ($(ENGINE),docker)
STRUCTURIZR_USER_FLAGS := --user 0:0
else
STRUCTURIZR_USER_FLAGS :=
endif
STRUCTURIZR_RUN := $(ENGINE) run --rm $(STRUCTURIZR_USER_FLAGS) -v "$(C4_DIR):/usr/local/structurizr:Z" $(STRUCTURIZR_IMG)
PLANTUML_RUN    := $(ENGINE) run --rm -v "$(C4_DIR):/work:Z" -w /work $(PLANTUML_IMG)
MERMAID_RUN     := $(ENGINE) run --rm -v "$(C4_DIR):/data:Z" $(MERMAID_IMG)

.PHONY: all export svg png mermaid lite static clean

## all: export PlantUML from the DSL and render every view to SVG
all: svg

## export: DSL -> one PlantUML file per view (structurizr-<View>.puml)
export:
	$(STRUCTURIZR_RUN) export -workspace $(WORKSPACE) -format plantuml
	@rm -f $(C4_DIR)/structurizr-*-key.puml

## svg: render every exported view to SVG (runs export first)
svg: export
	@for f in $(C4_DIR)/structurizr-*.puml; do \
		b=$$(basename "$$f" .puml); \
		echo "svg  $$b"; \
		$(PLANTUML_RUN) -tsvg "$$b.puml"; \
	done

## png: render every exported view to PNG (runs export first)
png: export
	@for f in $(C4_DIR)/structurizr-*.puml; do \
		b=$$(basename "$$f" .puml); \
		echo "png  $$b"; \
		$(PLANTUML_RUN) -tpng "$$b.puml"; \
	done

## mermaid: export Mermaid (.mmd) for embedding a single view into a markdown doc
mermaid:
	$(STRUCTURIZR_RUN) export -workspace $(WORKSPACE) -format mermaid

## lite: serve the interactive Structurizr Lite UI (Ctrl-C to stop)
# The old structurizr/lite image is deprecated (its entrypoint only prints a
# notice and exits); Lite now lives in the consolidated image as `... local`.
LITE_PORT ?= 8080
lite:
	$(ENGINE) run -it --rm $(STRUCTURIZR_USER_FLAGS) -p $(LITE_PORT):8080 -v "$(C4_DIR):/usr/local/structurizr:Z" $(STRUCTURIZR_IMG) local

## static: export a self-contained static site (plain HTML/CSS/JS, no backend)
# to static-site/. Same interactive diagram renderer as Lite (pan/zoom,
# click-through between views, tooltips) but no documentation/ADR pages -
# just the views. Deployable as-is to GitHub Pages or any static host.
# The exported viewer has no persistent sidebar of its own (navigation is
# double-click / arrow keys / Space quick-find), so static-site-assets/
# (hand-authored, tracked in git) supplies one: it's dropped in as index.html,
# listing every view from workspace.js and driving the exported viewer -
# renamed to diagram.html - via its #<ViewKey> hash navigation in an iframe.
static:
	rm -rf $(C4_DIR)/static-site
	mkdir -p $(C4_DIR)/static-site
	@sleep 1 # podman-machine's virtiofs mount on macOS needs a moment to see a just-created empty dir
	$(STRUCTURIZR_RUN) export -workspace $(WORKSPACE) -format static -output /usr/local/structurizr/static-site
	mv $(C4_DIR)/static-site/index.html $(C4_DIR)/static-site/diagram.html
	cp $(C4_DIR)/static-site-assets/index.html $(C4_DIR)/static-site/index.html
	@echo "Static site written to static-site/ - serve locally with: python3 -m http.server -d static-site 8080"

## clean: remove generated PlantUML, Mermaid, and image files
clean:
	rm -f $(C4_DIR)/structurizr-*.puml $(C4_DIR)/structurizr-*.mmd \
		$(C4_DIR)/structurizr-*.svg $(C4_DIR)/structurizr-*.png
	rm -rf $(C4_DIR)/static-site $(C4_DIR)/.structurizr $(C4_DIR)/workspace.json
