# Verification checkpoint

Migration compatibility verification is complete for the recorded cases.
The comparison tools and fixtures were retired after the
[four-platform Nix run](https://github.com/rickyhugo/huen-sessionizer/actions/runs/43452088400)
and [mise CI run](https://github.com/rickyhugo/huen-sessionizer/actions/runs/43452088348)
passed.

The verified checks included:

- 42 stored command cases and 25 stored ranking vectors.
- 815 completion probes, 40 jj probes, and 42 help forms against Rust.
- 101 targeted CLI probes and 35 repository/session scenarios.
- 21 terminal/popup scenarios and 16 focused picker scenarios.
- Native ARM Linux module tests and real cross-device metadata fixtures.
- Four release archives with exact notices and native Apple Silicon smoke.
- Independent Sol-high review and targeted repair verification.

This evidence covers tested cases, not every possible input. Benchmark results
were inconclusive; no speedup is claimed.

Commit `9fd6bbd2517606b7575ecf6bfdd2772e3400d2f1` retains the pre-cleanup
tools, fixtures, and migration records. It is the repository's clean-history
root; earlier fork commit IDs mentioned in historical reports belong to the
original `rickyhugo/tmux-sessionizer` repository.

Current development uses Zig unit tests, executable regressions, PTY tests,
and packaging checks through mise and hk. See [development](development.md).
