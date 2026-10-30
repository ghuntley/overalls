# Shared localization catalogs

`generate_catalogs.py` converts Mila's canonical catalogs into a stable,
platform-neutral JSON intermediate consumed by every native client build step.
The checked-in ARB files under `mila/localization/catalogs` are the native
source bundle; the generator also accepts Marshall Gettext trees when invoked
with an alternate `--source`. Message identity preserves domain, context,
source id, and plural forms.

```sh
python3 mila/localization/generate_catalogs.py \
  --source mila/localization/catalogs --output build/mila-localization
```

The generator sorts locales, domains, and messages and writes a schema-versioned
`manifest.json`; rerunning it with the same catalogs is byte-for-byte identical.
It validates duplicate identities and interpolation placeholders while preserving
empty source fallback forms for the existing catalog completeness gate.

The Apple Swift package bundles the generated output as SwiftPM resources.
`mila/native/apple/build.sh` and the `apple-native` CI job generate it into
`mila/native/apple/Sources/MilaNativeUI/Resources` (ignored by Git) before
building; run the same command before a local `swift test`.
