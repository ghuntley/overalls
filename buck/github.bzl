# The managed GitHub tools release directory (ADR-0269, M7). It reproduces the
# Nix `overalls-github-tools-release-v1` layout and manifest byte for byte, so
# Marshall and Ziggy can read the same manifest generation from either build.
# Contract go-binary-nix-parity: see buck/CONTRACTS.

load(":checks.bzl", "tool", "tool_attr")

_SCRIPT = [
    "set -euo pipefail",
    "out=$1 config=$2; shift 2",
    "mkdir -p \"$out\"",
    "config_digest=$(sha256sum \"$config\" | cut -d ' ' -f 1)",
    "manifest=$(jq -nc --arg configuration_sha256 \"$config_digest\" '{version:1,configuration_sha256:$configuration_sha256,platforms:{}}')",
    "while [ $# -gt 0 ]; do",
    "  platform=$1 gh=$2 lfs=$3; shift 3",
    "  suffix=; case $platform in windows-*) suffix=.exe ;; esac",
    "  mkdir -p \"$out/$platform\"",
    "  cp \"$gh\" \"$out/$platform/gh$suffix\"",
    "  cp \"$lfs\" \"$out/$platform/git-lfs$suffix\"",
    "  cp \"$config\" \"$out/$platform/github.gitconfig\"",
    "  chmod 0555 \"$out/$platform/gh$suffix\" \"$out/$platform/git-lfs$suffix\"",
    "  chmod 0444 \"$out/$platform/github.gitconfig\"",
    "  files='[]'",
    "  for name in gh git-lfs github.gitconfig; do",
    "    file=$name; [ \"$name\" != github.gitconfig ] && file=$name$suffix",
    "    digest=$(sha256sum \"$out/$platform/$file\" | cut -d ' ' -f 1)",
    "    bytes=$(wc -c < \"$out/$platform/$file\")",
    "    files=$(jq -nc --argjson files \"$files\" --arg name \"$name\" --arg sha256 \"$digest\" --argjson bytes \"$bytes\" --arg path \"$platform/$file\" '$files + [{name:$name,sha256:$sha256,bytes:$bytes,path:$path}] | sort_by(.name)')",
    "  done",
    "  manifest=$(printf '%s' \"$manifest\" | jq -c --arg platform \"$platform\" --argjson files \"$files\" '.platforms[$platform] = {files:$files}')",
    "done",
    "generation=$(printf '%s\\n' \"$manifest\" | jq -Scj . | sha256sum | cut -d ' ' -f 1)",
    "printf '%s\\n' \"$manifest\" | jq -Sc --arg generation \"$generation\" '. + {generation:$generation}' > \"$out/manifest.json\"",
    "chmod 0444 \"$out/manifest.json\"",
]

def _github_tools_release_impl(ctx: AnalysisContext) -> list[Provider]:
    out = ctx.actions.declare_output("release", dir = True)
    script = ctx.actions.write("release.sh", _SCRIPT)
    args = cmd_args(tool(ctx.attrs._bash), script, out.as_output(), ctx.attrs.configuration)
    for platform, tools in sorted(ctx.attrs.platforms.items()):
        args.add(platform, tools[0][DefaultInfo].default_outputs[0], tools[1][DefaultInfo].default_outputs[0])
    ctx.actions.run(
        args,
        env = {"PATH": "{}:{}".format(tool(ctx.attrs._coreutils), tool(ctx.attrs._jq).rsplit("/", 1)[0])},
        category = "github_tools_release",
    )
    return [DefaultInfo(default_output = out)]

github_tools_release = rule(
    impl = _github_tools_release_impl,
    attrs = {
        "configuration": attrs.source(),
        # platform -> (gh, git-lfs)
        "platforms": attrs.dict(attrs.string(), attrs.tuple(attrs.dep(), attrs.dep())),
        "_bash": tool_attr("bash"),
        "_coreutils": tool_attr("coreutils"),
        "_jq": tool_attr("jq"),
    },
)
