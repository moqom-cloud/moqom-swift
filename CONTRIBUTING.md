# Contributing

Thanks for wanting to help. This SDK is Apache-2.0 and maintained by
Elliott Wave LLC (elliottwave.studio lab). Issues and pull requests are welcome.

## Before you open a pull request

1. **Sign the CLA.** The first pull request you open asks you to sign the
   [Copyright Assignment Agreement](.github/CLA.md) by leaving a comment.
   Elliott Wave LLC owns all of MOQOM's intellectual property, open source
   included, so your contribution's copyright is assigned to it; you get a
   permanent licence back to use your own work for anything. We have contacted
   legal counsel to review the agreement.
2. **Open an issue first for anything bigger than a bug fix**, so nobody spends a
   weekend on a change that conflicts with work in progress.
3. **Keep the public API stable.** Additions are easy; renames and removals need
   a deprecation period and a note in the changelog.

## Building and testing

```sh
swift build
swift test
```

This needs Xcode 26 or a Swift 6.2 toolchain with the 26 SDKs. Tests run against
an in-memory relay and carrier, so no account or network access is needed. The
three relay interop tests skip unless `MOQOM_RELAY_BIN` points at a relay binary;
see [Interop](README.md#interop).

## Good first issues

Look for the `good first issue` label. Documentation fixes, examples, and clearer
error messages are always useful.

## Security

Do not open a public issue for a vulnerability. Email security@moqom.cloud;
see [SECURITY.md](SECURITY.md).

## Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Support the open-source work

The SDKs, samples and shells are free. If MOQOM's open-source work is useful to
you, you can support it at [elliottwave.dev/donate](https://elliottwave.dev/donate/).
Donations fund maintenance of the public repositories; they do not buy priority
support or influence over the roadmap.
