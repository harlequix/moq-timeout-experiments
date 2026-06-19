# moq-timeout-experiments

Experiment harness for the MoQ delivery-timeout study. It drives the
publisher, relay, and subscriber binaries from
[moq-streaming](https://github.com/harlequix/moq-streaming) across a matrix of
network conditions, reset strategies, and timeout values, applying impairments
with `netem` and `tc` HTB on a Linux network namespace. The per-run CSV logs it
produces are published as
[moq-timeout-dataset](https://github.com/harlequix/moq-timeout-dataset).

## Requirements

- Linux with `ip netns` and `tc` (netem + HTB); root for namespace setup
- `ffmpeg` (publisher) and `mpv` (subscriber) on `PATH`
- `jq`
- Prebuilt `publisher`, `relay`, `subscriber` binaries (see below)

Tested with ffmpeg n8.1.2, mpv 0.41.0, jq 1.8.1, iproute2 7.1.0 (tc), and Go 1.24 for the binaries.

## Binaries

The three binaries are gitignored rather than shipped. Build them from
moq-streaming and place them in this directory:

    git clone https://github.com/harlequix/moq-streaming
    cd moq-streaming
    go build -o ../publisher ./cmd/publisher
    go build -o ../relay ./cmd/relay
    go build -o ../subscriber ./cmd/subscriber

Alternatively, point `BIN_DIR` at them by copying `.env.example` to `.env`.

## Network namespace

    sudo ./netns-setup.sh     # create namespace
    sudo ./netns-teardown.sh  # clean up

## Run

A single condition:

    sudo ./run-experiment.sh --video clip.mp4 --strategy reset-at-keyframe --timeout 200ms --delay 50ms --loss 2 --bandwidth 1mbit --outdir ./results/exp001

The full matrix (conditions x (none + strategies x timeouts) x repeats):

    sudo ./run-matrix.sh --video clip.mp4 --duration 30 --repeats 10

Network conditions are defined in `conditions.conf`. Output lands under
`results/` (gitignored); each run directory holds the relay metrics and the
per-subscriber receive and display CSVs that the dataset's analysis pipeline
consumes.

## License

MIT (see `LICENSE`).
