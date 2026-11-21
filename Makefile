.PHONY: test vet fmt run seed doctor dev-up dev-down

test:
	cd server && go test ./...

vet:
	cd server && go vet ./...

fmt:
	cd server && gofmt -w .

# Needs PostgreSQL+PostGIS and Redis (see `make dev-up` or deploy/docker-compose.yml).
run:
	cd server && LOOPLAND_ENV=dev LOOPLAND_BOOTSTRAP_ADMIN=admin:admin-password-1 go run ./cmd/loopland-api

seed:
	cd server && go run ./cmd/loopland-seed -api http://localhost:8080

dev-up:
	docker compose -f deploy/docker-compose.yml up -d --build

dev-down:
	docker compose -f deploy/docker-compose.yml down

doctor:
	cd server && go run ./cmd/loopland-doctor
