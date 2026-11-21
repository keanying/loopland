# syntax=docker/dockerfile:1
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/loopland-api ./cmd/loopland-api \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/loopland-seed ./cmd/loopland-seed \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/loopland-doctor ./cmd/loopland-doctor

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/ /
EXPOSE 8080
ENTRYPOINT ["/loopland-api"]
