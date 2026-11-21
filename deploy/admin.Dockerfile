# Admin console: build with Node, serve with nginx; /admin/v1, /v1 and the
# WebSocket are proxied to the API container.
FROM node:22-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY --from=deploy nginx-admin.conf /etc/nginx/conf.d/default.conf
