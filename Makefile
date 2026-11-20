.PHONY: test vet fmt run dev-up dev-down

test:
	cd server && go test ./...

vet:
	cd server && go vet ./...

fmt:
	cd server && gofmt -w .

run:
	cd server && go run ./cmd/loopland-api

dev-up:
	docker compose -f deploy/docker-compose.yml up -d

dev-down:
	docker compose -f deploy/docker-compose.yml down
