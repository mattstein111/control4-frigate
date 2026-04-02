# Contributing

This project is solo-maintained by [Matt Stein](https://github.com/mattstein111).

## Bug Reports

If you find a bug, please [open an issue](https://github.com/mattstein111/control4-frigate/issues/new?template=bug_report.md) with as much detail as possible — your Control4 OS version, Frigate version, driver version, and any relevant logs from the Composer Pro Lua tab.

## Feature Requests

Feature requests are welcome. Please [open an issue](https://github.com/mattstein111/control4-frigate/issues/new?template=feature_request.md) describing the use case before starting any work.

## Pull Requests

PRs are welcome, but please discuss your proposed change in an issue first. This avoids duplicate effort and ensures the change fits the project direction.

## Building

Driver packages (`.c4z` files) are built using the included build script:

```bash
./build.sh all
```

Output goes to `dist/`. See the [README](README.md#building-from-source) for details.
