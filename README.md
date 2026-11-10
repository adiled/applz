# applz

A lean container runtime over Apple Virtualization.

Each container is its own small Linux VM. Virtualization.framework boots a
pinned kernel with the image as its root, a tiny init runs the container's
process, and stdio and the exit code come back over vsock. There is no daemon:
the VM lives exactly as long as `applz run`, so whatever runs `applz run`
(launchd, systemd, a shell) is the supervisor. No Docker, no Swift, nothing
beyond macOS itself.

```sh
applz pull nginx:alpine
applz run site nginx:alpine --spec site.json   # foreground; exits with the container
applz stop site
applz rm site
```

## The run spec

Everything beyond the image is one JSON document, given as a file
(`--spec <path>`) or inline (`--spec-base64 <data>`, for callers that put the
command in a shell line). Serving a folder from your Mac:

```json
{
  "mounts": [{ "source": "/Users/me/site", "destination": "/usr/share/nginx/html" }],
  "ports": [{ "host": 8080, "container": 80 }],
  "memory": "256M",
  "cpus": 1
}
```

| Field | Meaning |
|---|---|
| `env` | `["KEY=value", …]`, added to the image's own |
| `mounts` | host folders shared into the container: `source` → `destination`, read-only with `"read_only": true` |
| `ports` | `host` port forwarded to the container's, on `address` (default 127.0.0.1) |
| `memory`, `cpus` | the VM's size: `256M`, `1G`; vCPUs rounded up |
| `user`, `workdir` | who the process runs as, and where |
| `entrypoint`, `cmd` | replace the image's, split into words like a shell |
| `limits` | `nofile`, `nproc`, `pids`, `io_weight`, `cpu_quota` (`"50%"`) |

Every field is optional, and an unknown field is an error, so a typo is loud.

## Install

Apple silicon and macOS with Virtualization.framework. With Zig 0.17.1 and
[`just`](https://github.com/casey/just):

```sh
just install        # build, sign with the virtualization entitlement, install
just kernel         # fetch the pinned Linux kernel into ~/.applz/kernel
applz check
```

`applz` and its guest init `applz-init` are installed side by side and must stay
together. Images are cached under `~/.applz/images`, running containers under
`~/.applz/run`.

## How it works

[`DESIGN.md`](DESIGN.md).

## License

Apache-2.0
