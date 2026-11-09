# applz

A lean container runtime over Apple Virtualization.

Each container is its own small Linux VM. Virtualization.framework boots a
pinned kernel with the image as its root, a tiny init runs the container's
process, and stdio and the exit code come back over vsock. There is no daemon:
the VM lives exactly as long as `applz run`, so whatever runs `applz run`
(launchd, systemd, a shell) is the supervisor. No Docker, no Swift, nothing
beyond macOS itself.

```sh
applz pull postgres:16
applz run db postgres:16 --spec db.json      # foreground; exits with the container
applz stop db
applz rm db
```

## The run spec

Everything beyond the image is one JSON document, given as a file
(`--spec <path>`) or inline (`--spec-base64 <data>`, for callers that put the
command in a shell line):

```json
{
  "env": ["POSTGRES_PASSWORD=secret"],
  "mounts": [{ "source": "/Users/me/pg", "destination": "/var/lib/postgresql/data" }],
  "ports": [{ "host": 5432, "container": 5432, "address": "127.0.0.1" }],
  "memory": "1G",
  "cpus": 2,
  "user": "999:999",
  "workdir": "/var/lib/postgresql",
  "entrypoint": "docker-entrypoint.sh",
  "cmd": "postgres -c fsync=off",
  "limits": { "nofile": 4096, "nproc": 512, "pids": 256, "io_weight": 100, "cpu_quota": "50%" }
}
```

Every field is optional, and an unknown field is an error, so a typo is loud.
`env` is added to the image's own; `entrypoint` and `cmd` replace the image's.

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
