.PHONY: build install clean clean-logs generate ensure-generated

generate:
	@echo "Generating protobuf code..."
	buf generate

ensure-generated:
	@if [ ! -f cursor-api/gen/aiserver/v1/AiServerice.pb.go ] || [ ! -f cursor-api/gen/aiserver/v1/aiserverv1connect/AiServerice.connect.go ]; then \
		$(MAKE) generate; \
	fi

build: ensure-generated
	@echo "Building cursor-tab RPC server..."
	go build -o bin/cursor-tab-server ./cmd/server

install: build
	@echo "Installing to /usr/local/bin..."
	cp bin/cursor-tab-server /usr/local/bin/

clean:
	rm -rf bin/
	rm -rf cursor-api/gen/
	rm -f /tmp/cursor-tab.log

clean-logs:
	@echo "Cleaning logs..."
	rm -f /tmp/cursor-tab.log
	touch /tmp/cursor-tab.log
	@echo "Logs cleaned!"

run: build
	./bin/cursor-tab-server

deps:
	go mod download
	go mod tidy
