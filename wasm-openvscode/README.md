# wasm-openvscode — 为 WebAssembly 演示准备的最小 VS Code 镜像

这是 [`wasm-demo/`](../wasm-demo/README.md) 的可选「精简版」输入镜像：和仓库根目录的
Microsoft `code serve-web` 镜像（压缩后 ~335 MB）相比，它基于 OpenVSCode Server 的官方
linux-x64 tarball 构建，目标是让 **container2wasm 转出来的 wasm 镜像尽可能小**；同时没有
微软 CLI 包装层，wasm guest 里直接由 node server 启动，启动更快。

| 项目 | 根目录镜像（serve-web） | 本镜像（OpenVSCode Server） |
| --- | --- | --- |
| 基础 | debian + 微软 VS Code CLI + 预热 web server cache（738 MB） | debian-slim + OpenVSCode Server tarball（~74 MB 压缩 / 244 MB 解压） |
| 可写目录 | `/home/coder` 等（镜像内） | 全部在 `/tmp`（wasm guest 里就是内存盘；不落盘） |
| 启动路径 | `code serve-web`（Rust CLI）→ node server | 直接 `bin/openvscode-server`（node server） |
| 镜像体积（实测） | ~335 MB 压缩 | **111 MB 压缩**（GHCR manifest） |
| wasm `.data`（实测） | 1.07 GB（zstd 后 358 MB） | **428 MB**（gzip 后 141 MiB / zstd-3 后 129.7 MB） |
| 浏览器首载（实测） | ~1.1 GB（当时未压缩） | **168.5 MB**（gzip 传输，含客户端静态资源） |
| 启动就绪（实测） | 541 s | **105 s**（另一次 195 s） |

> 完整实测数据见 [`wasm-demo/docs/ovs-validation.json`](../wasm-demo/docs/ovs-validation.json)。

## 镜像内容

- `Dockerfile`：debian:bookworm-slim + ca-certificates/curl/libstdc++6/tini +
  [openvscode-server v1.109.5](https://github.com/gitpod-io/openvscode-server/releases)，
  运行用户 `coder`（uid 1000），端口 8000。
- `entrypoint.sh`：把 `HOME`/`XDG_*`/server data dir/默认工作区都放在 `/tmp`
  （wasm guest 的 rootfs 是只读的，`/tmp` 是可写内存盘），然后 `exec` node server。
  支持 `HOST`、`PORT`、`SERVER_DATA_DIR`、`DEFAULT_FOLDER`、`CONNECTION_TOKEN`。

## 使用

镜像由 GitHub Actions 构建并推送到 GHCR（`ghcr.io/frti64/web-vscode-openvscode:latest`）：

```bash
# 原生跑（快）：
docker run --rm -p 8000:8000 ghcr.io/frti64/web-vscode-openvscode:latest
# 浏览器打开 http://localhost:8000

# 转 wasm 并让浏览器跑（用 frti64_c2w 的 container2wasm 工作流）：
gh workflow run build.yml -R FRTI64/frti64_c2w \
  -f source=registry \
  -f image=ghcr.io/frti64/web-vscode-openvscode:latest \
  -f arch=amd64 \
  -f output_kind=to-js \
  -f kernel=mainline \
  -f name=web-vscode-ovs-wasm \
  -f guest_ram=1024
```

产物下载后放进 `wasm-demo/htdocs/`，用 `wasm-demo/scripts/serve.sh`
（或 `scripts/serve-openvscode.sh`）即可在浏览器里自动加载。

## 许可

镜像构建脚本 MIT；OpenVSCode Server 及其中包含的 VS Code OSS 组件遵循其各自许可，
构建/运行时会要求接受 VS Code Server License Terms。
