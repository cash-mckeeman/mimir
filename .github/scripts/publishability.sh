#!/usr/bin/env bash
# publishability.sh PACKAGE — would this package publish correctly?
#  build    MIMIR_PUBLISH=1 mix hex.build succeeds; it exits 1 on a path or git dep.
#  license  the tarball holds LICENSE (hex.build does not check).
#  sibling  every sibling requirement is "~> X.Y.Z" with X.Y the package's own minor.
#  docs     the generated docs link sources under this package's directory, at the tag
#           that publishes this version (vX.Y.0, or <package>-vX.Y.Z for a patch).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; pkg="$1"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cd "$root/$pkg"
MIMIR_PUBLISH=1 mix hex.build --output "$work/pkg.tar" >/dev/null || { echo "FAIL build: MIMIR_PUBLISH=1 mix hex.build failed for $pkg"; exit 1; }
tar -xf "$work/pkg.tar" -C "$work" && mkdir "$work/contents" && tar -xzf "$work/contents.tar.gz" -C "$work/contents"
if [ "$pkg" = mimir_analytics ]; then
  for f in schema.sql views.sql; do
    [ -f "$work/contents/priv/$f" ] || { echo "FAIL runtime-file: priv/$f missing"; exit 1; }
  done
fi
[ -f "$work/contents/LICENSE" ] || { echo "FAIL license: LICENSE is not in the $pkg tarball; add it to package files:"; exit 1; }
version="$(elixir -e '
  {:ok, terms} = :file.consult(String.to_charlist(hd(System.argv())))
  meta = Map.new(terms)
  v = Version.parse!(meta["version"])
  reqs =
    case meta["requirements"] do
      m when is_map(m) -> Enum.map(m, fn {name, r} -> Map.put(Map.new(r), "name", name) end)
      l when is_list(l) -> Enum.map(l, &Map.new/1)
    end
  siblings = ~w(mimir mimir_workflows mimir_orchestration mimir_analytics)
  bad =
    for r <- reqs, r["name"] in siblings,
        not Regex.match?(~r/\A~> #{v.major}\.#{v.minor}\.\d+\z/, r["requirement"]),
        do: "#{r["name"]} #{r["requirement"]}"
  if bad != [] do
    IO.puts("FAIL sibling: requirements must be ~> #{v.major}.#{v.minor}.Z: " <> Enum.join(bad, ", "))
    System.halt(1)
  end
  IO.puts(meta["version"])
' "$work/metadata.config")" || { echo "$version"; exit 1; }
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.0($|-) ]]; then ref="v$version"; else ref="$pkg-v$version"; fi
MIX_ENV=dev mix docs >/dev/null
grep -rqF "/blob/$ref/$pkg/lib/" doc/*.html || { echo "FAIL docs: no source link under /blob/$ref/$pkg/lib/ in $pkg's docs"; exit 1; }
echo "ok: $pkg $version publishable (ref $ref)"
