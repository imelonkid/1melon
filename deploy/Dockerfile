# 1melon-server（apps/server）。构建上下文是仓库根目录（melon-ci pr-check / server-release 都这样调用）。
# 规则：基础镜像钉版本；版本号构建时注入并烘进镜像（APP_VERSION = tag，/health 返回它）；最终镜像带 wget（compose 健康检查用）
FROM golang:1.26.10-alpine3.24 AS build
WORKDIR /src
COPY apps/server/go.mod apps/server/go.sum ./
RUN go mod download
COPY apps/server/ ./
# 纯 Go 的 SQLite 驱动，不用 cgo：静态二进制
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/1melon-server ./cmd/1melon-server

FROM alpine:3.24.3
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} \
    PORT=8790 \
    DATA_DIR=/data
# 非 root 运行；数据只在 /data（compose 挂 ./data）
RUN adduser -D -u 10001 melon && mkdir -p /data && chown melon /data
COPY --from=build /out/1melon-server /usr/local/bin/1melon-server
USER melon
VOLUME ["/data"]
EXPOSE 8790
CMD ["1melon-server"]
